import SwiftUI
import AVKit
import AVFoundation

@MainActor
class SequentialPlaybackController: ObservableObject {
    @Published var currentPlayer: AVPlayer?
    @Published var currentClipIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var totalProgress: Double = 0
    @Published var isFinished: Bool = false
    @Published var isLoading: Bool = true

    private var clips: [VideoClip] = []
    private var timeObserver: Any?
    private var clipStartTimes: [CMTime] = []  // Start time of each clip in the composition
    private var totalDuration: CMTime = .zero

    var clipCount: Int {
        clips.count
    }

    func configure(with clips: [VideoClip]) {
        self.clips = clips
        currentClipIndex = 0
        isFinished = false
        isLoading = true

        // Configure audio session for playback
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }

        // Build composition asynchronously
        Task {
            await buildComposition()
        }
    }

    private func buildComposition() async {
        guard !clips.isEmpty else {
            isLoading = false
            return
        }

        do {
            let composition = AVMutableComposition()
            guard let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ),
            let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                print("Failed to create composition tracks")
                isLoading = false
                return
            }

            // First pass: gather info about all videos for render size calculation
            var segments: [(clip: VideoClip, displaySize: CGSize, naturalSize: CGSize, preferredTransform: CGAffineTransform)] = []
            for clip in clips {
                let asset = AVURLAsset(url: clip.url)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = videoTracks.first else { continue }

                let naturalSize = try await videoTrack.load(.naturalSize)
                let preferredTransform = try await videoTrack.load(.preferredTransform)

                let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
                let displaySize = CGSize(
                    width: abs(transformedRect.width),
                    height: abs(transformedRect.height)
                )

                segments.append((clip, displaySize, naturalSize, preferredTransform))
            }

            // Determine render size (use the largest dimensions, ensure portrait)
            var renderWidth: CGFloat = 0
            var renderHeight: CGFloat = 0
            for segment in segments {
                renderWidth = max(renderWidth, segment.displaySize.width)
                renderHeight = max(renderHeight, segment.displaySize.height)
            }
            if renderWidth > renderHeight {
                swap(&renderWidth, &renderHeight)
            }
            let renderSize = CGSize(width: renderWidth, height: renderHeight)

            // Second pass: build composition
            var currentTime = CMTime.zero
            var videoInstructions: [AVMutableVideoCompositionInstruction] = []
            clipStartTimes = []

            for segment in segments {
                let asset = AVURLAsset(url: segment.clip.url)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)

                let trimStartTime = CMTime(seconds: segment.clip.trimStart, preferredTimescale: 600)
                let trimEndTime = CMTime(seconds: segment.clip.trimEnd, preferredTimescale: 600)
                let trimDuration = CMTimeSubtract(trimEndTime, trimStartTime)
                let timeRange = CMTimeRange(start: trimStartTime, duration: trimDuration)

                // Track when each clip starts in the composition
                clipStartTimes.append(currentTime)

                if let assetVideoTrack = videoTracks.first {
                    try compositionVideoTrack.insertTimeRange(timeRange, of: assetVideoTrack, at: currentTime)

                    let transform = calculateTransform(
                        naturalSize: segment.naturalSize,
                        preferredTransform: segment.preferredTransform,
                        displaySize: segment.displaySize,
                        renderSize: renderSize
                    )

                    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
                    layerInstruction.setTransform(transform, at: currentTime)

                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = CMTimeRange(start: currentTime, duration: trimDuration)
                    instruction.layerInstructions = [layerInstruction]
                    videoInstructions.append(instruction)
                }

                if let assetAudioTrack = audioTracks.first {
                    try? compositionAudioTrack.insertTimeRange(timeRange, of: assetAudioTrack, at: currentTime)
                }

                currentTime = CMTimeAdd(currentTime, trimDuration)
            }

            totalDuration = currentTime

            // Create video composition
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = renderSize
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            videoComposition.instructions = videoInstructions

            // Create player item and player
            let playerItem = AVPlayerItem(asset: composition)
            playerItem.videoComposition = videoComposition

            let player = AVPlayer(playerItem: playerItem)
            currentPlayer = player
            setupTimeObserver(for: player)

            isLoading = false

            if isPlaying {
                player.play()
            }

        } catch {
            print("Failed to build composition: \(error)")
            isLoading = false
        }
    }

    private func calculateTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        displaySize: CGSize,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let originalRect = CGRect(origin: .zero, size: naturalSize)
        let transformedRect = originalRect.applying(preferredTransform)

        let scaleX = renderSize.width / displaySize.width
        let scaleY = renderSize.height / displaySize.height
        let scale = min(scaleX, scaleY)

        let scaledWidth = displaySize.width * scale
        let scaledHeight = displaySize.height * scale
        let offsetX = (renderSize.width - scaledWidth) / 2
        let offsetY = (renderSize.height - scaledHeight) / 2

        let moveToOrigin = CGAffineTransform(
            translationX: -transformedRect.origin.x,
            y: -transformedRect.origin.y
        )

        let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
        let centerTransform = CGAffineTransform(translationX: offsetX, y: offsetY)

        return preferredTransform
            .concatenating(moveToOrigin)
            .concatenating(scaleTransform)
            .concatenating(centerTransform)
    }

    private func setupTimeObserver(for player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }

            // Update total progress
            if self.totalDuration.seconds > 0 {
                self.totalProgress = time.seconds / self.totalDuration.seconds
            }

            // Update current clip index based on playback time
            self.updateCurrentClipIndex(for: time)

            // Check if finished
            if time.seconds >= self.totalDuration.seconds - 0.05 {
                self.isFinished = true
                self.isPlaying = false
                self.totalProgress = 1.0
            }
        }
    }

    private func updateCurrentClipIndex(for time: CMTime) {
        for (index, startTime) in clipStartTimes.enumerated().reversed() {
            if CMTimeCompare(time, startTime) >= 0 {
                if currentClipIndex != index {
                    currentClipIndex = index
                }
                break
            }
        }
    }

    func play() {
        isPlaying = true
        if isFinished {
            restart()
        } else {
            currentPlayer?.play()
        }
    }

    func pause() {
        isPlaying = false
        currentPlayer?.pause()
    }

    func restart() {
        isFinished = false
        currentClipIndex = 0
        totalProgress = 0
        currentPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        isPlaying = true
        currentPlayer?.play()
    }

    func cleanup() {
        if let observer = timeObserver, let player = currentPlayer {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        currentPlayer?.pause()
        currentPlayer = nil
    }

    func skipClips(_ count: Int) {
        let newIndex = max(0, min(currentClipIndex + count, clips.count - 1))
        guard newIndex != currentClipIndex, newIndex < clipStartTimes.count else { return }

        currentClipIndex = newIndex
        isFinished = false

        // Seek to the start of the target clip
        let targetTime = clipStartTimes[newIndex]
        currentPlayer?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)

        // Update progress
        if totalDuration.seconds > 0 {
            totalProgress = targetTime.seconds / totalDuration.seconds
        }
    }
}

struct VideoPreviewView: View {
    let clips: [VideoClip]
    let exportQuality: ExportQuality
    let onSave: () -> Void
    let onDiscard: () -> Void

    // For backwards compatibility with ContentView - accepts a pre-combined video URL
    private let preExportedURL: URL?

    @StateObject private var playbackController = SequentialPlaybackController()
    @StateObject private var videoCombiner = VideoCombiner()
    @State private var isExporting = false

    // New initializer for sequential playback (no pre-processing)
    init(clips: [VideoClip], exportQuality: ExportQuality = .highest, onSave: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        self.clips = clips
        self.exportQuality = exportQuality
        self.onSave = onSave
        self.onDiscard = onDiscard
        self.preExportedURL = nil
    }

    // Legacy initializer for pre-combined video (ContentView compatibility)
    init(videoURL: URL, onSave: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        self.clips = []
        self.exportQuality = .highest
        self.onSave = onSave
        self.onDiscard = onDiscard
        self.preExportedURL = videoURL
    }

    private var isLegacyMode: Bool {
        preExportedURL != nil
    }

    @State private var legacyPlayer: AVPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.themeSurface.ignoresSafeArea()

                if isLegacyMode {
                    // Legacy mode: play pre-combined video
                    if let player = legacyPlayer {
                        VideoPlayer(player: player)
                            .ignoresSafeArea()
                    } else {
                        ProgressView()
                    }
                } else {
                    // New mode: sequential playback
                    if let player = playbackController.currentPlayer {
                        VideoPlayer(player: player)
                            .ignoresSafeArea()
                    } else {
                        ProgressView()
                    }

                    // Export progress overlay
                    if isExporting {
                        exportProgressOverlay
                    }

                    // Playback finished overlay
                    if playbackController.isFinished && !isExporting {
                        playbackFinishedOverlay
                    }
                }
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.themeSurface.opacity(0.8), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") {
                        if isLegacyMode {
                            legacyPlayer?.pause()
                        } else {
                            playbackController.cleanup()
                        }
                        onDiscard()
                    }
                    .foregroundColor(.red)
                    .disabled(isExporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if isLegacyMode {
                            legacyPlayer?.pause()
                            onSave()
                        } else {
                            saveVideo()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(isExporting)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !isExporting && !isLegacyMode {
                    playbackInfoBar
                }
            }
        }
        .onAppear {
            if isLegacyMode {
                if let url = preExportedURL {
                    legacyPlayer = AVPlayer(url: url)
                    legacyPlayer?.play()
                }
            } else {
                playbackController.configure(with: clips)
                playbackController.play()
            }
        }
        .onDisappear {
            if isLegacyMode {
                legacyPlayer?.pause()
                legacyPlayer = nil
            } else {
                playbackController.cleanup()
            }
        }
    }

    private var playbackInfoBar: some View {
        VStack(spacing: 12) {
            ProgressView(value: playbackController.totalProgress)
                .progressViewStyle(.linear)
                .tint(.white)

            HStack(spacing: 16) {
                Button {
                    playbackController.skipClips(-5)
                } label: {
                    Text("-5")
                        .font(.subheadline.bold())
                        .foregroundColor(playbackController.currentClipIndex >= 5 ? .white : .white.opacity(0.3))
                        .frame(width: 40, height: 32)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(8)
                }
                .disabled(playbackController.currentClipIndex < 5)

                Button {
                    playbackController.skipClips(-1)
                } label: {
                    Text("-1")
                        .font(.subheadline.bold())
                        .foregroundColor(playbackController.currentClipIndex > 0 ? .white : .white.opacity(0.3))
                        .frame(width: 40, height: 32)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(8)
                }
                .disabled(playbackController.currentClipIndex == 0)

                Button {
                    if playbackController.isPlaying {
                        playbackController.pause()
                    } else {
                        playbackController.play()
                    }
                } label: {
                    Image(systemName: playbackController.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 50, height: 32)
                }

                Button {
                    playbackController.skipClips(1)
                } label: {
                    Text("+1")
                        .font(.subheadline.bold())
                        .foregroundColor(playbackController.currentClipIndex < playbackController.clipCount - 1 ? .white : .white.opacity(0.3))
                        .frame(width: 40, height: 32)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(8)
                }
                .disabled(playbackController.currentClipIndex >= playbackController.clipCount - 1)

                Button {
                    playbackController.skipClips(5)
                } label: {
                    Text("+5")
                        .font(.subheadline.bold())
                        .foregroundColor(playbackController.currentClipIndex < playbackController.clipCount - 5 ? .white : .white.opacity(0.3))
                        .frame(width: 40, height: 32)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(8)
                }
                .disabled(playbackController.currentClipIndex >= playbackController.clipCount - 5)
            }

            Text("Clip \(playbackController.currentClipIndex + 1) of \(playbackController.clipCount)")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var playbackFinishedOverlay: some View {
        VStack(spacing: 16) {
            Button {
                playbackController.restart()
            } label: {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.white)
            }

            Text("Tap to replay")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
        }
    }

    private var exportProgressOverlay: some View {
        ZStack {
            Color.themeSurface.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)

                Text("Exporting...")
                    .font(.headline)
                    .foregroundColor(.white)

                ProgressView(value: videoCombiner.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 200)

                Text("\(Int(videoCombiner.progress * 100))%")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(30)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        }
    }

    private func saveVideo() {
        playbackController.pause()
        isExporting = true

        Task {
            do {
                // Now do the actual video combining
                let outputURL = try await videoCombiner.createCombinedVideo(clips: clips, quality: exportQuality)

                // Save to photo library
                try await videoCombiner.saveToPhotoLibrary(url: outputURL)

                // Clean up temp file
                try? FileManager.default.removeItem(at: outputURL)

                isExporting = false
                playbackController.cleanup()
                onSave()
            } catch {
                isExporting = false
                // Could show an alert here, but for now just log
                print("Export failed: \(error.localizedDescription)")
            }
        }
    }
}
