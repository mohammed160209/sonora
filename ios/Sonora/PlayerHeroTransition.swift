import Observation
import SwiftUI
import UIKit

/// The cover follows the rounded player, then settles into the pill using the panel's remaining motion.
@MainActor @Observable final class PlayerHeroState {
    @ObservationIgnored private(set) weak var pillView: UIView?
    @ObservationIgnored private weak var mini: PlayerArtworkVisual.Node?
    @ObservationIgnored private weak var expanded: PlayerArtworkVisual.Node?
    @ObservationIgnored private weak var surface: UIView?
    @ObservationIgnored private weak var window: UIWindow?
    @ObservationIgnored private var overlay: UIImageView?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var opening = false
    @ObservationIgnored private var waitingForRelease = false
    @ObservationIgnored private var handoffY: CGFloat = 0
    @ObservationIgnored private var lastY: CGFloat = 0
    @ObservationIgnored private var height: CGFloat = 1
    @ObservationIgnored private var coverRect: CGRect = .zero
    @ObservationIgnored private var handoffRect: CGRect = .zero
    @ObservationIgnored private var targetRect: CGRect = .zero
    @ObservationIgnored private var settleDuration = Layout.playerTransitionDuration
    @ObservationIgnored private var handedOff = false
    @ObservationIgnored private lazy var ticker = Ticker(self)
    #if DEBUG
    @ObservationIgnored private var capturesMotion = false
    @ObservationIgnored private var samples: [[String: Double]] = []
    @ObservationIgnored private var motionStart: CFTimeInterval = 0
    #endif

    func register(_ view: UIView) { pillView = view }
    func register(_ view: PlayerArtworkVisual.Node, role: PlayerArtworkVisual.Role) {
        if role == .mini { mini = view } else { expanded = view }
    }

    /// Record actual source/target bounds before UIKit translates the complete player surface.
    func begin(surface: UIView, opening: Bool, interactive: Bool) {
        finish()
        guard !UIAccessibility.isReduceMotionEnabled, let expanded, !expanded.isPlaceholder, let mini,
              let window = surface.window, expanded.window === window, mini.window === window else { return }
        let rect = expanded.convert(expanded.bounds, to: window)
        guard !rect.isEmpty else { return }
        self.surface = surface; self.window = window; self.opening = opening
        coverRect = rect; height = max(1, surface.bounds.height)
        handoffY = 0; handoffRect = rect
        targetRect = mini.convert(mini.bounds, to: window)
        settleDuration = Layout.playerTransitionDuration
        lastY = opening ? height : 0
        waitingForRelease = interactive && !opening
        #if DEBUG
        capturesMotion = ProcessInfo.processInfo.arguments.contains("--sonora-review-fullscreen")
        samples = []; motionStart = 0
        #endif
        let image = UIImageView(image: expanded.artwork)
        image.contentMode = .scaleAspectFill; image.clipsToBounds = true
        image.isUserInteractionEnabled = false; image.isAccessibilityElement = false; image.alpha = 0
        image.tintColor = expanded.imageView.tintColor
        window.addSubview(image); overlay = image
        let link = CADisplayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
        displayLink = link; link.add(to: .main, forMode: .common)
        update(y: lastY)
    }

    /// Start at the visible release frame, rather than waiting for a late threshold and rushing the cover.
    func release(committing: Bool, settleDuration: TimeInterval) {
        guard !opening else { return }
        waitingForRelease = !committing
        guard committing else { return }
        handoffY = currentY()
        handoffRect = coverRect.offsetBy(dx: 0, dy: handoffY)
        self.settleDuration = settleDuration
        if let mini, let window { targetRect = mini.convert(mini.bounds, to: window) }
        update(y: handoffY)
    }

    private func currentY() -> CGFloat {
        if let value = surface?.layer.presentation()?.affineTransform().ty { lastY = value }
        return min(height, max(0, lastY))
    }
    private func tick() { update(y: currentY()) }

    private func update(y: CGFloat) {
        guard let overlay, let expanded, let mini else { return }
        guard !waitingForRelease else {
            overlay.alpha = 0; expanded.alpha = 1; mini.alpha = 1
            return
        }
        let remaining = max(1, height - handoffY)
        let progress = min(1, max(0, (y - handoffY) / remaining))
        let start = handoffRect
        let target = targetRect
        guard !target.isEmpty else { return }
        // The panel already eases out. Blend that progress with a mild size curve so the
        // cover starts moving on release and spreads its shrink over the whole settle.
        let smooth = progress * progress * (3 - 2 * progress)
        let eased = opening ? smooth : progress * 0.7 + smooth * 0.3
        let tangent = min(remaining, max(0, target.midY - start.midY))
        let bend = progress * (1 - progress) * (1 - progress)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
        let size = CGSize(width: mix(start.width, target.width), height: mix(start.height, target.height))
        let center = CGPoint(x: mix(start.midX, target.midX), y: mix(start.midY, target.midY) + tangent * bend)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        overlay.image = expanded.artwork
        overlay.frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
            width: size.width, height: size.height)
        overlay.layer.cornerRadius = mix(expanded.radius, mini.radius)
        overlay.alpha = 1; expanded.alpha = 0; mini.alpha = 0
        CATransaction.commit()
        if !handedOff { handedOff = true; record("handoff") }
        #if DEBUG
        if capturesMotion, samples.count < 120 {
            let now = CACurrentMediaTime()
            if motionStart == 0 { motionStart = now }
            samples.append(["t": now - motionStart, "progress": Double(progress), "panelY": Double(y),
                "x": Double(overlay.frame.minX), "y": Double(overlay.frame.minY),
                "width": Double(overlay.frame.width), "height": Double(overlay.frame.height)])
        }
        #endif
    }

    /// Restore the real UIKit images synchronously; no SwiftUI opacity update or delayed return jump is needed.
    func finish(completed: Bool = false) {
        if completed, handedOff { update(y: opening ? 0 : height) }
        displayLink?.invalidate(); displayLink = nil
        #if DEBUG
        if capturesMotion, handedOff { recordMotion(completed: completed) }
        #endif
        overlay?.removeFromSuperview(); overlay = nil
        expanded?.alpha = 1; mini?.alpha = 1
        if handedOff { record("restored") }
        surface = nil; window = nil; handedOff = false; waitingForRelease = false
    }
    private func record(_ event: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--sonora-review-fullscreen") else { return }
        let url = URL.applicationSupportDirectory.appendingPathComponent("player-cover-handoff-review.json")
        var events = ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [[String: Any]] ?? []
        events.append(["event": event, "opening": opening, "afterRelease": !waitingForRelease, "startFraction": handoffY / height,
            "sharedPanelProgress": true, "settleDuration": settleDuration,
            "miniWidth": mini?.bounds.width ?? 0, "coverWidth": coverRect.width,
            "sourceAlpha": expanded?.alpha ?? 1, "miniAlpha": mini?.alpha ?? 1])
        if let data = try? JSONSerialization.data(withJSONObject: Array(events.suffix(12))) { try? data.write(to: url, options: .atomic) }
        #endif
    }
    #if DEBUG
    /// Count-only geometry and timestamps let native checks detect rushed motion without screenshots.
    private func recordMotion(completed: Bool) {
        let url = URL.applicationSupportDirectory.appendingPathComponent("player-cover-motion-review.json")
        var events = ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [[String: Any]] ?? []
        events.append(["opening": opening, "completed": completed, "settleDuration": settleDuration,
            "startFraction": handoffY / height, "samples": samples,
            "startX": handoffRect.minX, "startY": handoffRect.minY,
            "startWidth": handoffRect.width, "targetX": targetRect.minX, "targetY": targetRect.minY,
            "targetWidth": targetRect.width])
        if let data = try? JSONSerialization.data(withJSONObject: Array(events.suffix(6))) {
            try? data.write(to: url, options: .atomic)
        }
    }
    #endif
    @MainActor private final class Ticker: NSObject {
        weak var hero: PlayerHeroState?
        init(_ hero: PlayerHeroState) { self.hero = hero }
        @objc func tick(_ link: CADisplayLink) { hero?.tick() }
    }
}

/// Both real cover nodes share the player's high-resolution image; UIKit controls visibility during the final handoff.
struct PlayerArtworkVisual: UIViewRepresentable {
    enum Role: Equatable { case mini, expanded }
    let image: UIImage?
    let hero: PlayerHeroState?
    let role: Role
    let radius: CGFloat
    var shadowOpacity: Float = 0
    var shadowRadius: CGFloat = 0
    var shadowOffset: CGFloat = 0

    func makeUIView(context: Context) -> Node { Node() }
    func updateUIView(_ view: Node, context: Context) {
        view.hero = hero; view.role = role; view.radius = radius
        view.isPlaceholder = image == nil
        view.artwork = image ?? UIImage(systemName: "music.note")
        view.imageView.image = view.artwork
        view.imageView.contentMode = image == nil ? .center : .scaleAspectFill
        view.imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: role == .mini ? Layout.miniTitleSize : Layout.playerPlaySymbol)
        view.imageView.tintColor = .secondaryLabel
        view.imageView.backgroundColor = image == nil ? .tertiarySystemFill : .clear
        view.layer.shadowColor = UIColor.black.cgColor; view.layer.shadowOpacity = shadowOpacity
        view.layer.shadowRadius = shadowRadius; view.layer.shadowOffset = CGSize(width: 0, height: shadowOffset)
        view.setNeedsLayout(); view.report()
    }
    final class Node: UIView {
        weak var hero: PlayerHeroState?
        var role = Role.expanded
        var radius: CGFloat = 0
        var artwork: UIImage?
        var isPlaceholder = true
        let imageView = UIImageView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false; isAccessibilityElement = false
            imageView.clipsToBounds = true; addSubview(imageView)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            imageView.frame = bounds; imageView.layer.cornerRadius = radius
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
            CATransaction.commit(); report()
        }
        func report() { guard window != nil, bounds.width > 0 else { return }; hero?.register(self, role: role) }
    }
}

/// The accessory's outer frame remains available for transition geometry across tab minimization.
struct PlayerHeroAnchor: UIViewRepresentable {
    let hero: PlayerHeroState
    func makeUIView(context: Context) -> Anchor { Anchor(hero: hero) }
    func updateUIView(_ view: Anchor, context: Context) { view.report() }
    final class Anchor: UIView {
        weak var hero: PlayerHeroState?
        init(hero: PlayerHeroState) {
            self.hero = hero; super.init(frame: .zero)
            isUserInteractionEnabled = false; isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        func report() { guard window != nil, bounds.width > 0 else { return }; hero?.register(self) }
    }
}
