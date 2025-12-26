import SwiftUI
import PhotosUI
import AVKit

struct VideoItem: Identifiable {
    let id = UUID()
    let url: URL
    var thumbnail: UIImage?
    let duration: TimeInterval
}

struct ContentView: View {
    @StateObject private var videoCombiner = VideoCombiner()
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var videoItems: [VideoItem] = []
    @State private var isLoading = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

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
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .frame(width: 24, height: 24)
                            .background(Color.accentColor)
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
                            Text(formatDuration(item.duration))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 4)
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
            PhotosPicker(
                selection: $selectedItems,
                maxSelectionCount: 20,
                matching: .videos,
                photoLibrary: .shared()
            ) {
                Label(
                    videoItems.isEmpty ? "Select Videos" : "Change Selection",
                    systemImage: "photo.on.rectangle.angled"
                )
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor.opacity(0.1))
                .foregroundColor(.accentColor)
                .cornerRadius(12)
            }

            if !videoItems.isEmpty {
                Button(action: combineVideos) {
                    Label("Combine Videos", systemImage: "arrow.triangle.merge")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
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
            Color.black.opacity(0.4)
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
        videoItems.reduce(0) { $0 + $1.duration }
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
        imageGenerator.maximumSize = CGSize(width: 120, height: 80)

        do {
            let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    private func combineVideos() {
        guard videoItems.count >= 2 else {
            alertMessage = "Please select at least 2 videos to combine"
            showingAlert = true
            return
        }

        Task {
            do {
                let urls = videoItems.map { $0.url }
                try await videoCombiner.combineVideos(urls: urls)
                alertMessage = "Videos combined successfully and saved to your photo library!"
                showingAlert = true
            } catch {
                alertMessage = error.localizedDescription
                showingAlert = true
            }
        }
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
