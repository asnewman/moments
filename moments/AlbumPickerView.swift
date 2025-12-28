import SwiftUI
import Photos

struct AlbumItem: Identifiable {
    let id: String
    let collection: PHAssetCollection
    let title: String
    let videoCount: Int
}

struct AlbumRowView: View {
    let album: AlbumItem

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(album.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text("\(album.videoCount) video\(album.videoCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

struct AlbumPickerView: View {
    let onAlbumSelected: (PHAssetCollection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [AlbumItem] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Select Album")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
        }
        .task {
            await loadAlbums()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading albums...")
        } else if albums.isEmpty {
            ContentUnavailableView(
                "No Albums with Videos",
                systemImage: "photo.on.rectangle.angled",
                description: Text("No albums containing videos were found.")
            )
        } else {
            albumList
        }
    }

    private var albumList: some View {
        List(albums) { album in
            Button {
                onAlbumSelected(album.collection)
                dismiss()
            } label: {
                AlbumRowView(album: album)
            }
        }
    }

    private func loadAlbums() async {
        var albumItems: [AlbumItem] = []

        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .any,
            options: nil
        )

        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )

        smartAlbums.enumerateObjects { collection, _, _ in
            if let item = createAlbumItem(from: collection) {
                albumItems.append(item)
            }
        }

        userAlbums.enumerateObjects { collection, _, _ in
            if let item = createAlbumItem(from: collection) {
                albumItems.append(item)
            }
        }

        albumItems.sort { $0.videoCount > $1.videoCount }

        await MainActor.run {
            self.albums = albumItems
            self.isLoading = false
        }
    }

    private func createAlbumItem(from collection: PHAssetCollection) -> AlbumItem? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)
        let assets = PHAsset.fetchAssets(in: collection, options: options)

        guard assets.count > 0 else { return nil }

        let title = collection.localizedTitle ?? "Untitled Album"

        return AlbumItem(
            id: collection.localIdentifier,
            collection: collection,
            title: title,
            videoCount: assets.count
        )
    }
}
