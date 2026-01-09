import SwiftUI
import PhotosUI
import AVKit

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}

struct VideoItem: Identifiable {
    let id = UUID()
    let url: URL
    var thumbnail: UIImage?
    let originalDuration: TimeInterval
    var trimStart: TimeInterval = 0
    var trimEnd: TimeInterval
    var assetIdentifier: String?
    var creationDate: Date?

    var trimmedDuration: TimeInterval {
        trimEnd - trimStart
    }

    init(url: URL, thumbnail: UIImage?, duration: TimeInterval, creationDate: Date? = nil) {
        self.url = url
        self.thumbnail = thumbnail
        self.originalDuration = duration
        self.trimEnd = duration
        self.creationDate = creationDate
    }
}

struct ContentView: View {
    @StateObject private var videoCombiner = VideoCombiner()
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var videoItems: [VideoItem] = []
    @State private var isLoading = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var isShowingEditor = false
    @State private var editingVideoIndex: Int = 0
    @State private var previewURL: URL?
    @State private var showingPreview = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if videoItems.isEmpty {
                    emptyStateView
                } else {
                    videoListView
                }

                Spacer()

                actionButtons
            }
            .padding()
            .navigationTitle("Moments")
            .alert("Notice", isPresented: $showingAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
            .onChange(of: selectedItems) { _, newItems in
                Task {
                    await loadVideos(from: newItems)
                }
            }
            .overlay {
                if isLoading || videoCombiner.isProcessing {
                    loadingOverlay
                }
            }
            .fullScreenCover(isPresented: $isShowingEditor) {
                VideoTrimmerView(
                    videoItems: videoItems,
                    currentIndex: $editingVideoIndex,
                    onTrimChanged: { index, trimStart, trimEnd in
                        guard index < videoItems.count else { return }
                        videoItems[index].trimStart = trimStart
                        videoItems[index].trimEnd = trimEnd
                    },
                    onDelete: { index in
                        deleteItemFromEditor(at: index)
                    }
                )
            }
            .fullScreenCover(isPresented: $showingPreview) {
                if let url = previewURL {
                    VideoPreviewView(
                        videoURL: url,
                        onSave: savePreviewedVideo,
                        onDiscard: discardPreview
                    )
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("No Videos Selected")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select multiple videos from your library to combine them into one")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxHeight: .infinity)
    }

    private var videoListView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Selected Videos")
                    .font(.headline)
                Spacer()
                Text("\(videoItems.count) videos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            List {
                ForEach(Array(videoItems.enumerated()), id: \.element.id) { index, item in
                    Button {
                        editingVideoIndex = index
                        isShowingEditor = true
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption)
                                .fontWeight(.bold)
                                .frame(width: 24, height: 24)
                                .background(Color.themePrimary)
                                .foregroundColor(.white)
                                .clipShape(Circle())

                            if let thumbnail = item.thumbnail {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 60, height: 40)
                                    .clipped()
                                    .cornerRadius(6)
                            } else {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(width: 60, height: 40)
                                    .cornerRadius(6)
                            }

                            VStack(alignment: .leading) {
                                Text("Video \(index + 1)")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                HStack(spacing: 4) {
                                    Text(formatDuration(item.trimmedDuration))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if item.trimStart > 0 || item.trimEnd < item.originalDuration {
                                        Image(systemName: "scissors")
                                            .font(.caption2)
                                            .foregroundStyle(Color.themeSecondary)
                                    }
                                }
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .onMove(perform: moveItems)
                .onDelete(perform: deleteItems)
            }
            .listStyle(.plain)

            HStack {
                Text("Total Duration:")
                    .font(.subheadline)
                Spacer()
                Text(formatDuration(totalDuration))
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 4)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if videoItems.isEmpty {
                PhotosPicker(
                    selection: $selectedItems,
                    matching: .videos,
                    photoLibrary: .shared()
                ) {
                    Label("Select Videos", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.themePrimary.opacity(0.1))
                        .foregroundColor(Color.themePrimary)
                        .cornerRadius(12)
                }
            } else {
                Button(action: previewVideo) {
                    Label("Preview", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.themePrimary)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(videoItems.count < 2 || videoCombiner.isProcessing)

                Button(role: .destructive, action: clearSelection) {
                    Label("Clear All", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .foregroundColor(.red)
                        .cornerRadius(12)
                }
            }
        }
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.themeSurface.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)

                if videoCombiner.isProcessing {
                    Text("Combining videos...")
                        .font(.headline)
                        .foregroundColor(.white)

                    ProgressView(value: videoCombiner.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)

                    Text("\(Int(videoCombiner.progress * 100))%")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                } else {
                    Text("Loading videos...")
                        .font(.headline)
                        .foregroundColor(.white)
                }
            }
            .padding(30)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        }
    }

    private var totalDuration: TimeInterval {
        videoItems.reduce(0) { $0 + $1.trimmedDuration }
    }

    private func loadVideos(from items: [PhotosPickerItem]) async {
        isLoading = true
        videoItems = []

        for item in items {
            do {
                if let movie = try await item.loadTransferable(type: VideoTransferable.self) {
                    let asset = AVURLAsset(url: movie.url)
                    let duration = try await asset.load(.duration)
                    let thumbnail = await generateThumbnail(for: asset)

                    let videoItem = VideoItem(
                        url: movie.url,
                        thumbnail: thumbnail,
                        duration: duration.seconds
                    )
                    videoItems.append(videoItem)
                }
            } catch {
                print("Failed to load video: \(error)")
            }
        }

        isLoading = false
    }

    private func generateThumbnail(for asset: AVURLAsset) async -> UIImage? {
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 400, height: 300)

        do {
            let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    private func previewVideo() {
        guard videoItems.count >= 2 else {
            alertMessage = "Please select at least 2 videos to combine"
            showingAlert = true
            return
        }

        Task {
            do {
                let clips = videoItems.map { item in
                    VideoClip(
                        url: item.url,
                        trimStart: item.trimStart,
                        trimEnd: item.trimEnd
                    )
                }
                let url = try await videoCombiner.createCombinedVideo(clips: clips)
                previewURL = url
                showingPreview = true
            } catch {
                alertMessage = error.localizedDescription
                showingAlert = true
            }
        }
    }

    private func savePreviewedVideo() {
        guard let url = previewURL else { return }

        Task {
            do {
                try await videoCombiner.saveToPhotoLibrary(url: url)
                try? FileManager.default.removeItem(at: url)
                previewURL = nil
                showingPreview = false
                alertMessage = "Video saved to your photo library!"
                showingAlert = true
            } catch {
                alertMessage = error.localizedDescription
                showingAlert = true
            }
        }
    }

    private func discardPreview() {
        if let url = previewURL {
            try? FileManager.default.removeItem(at: url)
        }
        previewURL = nil
        showingPreview = false
    }

    private func clearSelection() {
        selectedItems = []
        videoItems = []
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        videoItems.move(fromOffsets: source, toOffset: destination)
    }

    private func deleteItems(at offsets: IndexSet) {
        videoItems.remove(atOffsets: offsets)
        selectedItems.remove(atOffsets: offsets)
    }

    private func deleteItemFromEditor(at index: Int) {
        guard index < videoItems.count else { return }

        videoItems.remove(at: index)
        if index < selectedItems.count {
            selectedItems.remove(at: index)
        }

        // Navigate to appropriate clip or close editor
        if videoItems.isEmpty {
            isShowingEditor = false
        } else if index >= videoItems.count {
            // Was last item, go to new last item
            editingVideoIndex = videoItems.count - 1
        }
        // Otherwise stay at same index (which now shows the next clip)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: tempURL)
            return Self(url: tempURL)
        }
    }
}

#Preview {
    ContentView()
}
