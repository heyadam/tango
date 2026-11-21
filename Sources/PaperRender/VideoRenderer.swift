import AVFoundation
import CoreVideo
import Foundation
import QuartzCore

/// Holds what a piece of asynchronous work produced, for a caller that waits for it.
private nonisolated final class Outcome<T>: @unchecked Sendable {
    var value: T?
}

/// Runs AVFoundation's asynchronous loading and waits for it, at most `timeout` seconds.
/// The loading happens on AVFoundation's own queues, so waiting on the main thread is safe.
/// A time in seconds as a `CMTime`, kept to a range a 64-bit count of 1/600 s can hold:
/// a cabled time of 1e20 must not stop the app.
func videoTime(_ seconds: Double) -> CMTime {
    let kept = seconds.isFinite ? min(max(seconds, 0), 1e9) : 0
    return CMTime(value: CMTimeValue((kept * 600).rounded()), timescale: 600)
}

private func waitFor<T>(timeout: Double = 3, _ work: @escaping @Sendable () async throws -> T) -> T? {
    let outcome = Outcome<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        outcome.value = try? await work()
        done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success else { return nil }
    return outcome.value
}

/// Pictures of local video files at exact times, made at once. This is how a video is drawn
/// wherever nothing plays it: pictures for the assistant, `papertool`, recordings made
/// without a window, the gallery and the Canvas. So a video shows the same frame for the
/// same playhead every time.
public final class VideoStills {
    public static let shared = VideoStills()

    private final class Entry {
        let generator: AVAssetImageGenerator
        let duration: Double?

        init(generator: AVAssetImageGenerator, duration: Double?) {
            self.generator = generator
            self.duration = duration
        }
    }

    private var entries: [URL: Entry] = [:]
    private var pictures: [String: CGImage] = [:]
    private var order: [String] = []
    private var missing: Set<String> = []

    private func entry(for url: URL) -> Entry? {
        guard url.isFileURL else { return nil }
        if let known = entries[url] { return known }
        let asset = AVURLAsset(url: url)
        let seconds = waitFor { try await asset.load(.duration).seconds }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 2048, height: 2048)
        let entry = Entry(generator: generator, duration: seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        if entries.count > 40 { entries.removeAll() }
        entries[url] = entry
        return entry
    }

    /// How long the video in a file is, or nil when it cannot be read.
    public func duration(of url: URL) -> Double? { entry(for: url)?.duration }

    /// The frame showing at `time` seconds. A time past the end shows the last frame.
    public func picture(of url: URL, at time: Double) -> CGImage? {
        guard let entry = entry(for: url), time.isFinite else { return nil }
        // The last frame starts before the end, so the end itself has no picture.
        let last = max((entry.duration ?? .infinity) - 1.0 / 600, 0)
        let at = videoTime(min(time, last))
        let key = "\(url.path)|\(at.value)"
        if let known = pictures[key] { return known }
        // A frame that could not be made is not tried again on every render.
        if missing.contains(key) { return nil }
        nonisolated(unsafe) let generator = entry.generator
        guard let image = waitFor(timeout: 2, { try await generator.image(at: at).image }) else {
            if missing.count > 200 { missing.removeAll() }
            missing.insert(key)
            return nil
        }
        pictures[key] = image
        order.append(key)
        if order.count > 90 { pictures[order.removeFirst()] = nil }
        return image
    }
}

/// Plays a video for the Viewer, with its sound, following the playhead the runtime keeps:
/// it plays at the prototype's rate while the playhead moves, and seeks when they drift
/// apart or the playhead jumps. Its frames are put on `picture` as IOSurfaces, which a
/// recording made from the Viewer can capture.
final class VideoPlayer {
    let url: URL
    /// The layer the frames are shown on, and a glyph shown until there is one.
    weak var picture: CALayer?
    weak var glyph: CALayer?
    /// Called once the video's length is known.
    var onDuration: ((Double) -> Void)?
    /// Called if the video cannot be played.
    var onFailure: (() -> Void)?

    private let item: AVPlayerItem
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var observation: NSKeyValueObservation?
    private var target = 0.0
    private var playing = false
    private var rate = 1.0
    private var seeking = false
    private var wanted: Double?
    private var lastSeek: Double?
    /// Asks for a frame for a moment after a seek, when nothing else draws.
    private var poll: Timer?
    /// The last frames shown, kept so their surfaces are not reused while on screen.
    private var held: [CVPixelBuffer] = []

    init(url: URL) {
        self.url = url
        item = AVPlayerItem(url: url)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        // The runtime decides what happens at the end.
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        let changed: @Sendable (AVPlayerItem, NSKeyValueObservedChange<AVPlayerItem.Status>) -> Void = { [weak self] _, _ in
            Task { @MainActor in self?.statusChanged() }
        }
        observation = item.observe(\.status, options: [.initial], changeHandler: changed)
    }

    var isReady: Bool { item.status == .readyToPlay }

    private func statusChanged() {
        if item.status == .failed { onFailure?() }
        guard item.status == .readyToPlay else { return }
        let seconds = item.duration.seconds
        if seconds.isFinite, seconds > 0 { onDuration?(seconds) }
        apply()
        showSoon()
    }

    /// Follows the runtime's playhead for this frame.
    func follow(time: Double, playing: Bool, rate: Double, muted: Bool, volume: Double) {
        target = time
        self.playing = playing
        self.rate = rate
        player.isMuted = muted
        player.volume = Float(min(max(volume.isFinite ? volume : 1, 0), 1))
        guard isReady else { return }
        apply()
        pullFrame()
    }

    private func apply() {
        let now = player.currentTime().seconds
        let canPlay = rate > 0 || (rate < 0 && item.canPlayReverse)
        if playing, canPlay {
            // Close enough is left alone: a seek while playing is a visible hitch.
            if !now.isFinite || abs(now - target) > 0.25 { seek(to: target) }
            if player.rate != Float(rate) { player.rate = Float(rate) }
        } else {
            if player.rate != 0 { player.pause() }
            if !now.isFinite || abs(now - target) > 0.5 / 60 { seek(to: target) }
        }
    }

    private func seek(to time: Double) {
        if seeking {
            wanted = time
            return
        }
        if let lastSeek, abs(lastSeek - time) < 0.5 / 600, !playing { return }
        seeking = true
        lastSeek = time
        let at = videoTime(time)
        player.seek(to: at, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                if let next = self.wanted {
                    self.wanted = nil
                    self.seek(to: next)
                } else {
                    self.showSoon()
                }
            }
        }
    }

    /// Looks for a frame each sixtieth of a second for half a second: after a seek or once
    /// loaded the picture changes while the prototype itself may be asking for no frames.
    private func showSoon() {
        poll?.invalidate()
        tries = 0
        poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tryShowing() }
        }
    }

    private var tries = 0

    private func tryShowing() {
        tries += 1
        if pullFrame() || tries >= 30 {
            poll?.invalidate()
            poll = nil
        }
    }

    /// Shows the newest frame there is. Returns whether there was one.
    @discardableResult
    private func pullFrame() -> Bool {
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture?.contents = surface
        glyph?.isHidden = true
        CATransaction.commit()
        held.insert(buffer, at: 0)
        if held.count > 3 { held.removeLast() }
        return true
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        observation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
