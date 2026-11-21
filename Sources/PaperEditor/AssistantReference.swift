import AVFoundation
import AppKit
import Foundation
import PaperEngine
import PaperModel
import UniformTypeIdentifiers

/// Something the person points the assistant at along with a message: a view or a patch
/// in the document, or a picture or video of what they want.
public struct AssistantReference: Identifiable, Equatable {
    public enum Target: Equatable {
        case view(LayerID)
        case patch(NodeID)
        case media(AssistantMedia)
    }

    public let id: UUID
    public var target: Target

    public init(_ target: Target) {
        id = UUID()
        self.target = target
    }

    /// How a reference is drawn: in the composer before sending, and in the transcript after.
    public struct Chip: Identifiable, Equatable {
        public let id: UUID
        public var title: String
        public var symbol: String
        public var target: Target
        /// A small picture, for media.
        public var thumbnail: Data?
    }

    /// The chip for this reference, or nil when the view or patch it names is gone.
    public func chip(in store: DocumentStore) -> Chip? {
        switch target {
        case let .view(layer):
            guard let layer = store.document.layer(layer) else { return nil }
            return Chip(id: id, title: layer.name, symbol: layer.type.symbolName, target: target)
        case let .patch(node):
            guard let node = store.document.graph.node(node) else { return nil }
            return Chip(id: id, title: store.title(for: node), symbol: "point.3.connected.trianglepath.dotted", target: target)
        case let .media(media):
            return Chip(
                id: id, title: media.name, symbol: media.isVideo ? "film" : "photo",
                target: target, thumbnail: media.thumbnail
            )
        }
    }
}

/// A picture, or a video as the frames picked out of it. Claude does not watch video, so
/// a video travels as stills with the time each was taken.
public struct AssistantMedia: Equatable {
    public struct Frame: Equatable {
        /// Seconds into the video; 0 for a picture.
        public var time: Double
        /// JPEG data.
        public var data: Data
    }

    public var name: String
    public var frames: [Frame]
    /// A video's length in seconds; nil for a picture.
    public var duration: Double?
    public var thumbnail: Data?

    public var isVideo: Bool { duration != nil }
}

public struct AssistantMediaError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Reads pictures and videos into what can be sent to Claude.
public enum AssistantMediaLoader {
    /// The longest side of a picture, and of a video frame, in pixels.
    static let imageSide: CGFloat = 1568
    static let frameSide: CGFloat = 768
    /// How many stills stand for a video: about three a second, within these bounds.
    static let frameCounts = 4...12

    public static let fileTypes: [UTType] = [.image, .movie]

    public static func canLoad(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return fileTypes.contains { type.conforms(to: $0) }
    }

    public static func load(_ url: URL) async throws -> AssistantMedia {
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .movie) == true { return try await video(url, name: name) }
        guard let image = NSImage(contentsOf: url), let media = picture(image, name: name) else {
            throw AssistantMediaError(message: "\(name) is not a picture or video that can be read.")
        }
        return media
    }

    public static func picture(_ image: NSImage, name: String) -> AssistantMedia? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = jpeg(cgImage, longestSide: imageSide, quality: 0.85)
        else { return nil }
        return AssistantMedia(
            name: name, frames: [.init(time: 0, data: data)], duration: nil,
            thumbnail: jpeg(cgImage, longestSide: 160, quality: 0.7)
        )
    }

    /// The times stills are taken at: evenly through the video, the first and the last included.
    static func frameTimes(duration: Double) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [0] }
        let count = min(max((duration * 3).whole, frameCounts.lowerBound), frameCounts.upperBound)
        // The very end of a movie often has no picture to give.
        let last = max(duration - 0.05, 0)
        return (0..<count).map { last * Double($0) / Double(count - 1) }
    }

    static func video(_ url: URL, name: String) async throws -> AssistantMedia {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else {
            throw AssistantMediaError(message: "\(name) could not be read as a video.")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: frameSide, height: frameSide)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 20)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 20)
        var frames: [AssistantMedia.Frame] = []
        var thumbnail: Data?
        for time in frameTimes(duration: duration) {
            guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image,
                  let data = jpeg(image, longestSide: frameSide, quality: 0.75)
            else { continue }
            if thumbnail == nil { thumbnail = jpeg(image, longestSide: 160, quality: 0.7) }
            frames.append(.init(time: time, data: data))
        }
        guard !frames.isEmpty else {
            throw AssistantMediaError(message: "No pictures could be read from \(name).")
        }
        return AssistantMedia(name: name, frames: frames, duration: duration, thumbnail: thumbnail)
    }

    /// JPEG data of an image, made smaller when its longest side is over `longestSide`.
    static func jpeg(_ image: CGImage, longestSide: CGFloat, quality: CGFloat) -> Data? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width >= 1, height >= 1 else { return nil }
        let scale = min(1, longestSide / max(width, height))
        let pixelWidth = max(Int((width * scale).rounded()), 1), pixelHeight = max(Int((height * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        // JPEG has no transparency: what is clear becomes white.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}

/// A message as it goes to Claude: the text the model reads and the pictures after it.
public struct AssistantMessage {
    public struct Picture: Equatable {
        /// A line the model reads just before the picture.
        public var label: String
        public var data: Data
    }

    public var text: String
    public var pictures: [Picture] = []

    /// What the person typed, with what they pointed at and what is selected written out.
    public static func make(_ typed: String, references: [AssistantReference], selection: Bool = true, store: DocumentStore) -> AssistantMessage {
        var notes: [String] = []
        if selection {
            let context = selectionNote(of: store)
            if !context.isEmpty { notes.append(context) }
        } else if let scope = store.scope, let component = store.fullDocument.component(scope) {
            notes.append("[Editing inside the component \"\(component.name)\".]")
        }

        var lines: [String] = []
        var pictures: [Picture] = []
        for reference in references {
            switch reference.target {
            case let .view(id):
                if let line = describe(view: id, in: store) { lines.append("- " + line) }
            case let .patch(id):
                if let line = describe(patch: id, in: store) { lines.append("- " + line) }
            case let .media(media):
                let first = pictures.count + 1
                if let duration = media.duration {
                    for frame in media.frames {
                        pictures.append(Picture(
                            label: "Image \(pictures.count + 1): \"\(media.name)\" at \(seconds(frame.time)) of \(seconds(duration))",
                            data: frame.data
                        ))
                    }
                    let range = media.frames.count == 1 ? "image \(first) is a still" : "images \(first) to \(pictures.count) are stills in order"
                    lines.append("- Video \"\(media.name)\", \(seconds(duration)) long: \(range), each labelled with its time. Read them as one motion: what moves, how far, how fast, and with what easing.")
                } else if let frame = media.frames.first {
                    pictures.append(Picture(label: "Image \(first): \"\(media.name)\"", data: frame.data))
                    lines.append("- Picture \"\(media.name)\": image \(first).")
                }
            }
        }
        if !lines.isEmpty {
            notes.append("[The person attached these to the message. \"This\" and \"these\" mean them.\n" + lines.joined(separator: "\n") + "]")
        }
        return AssistantMessage(text: (notes.isEmpty ? "" : notes.joined(separator: "\n") + "\n\n") + typed, pictures: pictures)
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.1f s", value)
    }

    /// What is selected at the moment a message is sent.
    static func selectionNote(of store: DocumentStore) -> String {
        var lines: [String] = []
        let document = store.document
        let layers = document.screen.flattened.filter { store.selectedLayers.contains($0.id) }
        if !layers.isEmpty {
            lines.append("Selected views: " + layers.map { "\($0.name) (\(AssistantToolbox.short($0.id)))" }.joined(separator: ", "))
        }
        let patches = document.graph.patches.filter { store.selectedNodes.contains($0.id) }
        if !patches.isEmpty {
            lines.append("Selected patches: " + patches.map { "\(store.title(for: $0)) (\(AssistantToolbox.short($0.id)))" }.joined(separator: ", "))
        }
        if let scope = store.scope, let component = store.fullDocument.component(scope) {
            lines.append("Editing inside the component \"\(component.name)\".")
        }
        return lines.isEmpty ? "" : "[" + lines.joined(separator: " ") + "]"
    }

    static func describe(view id: LayerID, in store: DocumentStore) -> String? {
        let document = store.document
        guard let layer = document.layer(id) else { return nil }
        var line = "View \"\(layer.name)\" (\(AssistantToolbox.short(id))), a \(layer.type.rawValue)"
        if let parent = document.screen.parent(of: id) { line += " in \"\(parent.name)\"" }
        if !layer.children.isEmpty {
            line += ", holding " + layer.children.prefix(8).map { "\"\($0.name)\"" }.joined(separator: ", ")
            if layer.children.count > 8 { line += " and \(layer.children.count - 8) more" }
        }
        if let node = document.graph.nodes.first(where: { $0.kind == PatchKind.view && $0.layerID == id }) {
            line += cables(of: node.id, in: store)
        }
        let attached = document.graph.patches.filter { $0.layerID == id }
        if !attached.isEmpty {
            line += ". Attached: " + attached.map { "\(store.title(for: $0)) (\(AssistantToolbox.short($0.id)))" }.joined(separator: ", ")
        }
        return line
    }

    static func describe(patch id: NodeID, in store: DocumentStore) -> String? {
        let document = store.document
        guard let node = document.graph.node(id) else { return nil }
        if node.kind == PatchKind.view, let layer = node.layerID { return describe(view: layer, in: store) }
        var line = "Patch \"\(store.title(for: node))\" (\(AssistantToolbox.short(id))), kind `\(node.kind)`"
        if let layer = node.layerID.flatMap({ document.layer($0) }) { line += ", attached to \"\(layer.name)\"" }
        if let home = node.home.flatMap({ document.layer($0) }) { line += ", kept in \"\(home.name)\"" }
        return line + cables(of: id, in: store)
    }

    /// The cables on a patch, by name, so the model sees how it is wired without asking.
    private static func cables(of id: NodeID, in store: DocumentStore) -> String {
        let graph = store.document.graph
        func name(_ node: NodeID) -> String { graph.node(node).map { store.title(for: $0) } ?? "?" }
        let into = graph.connections.filter { $0.to.node == id }.map { "\(name($0.from.node)).\($0.from.port) -> \($0.to.port)" }
        let out = graph.connections.filter { $0.from.node == id }.map { "\($0.from.port) -> \(name($0.to.node)).\($0.to.port)" }
        var parts: [String] = []
        if !into.isEmpty { parts.append("cables in: " + into.prefix(12).joined(separator: "; ")) }
        if !out.isEmpty { parts.append("cables out: " + out.prefix(12).joined(separator: "; ")) }
        return parts.isEmpty ? "" : ". " + parts.joined(separator: ". ")
    }
}
