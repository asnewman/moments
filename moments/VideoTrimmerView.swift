import SwiftUI
import AVKit
import AVFoundation

struct VideoTrimmerView: View {
    let videoURL: URL
    let originalDuration: TimeInterval
    @Binding var trimStart: TimeInterval
    @Binding var trimEnd: TimeInterval
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var thumbnails: [UIImage] = []
    @State private var isDraggingStart = false
    @State private var isDraggingEnd = false
    @State private var isDraggingMiddle = false
    @State private var dragStartTrimStart: TimeInterval = 0
    @State private var dragStartTrimEnd: TimeInterval = 0
    @State private var originalTrimStart: TimeInterval = 0
    @State private var originalTrimEnd: TimeInterval = 0

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
                        Text(formatTime(trimStart))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Duration: \(formatTime(trimmedDuration))")
                            .font(.caption.bold())
                        Spacer()
                        Text(formatTime(trimEnd))
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
            .background(Color.black)
            .navigationTitle("Trim Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Restore original values
                        trimStart = originalTrimStart
                        trimEnd = originalTrimEnd
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            originalTrimStart = trimStart
            originalTrimEnd = trimEnd
            setupPlayer()
            generateThumbnails()
        }
        .onDisappear {
            player?.pause()
        }
    }

    private var videoPlayerView: some View {
        Group {
            if let player = player {
                VideoPlayer(player: player)
                    .disabled(true)
            } else {
                Rectangle()
                    .fill(Color.black)
                    .overlay {
                        ProgressView()
                    }
            }
        }
    }

    private var trimmerTimeline: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let startPosition = (trimStart / originalDuration) * width
            let endPosition = (trimEnd / originalDuration) * width

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
                        .fill(Color.black.opacity(0.6))
                        .frame(width: startPosition)

                    Spacer()

                    Rectangle()
                        .fill(Color.black.opacity(0.6))
                        .frame(width: width - endPosition)
                }
                .frame(height: 50)
                .cornerRadius(8)

                // Selected range border
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.yellow, lineWidth: 3)
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
                                trimStart = (newPosition / width) * originalDuration
                                seekToTime(trimStart)
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
                                trimEnd = (newPosition / width) * originalDuration
                                seekToTime(trimEnd)
                            }
                            .onEnded { _ in
                                isDraggingEnd = false
                            }
                    )

                // Playhead
                if !isDraggingStart && !isDraggingEnd && !isDraggingMiddle {
                    let playheadPosition = (currentTime / originalDuration) * width
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
            let trimDuration = trimEnd - trimStart
            let sliderWidth = max(44, (trimDuration / originalDuration) * width)
            let maxOffset = width - sliderWidth
            let sliderOffset = (trimStart / (originalDuration - trimDuration)) * maxOffset

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.systemGray5))
                    .frame(height: 32)

                // Draggable slider thumb
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.yellow)
                    .frame(width: sliderWidth, height: 32)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.yellow.opacity(0.8), lineWidth: 1)
                    }
                    .overlay {
                        Image(systemName: "arrow.left.and.right")
                            .font(.caption.bold())
                            .foregroundColor(.black)
                    }
                    .offset(x: trimDuration >= originalDuration ? 0 : sliderOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if !isDraggingMiddle {
                                    isDraggingMiddle = true
                                    dragStartTrimStart = trimStart
                                    dragStartTrimEnd = trimEnd
                                }

                                let dragMaxOffset = width - sliderWidth
                                let deltaX = value.translation.width
                                let deltaRatio = dragMaxOffset > 0 ? deltaX / dragMaxOffset : 0
                                let deltaTime = deltaRatio * (originalDuration - trimDuration)

                                var newStart = dragStartTrimStart + deltaTime
                                var newEnd = dragStartTrimEnd + deltaTime

                                // Clamp to bounds
                                if newStart < 0 {
                                    newStart = 0
                                    newEnd = trimDuration
                                }
                                if newEnd > originalDuration {
                                    newEnd = originalDuration
                                    newStart = originalDuration - trimDuration
                                }

                                trimStart = newStart
                                trimEnd = newEnd
                                seekToTime(trimStart)
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
            .fill(Color.yellow)
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
                seekToTime(trimStart)
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title2)
            }

            Button {
                if isPlaying {
                    player?.pause()
                } else {
                    if currentTime >= trimEnd {
                        seekToTime(trimStart)
                    }
                    player?.play()
                }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
            }

            Button {
                seekToTime(trimEnd)
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title2)
            }
        }
        .foregroundColor(.primary)
    }

    private var trimmedDuration: TimeInterval {
        trimEnd - trimStart
    }

    private func setupPlayer() {
        // Configure audio session for playback
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }

        let playerItem = AVPlayerItem(url: videoURL)
        player = AVPlayer(playerItem: playerItem)

        // Add time observer
        player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
            currentTime = time.seconds

            // Loop within trim range
            if currentTime >= trimEnd && isPlaying {
                seekToTime(trimStart)
            }
        }

        seekToTime(trimStart)
    }

    private func seekToTime(_ time: TimeInterval) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    private func generateThumbnails() {
        let asset = AVURLAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 100, height: 100)

        var images: [UIImage] = []
        let interval = originalDuration / Double(thumbnailCount)

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
