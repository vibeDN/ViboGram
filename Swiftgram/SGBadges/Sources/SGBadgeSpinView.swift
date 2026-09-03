import Foundation
import UIKit

// MARK: ViboGram - lightweight pan-driven pseudo-3D flip for a badge image.
// Deliberately not a real 3D engine (SceneKit): CATransform3D perspective +
// Y-axis rotation driven directly by horizontal pan translation is the
// standard, well-understood "card flip" technique, needs no 3D asset
// pipeline, and works on the same flat badge image already being fetched
// for the plain 2D display anyway. Drag horizontally to spin, with a bit of
// inertia on release that settles back to a face-on angle rather than
// stopping edge-on.
public final class SGBadgeSpinView: UIView {
    private let imageView = UIImageView()
    private let colorBackground = UIView()
    private var displayLink: CADisplayLink?
    private var angularVelocity: CGFloat = 0
    private var currentAngle: CGFloat = 0

    public var image: UIImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            colorBackground.isHidden = newValue != nil
        }
    }

    public var fallbackColor: UIColor {
        get { colorBackground.backgroundColor ?? .clear }
        set { colorBackground.backgroundColor = newValue }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)

        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 900.0
        self.layer.sublayerTransform = perspective

        colorBackground.layer.cornerRadius = 16
        colorBackground.layer.masksToBounds = true
        addSubview(colorBackground)

        imageView.contentMode = .scaleAspectFit
        imageView.layer.cornerRadius = 16
        imageView.layer.masksToBounds = true
        addSubview(imageView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        colorBackground.frame = bounds
    }

    deinit {
        displayLink?.invalidate()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            displayLink?.invalidate()
            displayLink = nil
            angularVelocity = 0
        case .changed:
            // Radians per point dragged -- small enough that a full-width
            // drag on a typical badge-sized view is a bit more than one
            // full turn, not a barely-perceptible tilt.
            currentAngle += translation.x * 0.015
            applyRotation()
            gesture.setTranslation(.zero, in: self)
        case .ended, .cancelled, .failed:
            let velocity = gesture.velocity(in: self).x
            angularVelocity = velocity * 0.008
            startDecelerating()
        default:
            break
        }
    }

    private func applyRotation() {
        layer.transform = CATransform3DRotate(CATransform3DIdentity, currentAngle, 0, 1, 0)
    }

    private func startDecelerating() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        currentAngle += angularVelocity * (1.0 / 60.0)
        angularVelocity *= 0.94
        applyRotation()
        if abs(angularVelocity) < 0.02 {
            displayLink?.invalidate()
            displayLink = nil
            // Settle to the nearest face-on angle (a multiple of pi) rather
            // than wherever momentum happened to stop it, so it never ends
            // up resting edge-on/invisible.
            let target = (currentAngle / .pi).rounded() * .pi
            let startAngle = currentAngle
            let animationStart = CACurrentMediaTime()
            let animationDuration: CFTimeInterval = 0.35
            let settleLink = CADisplayLink(target: self, selector: #selector(settleTick))
            self.settleFrom = startAngle
            self.settleTo = target
            self.settleStartTime = animationStart
            self.settleDuration = animationDuration
            settleLink.add(to: .main, forMode: .common)
            displayLink = settleLink
        }
    }

    private var settleFrom: CGFloat = 0
    private var settleTo: CGFloat = 0
    private var settleStartTime: CFTimeInterval = 0
    private var settleDuration: CFTimeInterval = 0.35

    @objc private func settleTick() {
        let elapsed = CACurrentMediaTime() - settleStartTime
        let t = min(1.0, elapsed / settleDuration)
        // Ease-out cubic.
        let eased = 1 - pow(1 - CGFloat(t), 3)
        currentAngle = settleFrom + (settleTo - settleFrom) * eased
        applyRotation()
        if t >= 1.0 {
            currentAngle = settleTo
            applyRotation()
            displayLink?.invalidate()
            displayLink = nil
        }
    }
}
