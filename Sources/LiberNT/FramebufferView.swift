import SwiftUI
import UIKit

/// Shows LiberNT's screen and turns touches and the iPhone keyboard into mouse and key input.
///  - Tap: left click. Two-finger tap or long press: right click.
///  - Drag with one finger: drag with the left button held.
///  - Drag with two fingers: scroll.
struct FramebufferView: UIViewRepresentable {
    let frame: CGImage?
    let vnc: VNCClient
    @Binding var showKeyboard: Bool

    func makeUIView(context: Context) -> FramebufferUIView {
        let view = FramebufferUIView()
        view.vnc = vnc
        return view
    }

    func updateUIView(_ view: FramebufferUIView, context: Context) {
        view.show(frame)
        view.onKeyboardHidden = { showKeyboard = false }
        if showKeyboard && !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !showKeyboard && view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

final class FramebufferUIView: UIView, UIKeyInput {
    var vnc: VNCClient?
    var onKeyboardHidden: (() -> Void)?

    private let screen = CALayer()
    private var imageSize = CGSize(width: 1024, height: 768)
    private var scrollCarry: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        screen.contentsGravity = .resizeAspect
        screen.magnificationFilter = .linear
        screen.minificationFilter = .trilinear
        layer.addSublayer(screen)
        isMultipleTouchEnabled = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(rightTapped(_:)))
        twoTap.numberOfTouchesRequired = 2
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.5
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        tap.require(toFail: twoTap)
        [tap, twoTap, hold, drag, scroll].forEach(addGestureRecognizer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screen.frame = bounds
        CATransaction.commit()
    }

    func show(_ image: CGImage?) {
        guard let image else { return }
        imageSize = CGSize(width: image.width, height: image.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screen.contents = image
        CATransaction.commit()
    }

    /// Converts a point in this view to a pixel on LiberNT's screen.
    private func guestPoint(_ point: CGPoint) -> (Int, Int) {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (bounds.width - shown.width) / 2, y: (bounds.height - shown.height) / 2)
        let x = (point.x - origin.x) / scale
        let y = (point.y - origin.y) / scale
        return (Int(max(0, min(x, imageSize.width - 1))), Int(max(0, min(y, imageSize.height - 1))))
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let (x, y) = guestPoint(gesture.location(in: self))
        vnc?.click(x: x, y: y, button: 1)
    }

    @objc private func rightTapped(_ gesture: UITapGestureRecognizer) {
        let (x, y) = guestPoint(gesture.location(in: self))
        vnc?.click(x: x, y: y, button: 4)
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let (x, y) = guestPoint(gesture.location(in: self))
        vnc?.click(x: x, y: y, button: 4)
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        let (x, y) = guestPoint(gesture.location(in: self))
        switch gesture.state {
        case .began:
            vnc?.pointer(x: x, y: y, mask: 0)
            vnc?.pointer(x: x, y: y, mask: 1)
        case .changed:
            vnc?.pointer(x: x, y: y, mask: 1)
        default:
            vnc?.pointer(x: x, y: y, mask: 0)
        }
    }

    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        let (x, y) = guestPoint(gesture.location(in: self))
        if gesture.state == .began { scrollCarry = 0 }
        scrollCarry += gesture.translation(in: self).y
        gesture.setTranslation(.zero, in: self)
        while abs(scrollCarry) >= 24 {
            vnc?.scroll(x: x, y: y, up: scrollCarry > 0)
            scrollCarry += scrollCarry > 0 ? -24 : 24
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        onKeyboardHidden?()
        return result
    }

    var hasText: Bool { true }
    func insertText(_ text: String) { vnc?.type(text) }
    func deleteBackward() { vnc?.tap(Keysym.backspace) }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    /// Hardware keyboard keys that don't come through insertText.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, let sym = Self.special[key.keyCode] else { continue }
            vnc?.key(sym, down: true)
            handled = true
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, let sym = Self.special[key.keyCode] else { continue }
            vnc?.key(sym, down: false)
            handled = true
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    private static let special: [UIKeyboardHIDUsage: UInt32] = [
        .keyboardEscape: Keysym.escape,
        .keyboardLeftArrow: Keysym.left,
        .keyboardRightArrow: Keysym.right,
        .keyboardUpArrow: Keysym.up,
        .keyboardDownArrow: Keysym.down,
        .keyboardDeleteForward: Keysym.delete,
        .keyboardLeftControl: Keysym.control,
        .keyboardLeftAlt: Keysym.alt,
        .keyboardLeftGUI: Keysym.windows,
    ]
}
