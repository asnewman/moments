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

    private var clips: [VideoClip] = []
    private var timeObserver: Any?

    var clipCount: Int {
        clips.count
    }

    func configure(with clips: [VideoClip]) {
        self.clips = clips
        currentClipIndex = 0
        isFinished = false

        // Configure audio session for playback
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }

        loadClip(at: 0)
    }

    private func loadClip(at index: Int) {
        guard index < clips.count else {
            isPlaying = false
            isFinished = true
            totalProgress = 1.0
            return
        }

        let clip = clips[index]
        let playerItem = AVPlayerItem(url: clip.url)
        let player = AVPlayer(playerItem: playerItem)

        // Remove existing time observer
        if let observer = timeObserver, let oldPlayer = currentPlayer {
            oldPlayer.removeTimeObserver(observer)
            timeObserver = nil
        }

        currentPlayer = player
        setupTimeObserver(for: player, clip: clip)

        // Seek to trim start and play
        let startTime = CMTime(seconds: clip.trimStart, preferredTimescale: 600)
        if clip.trimStart > 0 {
            player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        if isPlaying {
            player.play()
        }
    }

    private func setupTimeObserver(for player: AVPlayer, clip: VideoClip) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }

            let currentTime = time.seconds

            // Check if we've reached the trim end
            if currentTime >= clip.trimEnd - 0.05 {
                self.advanceToNextClip()
                return
            }

            // Update total progress
            self.updateTotalProgress(currentTime: currentTime, clip: clip)
        }
    }

    private func advanceToNextClip() {
        currentPlayer?.pause()

        // Remove observer before advancing
        if let observer = timeObserver, let player = currentPlayer {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }

        currentClipIndex += 1
        loadClip(at: currentClipIndex)
    }

    private func updateTotalProgress(currentTime: Double, clip: VideoClip) {
        let totalDuration = clips.reduce(0) { $0 + $1.duration }
        guard totalDuration > 0 else { return }

        let completedDuration = clips.prefix(currentClipIndex).reduce(0) { $0 + $1.duration }
        let currentClipProgress = max(0, currentTime - clip.trimStart)
        totalProgress = (completedDuration + currentClipProgress) / totalDuration
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
        loadClip(at: 0)
        isPlaying = true
    }

    func cleanup() {
        if let observer = timeObserver, let player = currentPlayer {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        currentPlayer?.pause()
        currentPlayer = nil
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
                Color.black.ignoresSafeArea()

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
            .toolbarBackground(Color.black.opacity(0.8), for: .navigationBar)
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
        VStack(spacing: 8) {
            ProgressView(value: playbackController.totalProgress)
                .progressViewStyle(.linear)
                .tint(.white)

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
            Color.black.opacity(0.6)
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
