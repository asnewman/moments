import SwiftUI
import AVKit
import AVFoundation

struct VideoTrimmerView: View {
    // Video items array for navigation
    let videoItems: [VideoItem]
    @Binding var currentIndex: Int
    let onTrimChanged: (Int, TimeInterval, TimeInterval) -> Void
    var onDelete: ((Int) -> Void)?
    @Environment(\.dismiss) private var dismiss

    // Computed properties for current clip
    private var currentItem: VideoItem? {
        guard currentIndex >= 0 && currentIndex < videoItems.count else { return nil }
        return videoItems[currentIndex]
    }
    private var canGoPrevious: Bool { currentIndex > 0 }
    private var canGoNext: Bool { currentIndex < videoItems.count - 1 }

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var thumbnails: [UIImage] = []
    @State private var isDraggingStart = false
    @State private var isDraggingEnd = false
    @State private var isDraggingMiddle = false
    @State private var dragStartTrimStart: TimeInterval = 0
    @State private var dragStartTrimEnd: TimeInterval = 0

    // Local trim values that sync with the source
    @State private var localTrimStart: TimeInterval = 0
    @State private var localTrimEnd: TimeInterval = 0

    private let thumbnailCount = 10

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Video Player
                videoPlayerView
                    .frame(maxHeight: .infinity)

                // Timeline and controls
                VStack(spacing: 16) {
                    // Current time display
                    HStack {
                        Text(formatTime(localTrimStart))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Duration: \(formatTime(trimmedDuration))")
                            .font(.caption.bold())
                        Spacer()
                        Text(formatTime(localTrimEnd))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    // Position slider for moving the selection
                    positionSlider
                        .padding(.horizontal)

                    // Thumbnail timeline with trim handles
                    trimmerTimeline
                        .padding(.horizontal)

                    // Playback controls
                    playbackControls
                        .padding(.bottom, 8)
                }
                .padding(.vertical)
                .background(Color(.systemBackground))
            }
            .background(Color.themeSurface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .principal) {
                    clipNavigationControls
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .destructive) {
                        player?.pause()
                        onDelete?(currentIndex)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .disabled(videoItems.count <= 1)
                }
            }
        }
        .onAppear {
            loadCurrentClip()
        }
        .onChange(of: currentIndex) { _, _ in
            loadCurrentClip()
        }
        .onDisappear {
            player?.pause()
        }
    }

    private func loadCurrentClip() {
        guard let item = currentItem else { return }
        localTrimStart = item.trimStart
        localTrimEnd = item.trimEnd
        setupPlayer()
        generateThumbnails()
    }

    private var videoPlayerView: some View {
        Group {
            if let player = player {
                VideoPlayer(player: player)
                    .disabled(true)
            } else {
                Rectangle()
                    .fill(Color.themeSurface)
                    .overlay {
                        ProgressView()
                    }
            }
        }
    }

    private var trimmerTimeline: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = currentItem?.originalDuration ?? 1
            let startPosition = (localTrimStart / duration) * width
            let endPosition = (localTrimEnd / duration) * width

            ZStack(alignment: .leading) {
                // Thumbnail strip
                HStack(spacing: 0) {
                    ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, thumbnail in
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width / CGFloat(thumbnailCount), height: 50)
                            .clipped()
                    }
                }
                .frame(height: 50)
                .cornerRadius(8)

                // Dimmed areas outside trim range
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.themeSurface.opacity(0.6))
                        .frame(width: startPosition)

                    Spacer()

                    Rectangle()
                        .fill(Color.themeSurface.opacity(0.6))
                        .frame(width: width - endPosition)
                }
                .frame(height: 50)
                .cornerRadius(8)

                // Selected range border
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.themeSecondary, lineWidth: 3)
                    .frame(width: endPosition - startPosition, height: 50)
                    .offset(x: startPosition)

                // Start handle
                trimHandle(isStart: true)
                    .offset(x: startPosition - 10)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                isDraggingStart = true
                                let newPosition = max(0, min(value.location.x, endPosition - 20))
                                localTrimStart = (newPosition / width) * duration
                                onTrimChanged(currentIndex, localTrimStart, localTrimEnd)
                                seekToTime(localTrimStart)
                            }
                            .onEnded { _ in
                                isDraggingStart = false
                            }
                    )

                // End handle
                trimHandle(isStart: false)
                    .offset(x: endPosition - 10)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                isDraggingEnd = true
                                let newPosition = max(startPosition + 20, min(value.location.x, width))
                                localTrimEnd = (newPosition / width) * duration
                                onTrimChanged(currentIndex, localTrimStart, localTrimEnd)
                                seekToTime(localTrimEnd)
                            }
                            .onEnded { _ in
                                isDraggingEnd = false
                            }
                    )

                // Playhead
                if !isDraggingStart && !isDraggingEnd && !isDraggingMiddle {
                    let playheadPosition = (currentTime / duration) * width
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: 60)
                        .offset(x: playheadPosition - 1)
                }
            }
        }
        .frame(height: 50)
    }

    private var positionSlider: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = currentItem?.originalDuration ?? 1
            let trimDuration = localTrimEnd - localTrimStart
            let sliderWidth = max(44, (trimDuration / duration) * width)
            let maxOffset = width - sliderWidth
            let sliderOffset = (localTrimStart / (duration - trimDuration)) * maxOffset

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.systemGray5))
                    .frame(height: 32)

                // Draggable slider thumb
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.themeSecondary)
                    .frame(width: sliderWidth, height: 32)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.themeSecondary.opacity(0.8), lineWidth: 1)
                    }
                    .overlay {
                        Image(systemName: "arrow.left.and.right")
                            .font(.caption.bold())
                            .foregroundColor(.black)
                    }
                    .offset(x: trimDuration >= duration ? 0 : sliderOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if !isDraggingMiddle {
                                    isDraggingMiddle = true
                                    dragStartTrimStart = localTrimStart
                                    dragStartTrimEnd = localTrimEnd
                                }

                                let dragMaxOffset = width - sliderWidth
                                let deltaX = value.translation.width
                                let deltaRatio = dragMaxOffset > 0 ? deltaX / dragMaxOffset : 0
                                let deltaTime = deltaRatio * (duration - trimDuration)

                                var newStart = dragStartTrimStart + deltaTime
                                var newEnd = dragStartTrimEnd + deltaTime

                                // Clamp to bounds
                                if newStart < 0 {
                                    newStart = 0
                                    newEnd = trimDuration
                                }
                                if newEnd > duration {
                                    newEnd = duration
                                    newStart = duration - trimDuration
                                }

                                localTrimStart = newStart
                                localTrimEnd = newEnd
                                onTrimChanged(currentIndex, localTrimStart, localTrimEnd)
                                seekToTime(localTrimStart)
                            }
                            .onEnded { _ in
                                isDraggingMiddle = false
                            }
                    )
            }
        }
        .frame(height: 32)
    }

    private func trimHandle(isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.themeSecondary)
            .frame(width: 20, height: 50)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.black.opacity(0.3), lineWidth: 1)
            }
            .overlay {
                Image(systemName: isStart ? "chevron.compact.left" : "chevron.compact.right")
                    .foregroundColor(.black)
                    .fontWeight(.bold)
            }
    }

    private var playbackControls: some View {
        HStack(spacing: 40) {
            Button {
                seekToTime(localTrimStart)
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title2)
            }

            Button {
                if isPlaying {
                    player?.pause()
                } else {
                    if currentTime >= localTrimEnd {
                        seekToTime(localTrimStart)
                    }
                    player?.play()
                }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
            }

            Button {
                seekToTime(localTrimEnd)
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title2)
            }
        }
        .foregroundColor(.primary)
    }

    private var clipNavigationControls: some View {
        HStack(spacing: 16) {
            Button {
                player?.pause()
                isPlaying = false
                if canGoPrevious {
                    currentIndex -= 1
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
            }
            .disabled(!canGoPrevious)

            Text("Clip \(currentIndex + 1) of \(videoItems.count)")
                .font(.headline)

            Button {
                player?.pause()
                isPlaying = false
                if canGoNext {
                    currentIndex += 1
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
            }
            .disabled(!canGoNext)
        }
    }

    private var trimmedDuration: TimeInterval {
        localTrimEnd - localTrimStart
    }

    private func setupPlayer() {
        guard let item = currentItem else { return }

        // Configure audio session for playback
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }

        let playerItem = AVPlayerItem(url: item.url)
        player = AVPlayer(playerItem: playerItem)

        // Add time observer
        player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [self] time in
            currentTime = time.seconds

            // Loop within trim range
            if currentTime >= localTrimEnd && isPlaying {
                seekToTime(localTrimStart)
            }
        }

        seekToTime(localTrimStart)
    }

    private func seekToTime(_ time: TimeInterval) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    private func generateThumbnails() {
        guard let item = currentItem else { return }

        let asset = AVURLAsset(url: item.url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 100, height: 100)

        var images: [UIImage] = []
        let interval = item.originalDuration / Double(thumbnailCount)

        for i in 0..<thumbnailCount {
            let time = CMTime(seconds: Double(i) * interval, preferredTimescale: 600)
            do {
                let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
                images.append(UIImage(cgImage: cgImage))
            } catch {
                images.append(UIImage(systemName: "video") ?? UIImage())
            }
        }

        thumbnails = images
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let milliseconds = Int((time.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, milliseconds)
    }
}
