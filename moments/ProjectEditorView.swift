import SwiftUI
import PhotosUI
import AVKit
import Photos

enum VideoSortOption {
    case dateNewest
    case dateOldest
    case lengthShortest
    case lengthLongest
}

struct ProjectEditorView: View {
    @Bindable var project: Project
    @Environment(\.modelContext) private var modelContext
    @StateObject private var videoCombiner = VideoCombiner()

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var videoItems: [VideoItem] = []
    @State private var isLoading = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var editingVideoIndex: Int?
    @State private var previewURL: URL?
    @State private var showingPreview = false
    @State private var showingRenameAlert = false
    @State private var newProjectName = ""
    @State private var showingPhotoPicker = false

    var body: some View {
        VStack(spacing: 20) {
            if videoItems.isEmpty && !isLoading {
                emptyStateView
            } else {
                videoListView
            }

            Spacer()

            actionButtons
        }
        .padding()
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        newProjectName = project.name
                        showingRenameAlert = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Button {
                        showingPhotoPicker = true
                    } label: {
                        Label("Add Videos", systemImage: "plus")
                    }

                    Menu {
                        Button {
                            sortVideos(by: .dateNewest)
                        } label: {
                            Label("Date (Newest First)", systemImage: "calendar")
                        }

                        Button {
                            sortVideos(by: .dateOldest)
                        } label: {
                            Label("Date (Oldest First)", systemImage: "calendar")
                        }

                        Button {
                            sortVideos(by: .lengthShortest)
                        } label: {
                            Label("Length (Shortest First)", systemImage: "timer")
                        }

                        Button {
                            sortVideos(by: .lengthLongest)
                        } label: {
                            Label("Length (Longest First)", systemImage: "timer")
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(videoItems.count < 2)

                    Menu {
                        Button {
                            trimAllToMiddle(seconds: 1.0)
                        } label: {
                            Label("1 Second", systemImage: "1.circle")
                        }

                        Button {
                            trimAllToMiddle(seconds: 2.0)
                        } label: {
                            Label("2 Seconds", systemImage: "2.circle")
                        }
                    } label: {
                        Label("Trim All to Middle", systemImage: "scissors")
                    }
                    .disabled(videoItems.count < 2)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Project", isPresented: $showingRenameAlert) {
            TextField("Project Name", text: $newProjectName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    project.name = name
                    project.modifiedAt = Date()
                }
            }
        }
        .alert("Notice", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $selectedItems,
            matching: .videos,
            photoLibrary: .shared()
        )
        .onChange(of: selectedItems) { _, newItems in
            Task {
                await addVideos(from: newItems)
            }
        }
        .overlay {
            if isLoading || videoCombiner.isProcessing {
                loadingOverlay
            }
        }
        .sheet(item: $editingVideoIndex) { index in
            if index < videoItems.count {
                VideoTrimmerView(
                    videoURL: videoItems[index].url,
                    originalDuration: videoItems[index].originalDuration,
                    trimStart: Binding(
                        get: { videoItems[index].trimStart },
                        set: { newValue in
                            videoItems[index].trimStart = newValue
                            updateClipData(at: index)
                        }
                    ),
                    trimEnd: Binding(
                        get: { videoItems[index].trimEnd },
                        set: { newValue in
                            videoItems[index].trimEnd = newValue
                            updateClipData(at: index)
                        }
                    )
                )
            }
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
        .task {
            await loadProjectClips()
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("No Videos")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Add videos to this project to get started")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            PhotosPicker(
                selection: $selectedItems,
                matching: .videos,
                photoLibrary: .shared()
            ) {
                Label("Add Videos", systemImage: "plus")
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var videoListView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Clips")
                    .font(.headline)
                Spacer()
                Text("\(videoItems.count) video\(videoItems.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            List {
                ForEach(Array(videoItems.enumerated()), id: \.element.id) { index, item in
                    Button {
                        editingVideoIndex = index
                    } label: {
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
                                Text("Clip \(index + 1)")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                HStack(spacing: 4) {
                                    Text(formatDuration(item.trimmedDuration))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if item.trimStart > 0 || item.trimEnd < item.originalDuration {
                                        Image(systemName: "scissors")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
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
            if !videoItems.isEmpty {
                Button(action: previewVideo) {
                    Label("Preview", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(videoItems.count < 2 || videoCombiner.isProcessing)
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
                    Text("Processing...")
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

    private func loadProjectClips() async {
        isLoading = true
        videoItems = []

        let sortedClips = project.clips.sorted { $0.orderIndex < $1.orderIndex }

        for clipData in sortedClips {
            if let videoItem = await loadVideoFromAsset(identifier: clipData.assetIdentifier, clipData: clipData) {
                videoItems.append(videoItem)
            }
        }

        isLoading = false
    }

    private func loadVideoFromAsset(identifier: String, clipData: VideoClipData) async -> VideoItem? {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetchResult.firstObject else { return nil }

        let creationDate = asset.creationDate

        return await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    continuation.resume(returning: nil)
                    return
                }

                Task {
                    let thumbnail = await self.generateThumbnail(for: urlAsset)
                    var videoItem = VideoItem(
                        url: urlAsset.url,
                        thumbnail: thumbnail,
                        duration: clipData.originalDuration,
                        creationDate: creationDate
                    )
                    videoItem.trimStart = clipData.trimStart
                    videoItem.trimEnd = clipData.trimEnd
                    videoItem.assetIdentifier = identifier
                    continuation.resume(returning: videoItem)
                }
            }
        }
    }

    private func addVideos(from items: [PhotosPickerItem]) async {
        isLoading = true

        for item in items {
            if let assetIdentifier = item.itemIdentifier {
                // Check if already added
                if project.clips.contains(where: { $0.assetIdentifier == assetIdentifier }) {
                    continue
                }

                if let videoItem = await loadVideoFromPickerItem(item, assetIdentifier: assetIdentifier) {
                    videoItems.append(videoItem)

                    let clipData = VideoClipData(
                        assetIdentifier: assetIdentifier,
                        trimStart: 0,
                        trimEnd: videoItem.originalDuration,
                        originalDuration: videoItem.originalDuration,
                        orderIndex: project.clips.count
                    )
                    project.clips.append(clipData)
                }
            }
        }

        project.modifiedAt = Date()
        selectedItems = []
        isLoading = false
    }

    private func loadVideoFromPickerItem(_ item: PhotosPickerItem, assetIdentifier: String) async -> VideoItem? {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else { return nil }

        let creationDate = asset.creationDate

        return await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    continuation.resume(returning: nil)
                    return
                }

                Task {
                    let duration = try? await urlAsset.load(.duration)
                    let thumbnail = await self.generateThumbnail(for: urlAsset)

                    var videoItem = VideoItem(
                        url: urlAsset.url,
                        thumbnail: thumbnail,
                        duration: duration?.seconds ?? 0,
                        creationDate: creationDate
                    )
                    videoItem.assetIdentifier = assetIdentifier
                    continuation.resume(returning: videoItem)
                }
            }
        }
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

    private func updateClipData(at index: Int) {
        guard index < videoItems.count else { return }
        let item = videoItems[index]

        if let clipIndex = project.clips.firstIndex(where: { $0.assetIdentifier == item.assetIdentifier }) {
            project.clips[clipIndex].trimStart = item.trimStart
            project.clips[clipIndex].trimEnd = item.trimEnd
            project.modifiedAt = Date()
        }
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        videoItems.move(fromOffsets: source, toOffset: destination)

        // Update order indices
        for (index, item) in videoItems.enumerated() {
            if let clipIndex = project.clips.firstIndex(where: { $0.assetIdentifier == item.assetIdentifier }) {
                project.clips[clipIndex].orderIndex = index
            }
        }
        project.modifiedAt = Date()
    }

    private func sortVideos(by option: VideoSortOption) {
        switch option {
        case .dateNewest:
            videoItems.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .dateOldest:
            videoItems.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        case .lengthShortest:
            videoItems.sort { $0.originalDuration < $1.originalDuration }
        case .lengthLongest:
            videoItems.sort { $0.originalDuration > $1.originalDuration }
        }

        // Update order indices in project.clips
        for (index, item) in videoItems.enumerated() {
            if let clipIndex = project.clips.firstIndex(where: { $0.assetIdentifier == item.assetIdentifier }) {
                project.clips[clipIndex].orderIndex = index
            }
        }
        project.modifiedAt = Date()
    }

    private func trimAllToMiddle(seconds: Double) {
        for index in videoItems.indices {
            let video = videoItems[index]
            guard video.originalDuration > seconds else { continue }

            let midpoint = video.originalDuration / 2
            let newTrimStart = midpoint - (seconds / 2)
            let newTrimEnd = midpoint + (seconds / 2)

            videoItems[index].trimStart = newTrimStart
            videoItems[index].trimEnd = newTrimEnd

            // Update persisted clip data
            if let assetId = video.assetIdentifier,
               let clipData = project.clips.first(where: { $0.assetIdentifier == assetId }) {
                clipData.trimStart = newTrimStart
                clipData.trimEnd = newTrimEnd
            }
        }
        project.modifiedAt = Date()
    }

    private func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            let item = videoItems[index]
            if let clipIndex = project.clips.firstIndex(where: { $0.assetIdentifier == item.assetIdentifier }) {
                project.clips.remove(at: clipIndex)
            }
        }
        videoItems.remove(atOffsets: offsets)

        // Reindex remaining clips
        for (index, item) in videoItems.enumerated() {
            if let clipIndex = project.clips.firstIndex(where: { $0.assetIdentifier == item.assetIdentifier }) {
                project.clips[clipIndex].orderIndex = index
            }
        }
        project.modifiedAt = Date()
    }

    private func previewVideo() {
        guard videoItems.count >= 2 else {
            alertMessage = "Please add at least 2 videos to preview"
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

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
