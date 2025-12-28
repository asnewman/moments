import AVFoundation
import Photos

enum ExportQuality: String, CaseIterable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case highest = "highest"

    var presetName: String {
        switch self {
        case .low:
            return AVAssetExportPresetLowQuality
        case .medium:
            return AVAssetExportPresetMediumQuality
        case .high:
            return AVAssetExportPreset1920x1080
        case .highest:
            return AVAssetExportPresetHighestQuality
        }
    }

    var displayName: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High (1080p)"
        case .highest:
            return "Highest"
        }
    }
}

enum VideoCombinerError: LocalizedError {
    case noVideosProvided
    case failedToLoadAsset(URL)
    case failedToCreateExportSession
    case exportFailed(String)
    case failedToSaveToLibrary(Error)
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case .noVideosProvided:
            return "No videos provided to combine"
        case .failedToLoadAsset(let url):
            return "Failed to load video: \(url.lastPathComponent)"
        case .failedToCreateExportSession:
            return "Failed to create export session"
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        case .failedToSaveToLibrary(let error):
            return "Failed to save to photo library: \(error.localizedDescription)"
        case .noVideoTrack:
            return "No video track found"
        }
    }
}

struct VideoClip {
    let url: URL
    let trimStart: TimeInterval
    let trimEnd: TimeInterval

    var duration: TimeInterval {
        trimEnd - trimStart
    }
}

struct VideoSegmentInfo {
    let clip: VideoClip
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let displaySize: CGSize
}

@MainActor
class VideoCombiner: ObservableObject {
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var errorMessage: String?
    @Published var isComplete = false

    func createCombinedVideo(clips: [VideoClip], quality: ExportQuality = .highest) async throws -> URL {
        guard !clips.isEmpty else {
            throw VideoCombinerError.noVideosProvided
        }

        isProcessing = true
        progress = 0
        errorMessage = nil
        isComplete = false

        defer {
            isProcessing = false
        }

        // First pass: gather info about all videos
        var segments: [VideoSegmentInfo] = []
        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            do {
                let videoTracks = try await asset.loadTracks(withMediaType: .video)

                guard let videoTrack = videoTracks.first else {
                    throw VideoCombinerError.noVideoTrack
                }

                let naturalSize = try await videoTrack.load(.naturalSize)
                let preferredTransform = try await videoTrack.load(.preferredTransform)

                // Calculate the actual display size by applying the transform
                let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
                let displaySize = CGSize(
                    width: abs(transformedRect.width),
                    height: abs(transformedRect.height)
                )

                segments.append(VideoSegmentInfo(
                    clip: clip,
                    naturalSize: naturalSize,
                    preferredTransform: preferredTransform,
                    displaySize: displaySize
                ))
            } catch {
                throw VideoCombinerError.failedToLoadAsset(clip.url)
            }
        }

        // Determine render size (use the largest dimensions, ensure portrait)
        var renderWidth: CGFloat = 0
        var renderHeight: CGFloat = 0
        for segment in segments {
            renderWidth = max(renderWidth, segment.displaySize.width)
            renderHeight = max(renderHeight, segment.displaySize.height)
        }
        // Ensure portrait (height >= width)
        if renderWidth > renderHeight {
            swap(&renderWidth, &renderHeight)
        }
        let renderSize = CGSize(width: renderWidth, height: renderHeight)

        // Create composition
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ),
        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoCombinerError.failedToCreateExportSession
        }

        // Second pass: add video segments and create instructions
        var currentTime = CMTime.zero
        var videoInstructions: [AVMutableVideoCompositionInstruction] = []
        let totalVideos = Double(segments.count)

        for (index, segment) in segments.enumerated() {
            let asset = AVURLAsset(url: segment.clip.url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)

            // Calculate the time range based on trim points
            let trimStartTime = CMTime(seconds: segment.clip.trimStart, preferredTimescale: 600)
            let trimEndTime = CMTime(seconds: segment.clip.trimEnd, preferredTimescale: 600)
            let trimDuration = CMTimeSubtract(trimEndTime, trimStartTime)
            let timeRange = CMTimeRange(start: trimStartTime, duration: trimDuration)

            if let assetVideoTrack = videoTracks.first {
                try compositionVideoTrack.insertTimeRange(timeRange, of: assetVideoTrack, at: currentTime)

                // Create transform for this segment
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
                try compositionAudioTrack.insertTimeRange(timeRange, of: assetAudioTrack, at: currentTime)
            }

            currentTime = CMTimeAdd(currentTime, trimDuration)
            progress = Double(index + 1) / totalVideos * 0.5
        }

        // Create video composition
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = videoInstructions

        // Export
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: quality.presetName
        ) else {
            throw VideoCombinerError.failedToCreateExportSession
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.videoComposition = videoComposition

        // Monitor export progress
        let progressTask = Task {
            while exportSession.status == .waiting || exportSession.status == .exporting {
                // Progress goes from 50% to 100% during export
                let exportProgress = exportSession.progress
                await MainActor.run {
                    self.progress = 0.5 + Double(exportProgress) * 0.5
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        await exportSession.export()
        progressTask.cancel()

        progress = 1.0

        switch exportSession.status {
        case .completed:
            isComplete = true
            return outputURL

        case .failed:
            let errorMsg = exportSession.error?.localizedDescription ?? "Unknown error"
            throw VideoCombinerError.exportFailed(errorMsg)

        case .cancelled:
            throw VideoCombinerError.exportFailed("Export was cancelled")

        default:
            throw VideoCombinerError.exportFailed("Unexpected export status")
        }
    }

    private func calculateTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        displaySize: CGSize,
        renderSize: CGSize
    ) -> CGAffineTransform {
        // Step 1: Apply preferredTransform to see where the video rect ends up
        let originalRect = CGRect(origin: .zero, size: naturalSize)
        let transformedRect = originalRect.applying(preferredTransform)

        // Step 2: Calculate scale to fit displaySize into renderSize (maintain aspect ratio)
        let scaleX = renderSize.width / displaySize.width
        let scaleY = renderSize.height / displaySize.height
        let scale = min(scaleX, scaleY)

        // Step 3: Calculate centering offset
        let scaledWidth = displaySize.width * scale
        let scaledHeight = displaySize.height * scale
        let offsetX = (renderSize.width - scaledWidth) / 2
        let offsetY = (renderSize.height - scaledHeight) / 2

        // Step 4: Build the final transform
        // We need to:
        // a) Apply the preferredTransform (rotates/flips the video correctly)
        // b) Translate so the transformed rect's origin is at (0, 0)
        // c) Scale to fit
        // d) Translate to center

        let moveToOrigin = CGAffineTransform(
            translationX: -transformedRect.origin.x,
            y: -transformedRect.origin.y
        )

        let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)

        let centerTransform = CGAffineTransform(translationX: offsetX, y: offsetY)

        // Chain transforms: preferredTransform -> moveToOrigin -> scale -> center
        let finalTransform = preferredTransform
            .concatenating(moveToOrigin)
            .concatenating(scaleTransform)
            .concatenating(centerTransform)

        return finalTransform
    }

    func saveToPhotoLibrary(url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
