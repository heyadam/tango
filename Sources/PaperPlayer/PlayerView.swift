#if os(iOS)
import PaperEngine
import PaperHost
import PaperModel
import QuartzCore
import SwiftUI
import UIKit

/// Shows a running prototype on a phone and hands it the person's fingers. Everything
/// else a host does is `PrototypeHost`'s; this is the one UIKit view of the player.
public final class PlayerView: UIView {
    public let host: PrototypeHost
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    /// Each finger on the glass, by the number the runtime knows it by.
    private var fingers: [ObjectIdentifier: Int] = [:]
    /// Called when three fingers are held down: the player's own bar, since every other
    /// touch belongs to the prototype.
    public var onMenu: (() -> Void)?

    public init(package: DocumentPackage, sendsRequests: Bool = true) {
        host = PrototypeHost(package: package, sendsRequests: sendsRequests)
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        layer.addSublayer(host.layer)
        host.onWake = { [weak self] in self?.wake() }
        let menu = UILongPressGestureRecognizer(target: self, action: #selector(menuPressed(_:)))
        menu.numberOfTouchesRequired = 3
        menu.minimumPressDuration = 0.6
        addGestureRecognizer(menu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func menuPressed(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began { onMenu?() }
    }

    // MARK: Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        host.layout(in: bounds, fills: true, backingScale: window?.screen.scale ?? traitCollection.displayScale)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // Only a prototype on screen plays video, with its sound.
        host.playsVideo = window != nil
        if window == nil {
            link?.invalidate()
            link = nil
        } else {
            setNeedsLayout()
            wake()
        }
    }

    // MARK: Frame clock

    /// Runs frames until the prototype wants no more; then the display link rests.
    private func wake() {
        guard window != nil else { return }
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            self.link = link
        }
        if link?.isPaused == true {
            lastTimestamp = nil
            link?.isPaused = false
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        let dt: Double
        if let last = lastTimestamp {
            dt = min(max(link.targetTimestamp - last, 0), 1.0 / 20)
        } else {
            dt = min(max(link.duration, 1.0 / 240), 1.0 / 30)
        }
        lastTimestamp = link.targetTimestamp
        if !host.step(dt: dt) { link.isPaused = true }
    }

    // MARK: Touches

    private func point(of touch: UITouch) -> Point2 {
        host.screenPoint(touch.location(in: self))
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            // The lowest number no finger has, so one finger is always finger 0.
            var id = 0
            while fingers.values.contains(id) { id += 1 }
            fingers[ObjectIdentifier(touch)] = id
            host.send(.touchBegan(id: id, point(of: touch)))
        }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = fingers[ObjectIdentifier(touch)] else { continue }
            host.send(.touchChanged(id: id, point(of: touch)))
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = fingers.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            host.send(.touchEnded(id: id, point(of: touch)))
        }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = fingers.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            host.send(.touchCancelled(id: id))
        }
    }
}

/// A prototype, playing, as a SwiftUI view.
struct PlayerSurface: UIViewRepresentable {
    let package: DocumentPackage
    /// Changes to start the prototype over.
    let restart: Int
    let onMenu: () -> Void

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView(package: package)
        view.onMenu = onMenu
        context.coordinator.restart = restart
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.onMenu = onMenu
        if context.coordinator.restart != restart {
            context.coordinator.restart = restart
            view.host.restart()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var restart = 0
    }
}
#endif
