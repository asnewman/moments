import Foundation
import SwiftData

@Model
final class Project {
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    @Relationship(deleteRule: .cascade) var clips: [VideoClipData]

    init(name: String = "Untitled Project") {
        self.name = name
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.clips = []
    }
}

@Model
final class VideoClipData {
    var assetIdentifier: String
    var trimStart: Double
    var trimEnd: Double
    var originalDuration: Double
    var orderIndex: Int

    init(assetIdentifier: String, trimStart: Double = 0, trimEnd: Double, originalDuration: Double, orderIndex: Int) {
        self.assetIdentifier = assetIdentifier
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.originalDuration = originalDuration
        self.orderIndex = orderIndex
    }

    var trimmedDuration: Double {
        trimEnd - trimStart
    }
}
