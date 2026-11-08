import UIKit

/// The trackpad surface. Classifies raw touches the way a Mac trackpad does:
/// 1 finger moves / taps / tap-and-drag, 2 fingers scroll / right-click,
/// 3–4 finger swipes and 4-finger pinch/spread become system gestures.
final class PadView: UIView {
    var onMove: ((CGFloat, CGFloat) -> Void)?
    var onButton: ((String, Bool) -> Void)?
    var onScroll: ((CGFloat, CGFloat) -> Void)?
    var onGesture: ((String) -> Void)?

    var pointerSpeed: CGFloat = 1.6
    var scrollSpeed: CGFloat = 1.2

    private var active = Set<UITouch>()
    private var maxTouches = 0
    private var startedAt: TimeInterval = 0
    private var lastCentroid = CGPoint.zero
    private var lastMoveAt: TimeInterval = 0
    private var travel: CGFloat = 0
    private var swipeAccum = CGPoint.zero
    private var spreadStart: CGFloat = 0
    private var gestureFired = false
    private var dragging = false
    private var lastTapEnd: TimeInterval = 0
    private var lastTapPoint = CGPoint.zero

    private var scrollVelocity = CGPoint.zero
    private var momentum: CADisplayLink?

    private let tapHaptic = UIImpactFeedbackGenerator(style: .light)
    private let gestureHaptic = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        tapHaptic.prepare()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasIdle = active.isEmpty
        active.formUnion(touches)
        let now = CACurrentMediaTime()
        if wasIdle {
            stopMomentum()
            startedAt = now
            maxTouches = 0
            travel = 0
            gestureFired = false
            swipeAccum = .zero
            // Second touch-down right after a tap → hold the button (drag, or double-click on release).
            if active.count == 1, now - lastTapEnd < 0.3, distance(centroid(), lastTapPoint) < 40 {
                dragging = true
                onButton?("left", true)
            }
        }
        if active.count > maxTouches {
            maxTouches = active.count
            spreadStart = spread()
            swipeAccum = .zero
        }
        lastCentroid = centroid()
        lastMoveAt = now
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let c = centroid()
        let d = CGPoint(x: c.x - lastCentroid.x, y: c.y - lastCentroid.y)
        let now = CACurrentMediaTime()
        let dt = max(now - lastMoveAt, 1.0 / 240)
        lastCentroid = c
        lastMoveAt = now
        travel += hypot(d.x, d.y)

        if maxTouches == 1 || (dragging && active.count == 1) {
            let v = hypot(d.x, d.y) / dt                      // points per second
            let gain = pointerSpeed * min(max(0.7 + v / 450, 0.7), 4.5)
            onMove?(d.x * gain, d.y * gain)
        } else if maxTouches == 2 && active.count == 2 {
            let s = scrollSpeed * 1.6
            onScroll?(d.x * s, d.y * s)
            scrollVelocity = CGPoint(x: d.x * s / dt, y: d.y * s / dt)
        } else if maxTouches >= 3 && active.count >= 3 && !gestureFired {
            swipeAccum.x += d.x
            swipeAccum.y += d.y
            detectMultiFinger()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let endPoint = centroid()
        active.subtract(touches)
        if !active.isEmpty {
            lastCentroid = centroid()   // avoid a jump when one finger lifts early
            return
        }
        let duration = CACurrentMediaTime() - startedAt
        let isTap = duration < 0.25 && travel < 10

        if dragging {
            onButton?("left", false)
            dragging = false
            lastTapEnd = isTap ? CACurrentMediaTime() : 0   // allows triple-click
        } else if maxTouches == 1 && isTap {
            onButton?("left", true)
            onButton?("left", false)
            tapHaptic.impactOccurred()
            lastTapEnd = CACurrentMediaTime()
            lastTapPoint = endPoint
        } else if maxTouches == 2 && duration < 0.3 && travel < 16 {
            onButton?("right", true)
            onButton?("right", false)
            tapHaptic.impactOccurred(intensity: 0.8)
            lastTapEnd = 0
        } else {
            lastTapEnd = 0
            let fresh = CACurrentMediaTime() - lastMoveAt < 0.06
            if maxTouches == 2 && fresh && hypot(scrollVelocity.x, scrollVelocity.y) > 200 { startMomentum() }
        }
        scrollVelocity = .zero
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
        if active.isEmpty && dragging {
            onButton?("left", false)
            dragging = false
        }
    }

    // MARK: Multi-finger gestures

    private func detectMultiFinger() {
        let n = min(maxTouches, 4)
        if n >= 4, spreadStart > 1 {
            let ratio = spread() / spreadStart
            if ratio < 0.68 { fire("pinch4"); return }
            if ratio > 1.4 { fire("spread4"); return }
        }
        let threshold: CGFloat = 45
        let ax = abs(swipeAccum.x), ay = abs(swipeAccum.y)
        if ax > threshold && ax > ay * 1.3 {
            fire("swipe\(n)" + (swipeAccum.x < 0 ? "Left" : "Right"))
        } else if ay > threshold && ay > ax * 1.3 {
            fire("swipe\(n)" + (swipeAccum.y < 0 ? "Up" : "Down"))
        }
    }

    private func fire(_ name: String) {
        gestureFired = true
        gestureHaptic.impactOccurred()
        onGesture?(name)
    }

    // MARK: Scroll momentum

    private func startMomentum() {
        scrollVelocityMomentum = scrollVelocity
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum))
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        let dt = link.targetTimestamp - link.timestamp
        scrollVelocityMomentum.x *= 0.95
        scrollVelocityMomentum.y *= 0.95
        onScroll?(scrollVelocityMomentum.x * dt, scrollVelocityMomentum.y * dt)
        if hypot(scrollVelocityMomentum.x, scrollVelocityMomentum.y) < 30 { stopMomentum() }
    }
    private var scrollVelocityMomentum = CGPoint.zero

    private func stopMomentum() {
        momentum?.invalidate()
        momentum = nil
    }

    // MARK: Geometry

    private func centroid() -> CGPoint {
        guard !active.isEmpty else { return lastCentroid }
        var x: CGFloat = 0, y: CGFloat = 0
        for t in active { let p = t.location(in: self); x += p.x; y += p.y }
        return CGPoint(x: x / CGFloat(active.count), y: y / CGFloat(active.count))
    }

    private func spread() -> CGFloat {
        let c = centroid()
        guard !active.isEmpty else { return 0 }
        return active.reduce(0) { $0 + distance($1.location(in: self), c) } / CGFloat(active.count)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
