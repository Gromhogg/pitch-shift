// The window: two cards ("What you hear" and "Your voice"), each with an on/off switch, a big number you can
// click and type into, − 0 + buttons, and a picker. No extra text. The window can be resized: the cards sit side
// by side (or one above the other in a tall, narrow window) and everything grows with the window.
import AppKit
import AVFoundation

// The icon's colors: purple to pink. Plus the shared control sizes and animation helpers.
enum Theme {
    static let purple = NSColor(red: 0.45, green: 0.25, blue: 0.95, alpha: 1)
    static let pink = NSColor(red: 0.95, green: 0.3, blue: 0.6, alpha: 1)
    static let mid = purple.blended(withFraction: 0.5, of: pink)!
    static let gradient = NSGradient(starting: purple, ending: pink)!

    // Regular controls in a small window, large ones once everything is 1.3 times bigger.
    static func controlSize(_ scale: CGFloat) -> NSControl.ControlSize { scale >= 1.3 ? .large : .regular }
    static func fontSize(_ size: NSControl.ControlSize) -> CGFloat { size == .large ? 14 : 13 }

    // "Reduce motion" in the Mac's accessibility settings: nothing slides or pulses, things only fade.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Fades from how a view looks now to how it looks after the changes made right after this call.
    static func crossfade(_ view: NSView?, _ duration: TimeInterval = 0.2) {
        guard let view, view.isShowing, let layer = view.layer else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "crossfade")
    }

    // Eases changes made through `animator()`.
    static func animate(_ duration: TimeInterval, _ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            changes()
        }
    }
}

extension NSView {
    var isShowing: Bool { window?.isVisible == true }
}

extension NSControl {
    // Regular or large control, with the matching text size.
    func useSize(_ size: NSControl.ControlSize) {
        guard controlSize != size || font?.pointSize != Theme.fontSize(size) else { return }
        controlSize = size
        font = .systemFont(ofSize: Theme.fontSize(size))
    }
}

// An on/off switch in the icon's colors (the standard switch can't be recolored). The knob slides, and stretches
// a little while pressed, like the standard switch.
final class GradientSwitch: NSView {
    var onChange: (Bool) -> Void = { _ in }
    var onEnabled: (Bool) -> Void = { _ in }  // when it's turned on or off as a control (for its label)
    var isEnabled = true {
        didSet {
            needsDisplay = true
            if oldValue != isEnabled { onEnabled(isEnabled) }
        }
    }
    var isOn = false {
        didSet {
            guard oldValue != isOn else { return }
            setAccessibilityValue(isOn ? 1 : 0)
            let target: CGFloat = isOn ? 1 : 0
            if isShowing && !Theme.reduceMotion {
                Theme.animate(0.18) { animator().knob = target }
            } else {
                knob = target
            }
        }
    }
    var size = NSSize(width: 38, height: 22) {
        didSet {
            guard oldValue != size else { return }
            invalidateIntrinsicContentSize()
            noteFocusRingMaskChanged()
            needsDisplay = true
        }
    }
    @objc dynamic var knob: CGFloat = 0 { didSet { needsDisplay = true } }  // 0 = off (left), 1 = on (right)
    private var pressed = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        setAccessibilityValue(0)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "knob" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    override var intrinsicContentSize: NSSize { size }

    private var track: NSRect {
        NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height).insetBy(dx: 1, dy: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        let track = self.track
        let shape = NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25 * alpha + 0.1).setFill()
        shape.fill()
        if knob > 0 {
            NSGraphicsContext.current?.cgContext.setAlpha(knob * alpha)
            Theme.gradient.draw(in: shape, angle: 0)
            NSGraphicsContext.current?.cgContext.setAlpha(1)
        }
        let height = track.height - 4
        let width = height * (pressed ? 1.25 : 1)
        let circle = NSRect(x: track.minX + 2 + knob * (track.width - width - 4), y: track.minY + 2, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.7).setFill()
        NSBezierPath(roundedRect: circle, xRadius: height / 2, yRadius: height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Reachable with Tab when "Keyboard navigation" is on in the Mac's settings; Space switches it.
    override var acceptsFirstResponder: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { track }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { flip() } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if !acceptsFirstResponder { window?.makeFirstResponder(nil) }  // stops typing in a number
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { flip() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        flip()
        return true
    }

    private func flip() {
        guard isEnabled else { return }
        isOn.toggle()
        onChange(isOn)
    }
}

// A slider from 0 (left) to 1 (right), like the voice style (Natural ... Cartoon) or the tone (Bass ... Treble). The
// track shows the icon's purple-to-pink colors from end to end, with a round white knob (like GradientSwitch's) and
// small labels under its ends. `middleMark` adds a small mark at the middle, and the knob snaps to it when close.
// Click or drag to set it; with "Keyboard navigation" on, the arrow keys move it in steps of 0.1.
// Nothing moves on its own, so it's the same with Reduce Motion.
final class GradientSlider: NSView {
    var onChange: (Float) -> Void = { _ in }
    var middleMark = false { didSet { needsDisplay = true } }
    private let left: String, right: String
    private let describe: (Float) -> String  // what VoiceOver says for a value
    var isEnabled = true {
        didSet {
            guard oldValue != isEnabled else { return }
            if !isEnabled && window?.firstResponder === self { window?.makeFirstResponder(nil) }
            needsDisplay = true
        }
    }
    var value: Float = 0 {
        didSet {
            guard oldValue != value else { return }
            setAccessibilityValue(NSNumber(value: value))
            setAccessibilityValueDescription(describe(value))
            needsDisplay = true
        }
    }
    // Sizes for the window's scale (1 = smallest window).
    var scale: CGFloat = 1 { didSet { if oldValue != scale { resized() } } }
    // The height of the button beside it (Test): the track runs through the middle of that height, so they line up.
    var rowHeight: CGFloat = 24 { didSet { if oldValue != rowHeight { resized() } } }
    private var grab: CGFloat?  // where on the knob the mouse took hold (so the knob doesn't jump)

    // left / right: the labels under the ends; name: what VoiceOver calls it.
    init(left: String, right: String, name: String, describe: @escaping (Float) -> String) {
        self.left = left
        self.right = right
        self.describe = describe
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 40))
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(name)
        setAccessibilityMinValue(NSNumber(value: 0))
        setAccessibilityMaxValue(NSNumber(value: 1))
        setAccessibilityValue(NSNumber(value: 0))
        setAccessibilityValueDescription(describe(0))
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func resized() {
        invalidateIntrinsicContentSize()
        noteFocusRingMaskChanged()
        needsDisplay = true
    }

    // The knob and track follow the switches' sizes (bigger once the window is 1.3 times bigger).
    private var large: Bool { Theme.controlSize(scale) == .large }
    private var knobSize: CGFloat { large ? 20 : 16 }
    private var trackHeight: CGFloat { large ? 7 : 6 }
    private var labelFont: NSFont { .systemFont(ofSize: 11 + (scale - 1) * 2.5) }
    private var labelHeight: CGFloat { (labelFont.ascender - labelFont.descender).rounded(.up) }
    private var middle: CGFloat { (bounds.maxY - rowHeight / 2).rounded() }  // the track's middle

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: (rowHeight / 2).rounded() + knobSize / 2 + 1 + labelHeight)
    }

    // The line the knob moves along, and the knob's place on it.
    private var track: NSRect {
        NSRect(x: bounds.minX, y: middle - trackHeight / 2, width: bounds.width, height: trackHeight)
    }

    private var knob: NSRect {
        let x = bounds.minX + CGFloat(value) * max(0, bounds.width - knobSize)
        return NSRect(x: x.rounded(), y: middle - knobSize / 2, width: knobSize, height: knobSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = track
        let shape = NSBezierPath(roundedRect: t, xRadius: t.height / 2, yRadius: t.height / 2)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.35)
        Theme.gradient.draw(in: shape, angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        // The labels: one under the left end ("Natural"), one under the right end ("Cartoon").
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont, .foregroundColor: isEnabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor]
        let top = middle - knobSize / 2 - 1  // just under the knob
        for (text, left) in [(left, true), (right, false)] {
            let width = (text as NSString).size(withAttributes: attributes).width
            (text as NSString).draw(at: NSPoint(x: left ? bounds.minX : bounds.maxX - width, y: top - labelHeight), withAttributes: attributes)
        }

        // The middle mark: a short line across the track's middle, just inside the knob's height (so the knob covers
        // it when it's there).
        if middleMark {
            (isEnabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setFill()
            let reach = knobSize / 2 - 1
            NSBezierPath(rect: NSRect(x: (bounds.midX - 1).rounded(), y: middle - reach, width: 2, height: reach - trackHeight / 2)).fill()
            NSBezierPath(rect: NSRect(x: (bounds.midX - 1).rounded(), y: middle + trackHeight / 2, width: 2, height: reach - trackHeight / 2)).fill()
        }

        // The knob, with a soft shadow and a thin edge (so it stands out on a white card too).
        let k = knob
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isEnabled ? 0.3 : 0.15)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.7).setFill()
        NSBezierPath(ovalIn: k).fill()
        NSGraphicsContext.restoreGraphicsState()
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor.white : NSColor.black).withAlphaComponent((dark ? 0.25 : 0.14) * (isEnabled ? 1 : 0.6)).setStroke()
        let edge = NSBezierPath(ovalIn: k.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = 1
        edge.stroke()
    }

    // Reachable with Tab when "Keyboard navigation" is on in the Mac's settings (like the switches).
    override var acceptsFirstResponder: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { track.insetBy(dx: 0, dy: -(knobSize - trackHeight) / 2) }
    override func drawFocusRingMask() {
        let ring = focusRingMaskBounds
        NSBezierPath(roundedRect: ring, xRadius: ring.height / 2, yRadius: ring.height / 2).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { super.keyDown(with: event); return }
        switch event.specialKey {
        case .leftArrow?, .downArrow?: set(value - 0.1)
        case .rightArrow?, .upArrow?: set(value + 0.1)
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(acceptsFirstResponder ? self : nil)  // also stops typing in a number
        let point = convert(event.locationInWindow, from: nil)
        let k = knob
        grab = k.insetBy(dx: -2, dy: -4).contains(point) ? point.x - k.midX : 0
        follow(point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard grab != nil else { return }
        follow(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) { grab = nil }

    private func follow(_ point: NSPoint) {
        let travel = max(1, bounds.width - knobSize)
        set(Float((point.x - (grab ?? 0) - bounds.minX - knobSize / 2) / travel))
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        set(value + 0.1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        set(value - 0.1)
        return true
    }

    // Steps of 0.01 from 0 to 1 (and to the middle mark when within 0.03 of it).
    private func set(_ new: Float) {
        var clean = max(0, min(1, (new * 100).rounded() / 100))
        if middleMark && abs(clean - 0.5) < 0.031 { clean = 0.5 }
        guard clean != value else { return }
        value = clean
        onChange(clean)
    }
}

// The big number. Shows "+2" / "−1.5" / "0"; click it to type any amount from −24 to 24, Return to apply, Esc to
// cancel, ↑ ↓ to step by 1 while typing. A new number rolls in: up when higher, down when lower.
final class AmountField: NSTextField, NSTextFieldDelegate {
    var onCommit: (Float) -> Void = { _ in }
    var value: Float = 0 {
        didSet {
            guard !editing, oldValue != value || stringValue != Self.display(value) else { return }
            roll(to: Self.display(value), up: value > oldValue)
        }
    }
    // How strong the number looks: 1 = on, lower = waiting for sound or switched off.
    var strength: CGFloat = 1 {
        didSet {
            guard oldValue != strength else { return }
            if isShowing { Theme.animate(0.3) { animator().alphaValue = strength } } else { alphaValue = strength }
        }
    }
    // A soft background behind the number while the mouse is over it: shows it can be clicked.
    @objc dynamic var highlight: CGFloat = 0 { didSet { updatePill() } }
    private var editing = false { didSet { updatePill() } }
    private var cancelled = false
    private var hideText = false      // while the roll animation shows pictures of the old and new number
    private let pill = CALayer()
    private var ghosts: [CALayer] = []
    private var rolls = 0
    private var hoverArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        isEditable = true
        isSelectable = true
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 48, weight: .bold)
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        delegate = self
        stringValue = Self.display(value)
    }

    required init?(coder: NSCoder) { fatalError() }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "highlight" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    func setFontSize(_ points: CGFloat) {
        let size = (points * 2).rounded() / 2
        guard font?.pointSize != size else { return }
        font = .monospacedDigitSystemFont(ofSize: size, weight: .bold)
        updatePill()
    }

    override var stringValue: String {
        didSet { updatePill() }
    }

    static func display(_ value: Float) -> String {
        value == 0 ? "0" : (value > 0 ? "+" : "−") + plain(abs(value))
    }

    // 2.5 -> "2.5", 3.0 -> "3", -1.25 -> "-1.25"
    static func plain(_ value: Float) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    static func parse(_ text: String) -> Float? {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: ".")
        if cleaned.hasPrefix("+") { cleaned.removeFirst() }
        guard let number = Float(cleaned), number.isFinite else { return nil }
        return clamp(number)
    }

    static func clamp(_ value: Float) -> Float { (min(24, max(-24, value)) * 100).rounded() / 100 }

    // Draws the number, then paints the icon's gradient over just the text.
    override func draw(_ dirtyRect: NSRect) {
        guard !hideText else { return }
        super.draw(dirtyRect)
        guard !editing, let context = NSGraphicsContext.current?.cgContext, let font else { return }
        let size = (stringValue as NSString).size(withAttributes: [.font: font])
        let textRect = NSRect(x: bounds.midX - size.width / 2, y: bounds.minY, width: size.width, height: bounds.height)
        context.saveGState()
        context.setBlendMode(.sourceAtop)
        Theme.gradient.draw(in: textRect, angle: 0)
        context.restoreGState()
    }

    // The soft background behind the number (its own layer, so it also shows while typing).
    private func updatePill() {
        guard let layer, let font else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if pill.superlayer == nil { layer.insertSublayer(pill, at: 0) }
        let text = editing ? (currentEditor()?.string ?? stringValue) : stringValue
        let width = max((text as NSString).size(withAttributes: [.font: font]).width, font.pointSize) + font.pointSize * (editing ? 0.9 : 0.7)
        let height = min(bounds.height, font.capHeight + font.pointSize * 0.45)
        // Centered on the digits (they sit a little above the middle of the line).
        let digitsMiddle = bounds.midY + (layer.isGeometryFlipped ? 1 : -1) * font.descender * 0.08
        pill.frame = NSRect(x: bounds.midX - width / 2, y: digitsMiddle - height / 2, width: width, height: height).integral
        pill.cornerRadius = height * 0.22
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pill.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        }
        pill.opacity = Float(editing ? 1 : highlight)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updatePill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hover(isEnabled)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(false)
    }

    override var isEnabled: Bool {
        didSet { if !isEnabled { hover(false) } }
    }

    private func hover(_ on: Bool) {
        let target: CGFloat = on ? 1 : 0
        guard highlight != target else { return }
        if isShowing { Theme.animate(0.15) { animator().highlight = target } } else { highlight = target }
    }

    // Shows a new number: the old one slides away and fades while the new one comes in.
    private func roll(to text: String, up: Bool) {
        ghosts.forEach { $0.removeFromSuperlayer() }
        ghosts = []
        hideText = false
        guard isShowing, let layer, let before = snapshot() else { stringValue = text; return }
        stringValue = text
        guard let after = snapshot() else { needsDisplay = true; return }
        rolls += 1
        let roll = rolls
        let distance = Theme.reduceMotion ? 0 : bounds.height * 0.22 * (up ? 1 : -1) * (layer.isGeometryFlipped ? -1 : 1)
        hideText = true
        needsDisplay = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.rolls == roll else { return }
            self.ghosts.forEach { $0.removeFromSuperlayer() }
            self.ghosts = []
            self.hideText = false
            self.needsDisplay = true
        }
        let parts: [(CGImage, CGFloat, CGFloat, Float, Float)] = [(before, 0, distance, 1, 0), (after, -distance, 0, 0, 1)]
        for (image, fromY, toY, fromOpacity, toOpacity) in parts {
            let ghost = CALayer()
            ghost.frame = layer.bounds
            ghost.contents = image
            ghost.contentsGravity = .resize
            layer.addSublayer(ghost)
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = fromY
            move.toValue = toY
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = toOpacity
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = 0.22
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            ghost.add(group, forKey: "roll")
            ghosts.append(ghost)
        }
        CATransaction.commit()
    }

    private func snapshot() -> CGImage? {
        guard let picture = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: picture)
        return picture.cgImage
    }

    override func becomeFirstResponder() -> Bool {
        editing = true
        cancelled = false
        stringValue = Self.plain(value)
        let ok = super.becomeFirstResponder()
        if ok {
            needsDisplay = true
            DispatchQueue.main.async {
                (self.currentEditor() as? NSTextView)?.insertionPointColor = Theme.mid
                self.currentEditor()?.selectAll(nil)
                self.updatePill()
            }
        } else {
            editing = false
        }
        return ok
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            cancelled = true
            window?.makeFirstResponder(nil)
            return true
        }
        if selector == #selector(insertNewline(_:)) {
            window?.makeFirstResponder(nil)
            return true
        }
        // ↑ ↓ step the typed number by 1 and apply it right away.
        if selector == #selector(moveUp(_:)) || selector == #selector(moveDown(_:)) {
            let typed = Self.parse(textView.string) ?? value
            let stepped = Self.clamp(typed + (selector == #selector(moveUp(_:)) ? 1 : -1))
            textView.string = Self.plain(stepped)
            textView.selectAll(nil)
            value = stepped
            onCommit(stepped)
            updatePill()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) { updatePill() }

    func controlTextDidEndEditing(_ obj: Notification) {
        editing = false
        needsDisplay = true
        if !cancelled {
            if let number = Self.parse(stringValue) {
                if number != value { value = number }  // rolls to the new number
                onCommit(number)
            } else {
                NSSound.beep()
            }
        }
        stringValue = Self.display(value)
    }
}

// Clicking empty space in the window stops typing in the big number.
final class BackgroundView: NSView {
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(nil) }
}

// The dot next to "Pitch Shift Mic": grey, or green with a gentle pulse while a call app is listening.
final class StatusDot: NSView {
    var isLive = false { didSet { if oldValue != isLive { update() } } }
    private let dot = CALayer()
    private let halo = CALayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    override func layout() {
        super.layout()
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if dot.superlayer == nil {
            layer.addSublayer(halo)
            layer.addSublayer(dot)
        }
        for part in [halo, dot] {
            part.frame = bounds
            part.cornerRadius = bounds.height / 2
        }
        CATransaction.commit()
        update()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    private func update() {
        var color = NSColor.tertiaryLabelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = (isLive ? NSColor.systemGreen : NSColor.tertiaryLabelColor).cgColor
        }
        dot.backgroundColor = color  // fades to the new color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.backgroundColor = color
        halo.opacity = 0
        CATransaction.commit()
        let pulsing = halo.animation(forKey: "pulse") != nil
        guard isLive, !Theme.reduceMotion, window != nil else {
            if pulsing { halo.removeAnimation(forKey: "pulse") }
            return
        }
        guard !pulsing else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.45
        fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [grow, fade]
        pulse.duration = 2
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        halo.add(pulse, forKey: "pulse")
    }
}

// A full-width row in a card. `onScale` resizes its controls as the window grows (scale 1 = smallest window).
final class CardRow: NSStackView {
    var onScale: (CGFloat) -> Void = { _ in }
}

// One card: title + switch, big number, − 0 +, a picker, and any extra rows below (see addRow).
final class ShiftCard: NSView {
    static let baseWidth: CGFloat = 266  // card width in the smallest window
    let toggle = GradientSwitch()
    let amount = AmountField()
    let minus = NSButton()
    let zero = NSButton(title: "0", target: nil, action: nil)
    let plus = NSButton()
    let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    var onToggle: (Bool) -> Void = { _ in }
    var onAmount: (Float) -> Void = { _ in }
    var keyViews: [NSView] { [toggle, amount, minus, zero, plus, picker] }
    private(set) var scale: CGFloat = 0
    // The purple-pink edge shown while the card is on.
    @objc dynamic var glow: CGFloat = 0 { didSet { needsDisplay = true } }
    private let title: NSTextField
    private let header: NSStackView
    private let buttons: NSStackView
    private let stack = NSStackView()
    private var rows: [NSView] = []
    private var tightAfter: [NSView] = []  // rows followed by a tight row (see addRow)
    private var widths: [NSLayoutConstraint] = []
    private var buttonWidths: [NSLayoutConstraint] = []
    private var heights: [Int: CGFloat] = [:]  // height needed at each scale
    private var column: CGFloat = 232          // width of the rows
    private var active: Bool?

    init(title text: String, extraRows: [NSView] = []) {
        title = NSTextField(labelWithString: text)
        header = NSStackView(views: [title, toggle])
        buttons = NSStackView(views: [minus, zero, plus])
        super.init(frame: NSRect(x: 0, y: 0, width: Self.baseWidth, height: 260))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text)

        header.distribution = .equalSpacing
        toggle.setAccessibilityLabel(text)
        toggle.onChange = { [weak self] in self?.onToggle($0) }
        amount.setAccessibilityLabel("\(text) pitch")
        amount.onCommit = { [weak self] in self?.onAmount($0) }
        let parts = [(minus, #selector(lower), "Lower", "Down 1"), (zero, #selector(reset), "Back to 0", "Back to 0"), (plus, #selector(higher), "Higher", "Up 1")]
        for (button, action, name, tip) in parts {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.setAccessibilityLabel(name)
            button.toolTip = tip
            buttonWidths.append(button.widthAnchor.constraint(equalToConstant: 48))
        }
        NSLayoutConstraint.activate(buttonWidths)

        stack.orientation = .vertical
        stack.alignment = .centerX
        for view in [header, amount, buttons, picker] { stack.addArrangedSubview(view) }
        for view in [header, amount, picker] { widen(view) }
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        extraRows.forEach(addRow)
        apply(scale: 1)
        place(width: Self.baseWidth)
    }

    required init?(coder: NSCoder) { fatalError() }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "glow" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    // Adds a full-width row at the bottom of the card (for example `ShiftCard.switchRow`). Add rows while
    // building the window, before it's laid out. `tight`: closer to the row above (it belongs with it).
    func addRow(_ row: NSView, tight: Bool) {
        if tight, let above = stack.arrangedSubviews.last {
            tightAfter.append(above)
            if scale > 0 { stack.setCustomSpacing((6 * scale).rounded(), after: above) }
        }
        addRow(row)
    }

    func addRow(_ row: NSView) {
        stack.addArrangedSubview(row)
        widen(row)
        rows.append(row)
        if scale > 0 { (row as? CardRow)?.onScale(scale) }
        heights = [:]
    }

    // A row with a label on the left and a small switch on the right, for settings like "Advanced processing".
    // The label dims while the switch can't be used.
    static func switchRow(_ text: String, _ toggle: GradientSwitch) -> CardRow {
        let label = NSTextField(labelWithString: text)
        label.textColor = toggle.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        toggle.onEnabled = { label.textColor = $0 ? .secondaryLabelColor : .tertiaryLabelColor }
        toggle.setAccessibilityLabel(text)
        let row = CardRow(views: [label, toggle])
        row.distribution = .equalSpacing
        row.onScale = { scale in
            label.font = .systemFont(ofSize: 12 + (scale - 1) * 2.5)
            toggle.size = Theme.controlSize(scale) == .large ? NSSize(width: 38, height: 22) : NSSize(width: 32, height: 19)
        }
        return row
    }

    private func widen(_ view: NSView) {
        let width = view.widthAnchor.constraint(equalToConstant: widths.first?.constant ?? 232)
        width.isActive = true
        widths.append(width)
    }

    // Sizes everything for a scale (1 = smallest window) and clears the extra spacing from `spread`.
    func apply(scale s: CGFloat) {
        if s != scale {
            scale = s
            let size = Theme.controlSize(s)
            title.font = .systemFont(ofSize: 13 + (s - 1) * 2.5, weight: .semibold)
            toggle.size = size == .large ? NSSize(width: 44, height: 26) : NSSize(width: 38, height: 22)
            for button in [minus, zero, plus] { button.useSize(size) }
            buttonWidths.forEach { $0.constant = (48 * s).rounded() }
            buttons.spacing = (8 * s).rounded()
            // − 0 + in the icon's middle color (plain tinting doesn't apply to these buttons).
            let glyph = NSImage.SymbolConfiguration(pointSize: Theme.fontSize(size), weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Theme.mid]))
            minus.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Lower")?.withSymbolConfiguration(glyph)
            plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Higher")?.withSymbolConfiguration(glyph)
            zero.attributedTitle = NSAttributedString(string: "0", attributes: [
                .foregroundColor: Theme.mid, .font: NSFont.systemFont(ofSize: Theme.fontSize(size), weight: .medium)])
            picker.useSize(size)
            stack.edgeInsets = NSEdgeInsets(top: (14 * s).rounded(), left: 0, bottom: (16 * s).rounded(), right: 0)
            stack.spacing = (12 * s).rounded()
            stack.setCustomSpacing((8 * s).rounded(), after: amount)
            tightAfter.forEach { stack.setCustomSpacing((6 * s).rounded(), after: $0) }
            rows.forEach { ($0 as? CardRow)?.onScale(s) }
            needsDisplay = true
        }
        spread(0)
    }

    // Fits the rows to the card's width (in a very wide card they stop growing and stay centered).
    func place(width: CGFloat) {
        column = min(width - 34 * scale, 232 * scale * 1.35).rounded()
        for width in widths where width.constant != column { width.constant = column }
    }

    // Extra height first makes the number bigger (while the widest number, "−23.75", still fits), then the rest
    // goes above the number and below the − 0 + buttons, so a tall card stays balanced.
    func spread(_ extra: CGFloat) {
        let base = 48 * scale
        amount.setFontSize(base)
        let baseHeight = amount.intrinsicContentSize.height
        amount.setFontSize(max(base, min(base + extra * 0.4, base * 1.5, column / Self.widestNumber)))
        let left = max(0, extra - (amount.intrinsicContentSize.height - baseHeight))
        stack.setCustomSpacing((4 * scale + left / 2).rounded(), after: header)
        stack.setCustomSpacing((16 * scale + left / 2).rounded(), after: buttons)
    }

    private static let widestNumber = ("−23.75" as NSString)
        .size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 100, weight: .bold)]).width / 100

    // The height the card needs at a scale (leaves the card sized for that scale).
    func neededHeight(at s: CGFloat) -> CGFloat {
        let key = Int((s * 100).rounded())
        if let height = heights[key] { return height }
        apply(scale: s)
        let height = stack.fittingSize.height.rounded(.up)
        heights[key] = height
        return height
    }

    // Call when a row is shown or hidden.
    func forgetHeights() { heights = [:] }

    // Updates the number and buttons; `active` dims everything when the card is off, `waiting` fades just the
    // number (on, but the chosen app isn't making sound).
    func show(on: Bool, value: Float, active: Bool, waiting: Bool = false) {
        toggle.isOn = on
        amount.value = value
        if active != self.active {
            if self.active != nil { ([amount, buttons, picker] + rows).forEach { Theme.crossfade($0, 0.25) } }
            self.active = active
            let target: CGFloat = active ? 1 : 0
            if isShowing { Theme.animate(0.25) { animator().glow = target } } else { glow = target }
        }
        amount.isEnabled = active
        amount.strength = active ? (waiting ? 0.5 : 1) : 0.4
        minus.isEnabled = active && value > -24
        plus.isEnabled = active && value < 24
        zero.isEnabled = active && value != 0
    }

    // The card: rounded, a soft shadow, and the purple-pink edge while on.
    override func draw(_ dirtyRect: NSRect) {
        let radius = 12 + (max(scale, 1) - 1) * 5
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor.controlBackgroundColor.setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.stroke()
        guard glow > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: radius - 0.25, yRadius: radius - 0.25)
        context.saveGState()
        context.setAlpha(glow * 0.55)
        context.addPath(edge.cgPath)
        context.setLineWidth(1.5)
        context.replacePathWithStrokedPath()
        context.clip()
        Theme.gradient.draw(in: bounds, angle: 0)
        context.restoreGState()
    }

    override func layout() {
        super.layout()
        let radius = 12 + (max(scale, 1) - 1) * 5
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateShadow()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateShadow()
        needsDisplay = true
    }

    private func updateShadow() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let depth = NSShadow()
        depth.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.35 : 0.09)
        depth.shadowBlurRadius = dark ? 6 : 5
        depth.shadowOffset = NSSize(width: 0, height: -1)
        shadow = depth
    }

    @objc private func lower() { step(-1) }
    @objc private func higher() { step(1) }
    @objc private func reset() {
        window?.makeFirstResponder(nil)
        onAmount(0)
    }

    private func step(_ by: Float) {
        window?.makeFirstResponder(nil)  // applies anything being typed first
        onAmount(AmountField.clamp(amount.value + by))
    }
}

enum Keys {
    static let hearOn = "hearOn", hearSource = "hearSource", halfSteps = "halfSteps", hearAdvanced = "hearAdvanced"
    static let hideAdvancedAlert = "hideAdvancedAlert"  // "Don't show again" was ticked
    // Advanced processing's Bass ↔ Treble for each speakers or headphones: [device UID: −1 (bass) … 0 … 1 (treble)].
    // Only what was picked on the slider is stored.
    static let hearTone = "hearTone"
    static let voiceOn = "voiceOn", voiceSteps = "voiceSteps", voiceMic = "voiceMic"
    static let voiceCartoon = "voiceCartoon"  // voice style, 0 (Natural) to 1 (Cartoon)
    static let voiceNatural = "voiceNatural"  // the old Natural/Cartoon switch (version 2.0), read once to carry over
    static let voiceSlowDeeper = "voiceSlowDeeper"  // "Deeper when slow"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let defaults = UserDefaults.standard
    lazy var hear = HearShifter(
        halfSteps: defaults.object(forKey: Keys.halfSteps) as? Float ?? 2,
        source: HearSource(saved: defaults.string(forKey: Keys.hearSource) ?? defaults.string(forKey: "source")),
        advanced: defaults.bool(forKey: Keys.hearAdvanced),
        tones: AppDelegate.savedTones(defaults))
    lazy var voice = VoiceShifter(
        halfSteps: defaults.object(forKey: Keys.voiceSteps) as? Float ?? 3,
        cartoon: AppDelegate.savedCartoon(defaults),
        slowDeeper: defaults.bool(forKey: Keys.voiceSlowDeeper),
        micUID: defaults.string(forKey: Keys.voiceMic))
    lazy var test = VoiceTest(voice: voice)

    // The saved voice style. Version 2.0 had a Natural/Cartoon switch instead: the first launch of this version turns
    // it into the slider's setting (Natural 0, Cartoon 1) and removes it; from then on only voiceCartoon is used.
    static func savedCartoon(_ defaults: UserDefaults) -> Float {
        if let natural = defaults.object(forKey: Keys.voiceNatural) as? Bool {
            let value: Float = natural ? 0 : 1
            if preview == nil {  // pictures change nothing
                defaults.set(value, forKey: Keys.voiceCartoon)
                defaults.removeObject(forKey: Keys.voiceNatural)
            }
            return value
        }
        guard let value = (defaults.object(forKey: Keys.voiceCartoon) as? NSNumber)?.floatValue, value.isFinite else { return 0 }
        return max(0, min(1, value))
    }

    // The saved Bass ↔ Treble per speakers or headphones (device UID → −1 … 1).
    static func savedTones(_ defaults: UserDefaults) -> [String: Float] {
        var tones: [String: Float] = [:]
        for (uid, saved) in defaults.dictionary(forKey: Keys.hearTone) ?? [:] {
            guard let value = (saved as? NSNumber)?.floatValue, value.isFinite else { continue }
            tones[uid] = max(-1, min(1, value))
        }
        return tones
    }

    var window: NSWindow!
    var hearCard: ShiftCard!
    var voiceCard: ShiftCard!
    let advancedSwitch = GradientSwitch()
    let style = GradientSlider(left: "Natural", right: "Cartoon", name: "Voice style") { value in
        value <= 0 ? "Natural" : value >= 1 ? "Cartoon" : "\(Int((value * 100).rounded())) percent Cartoon"
    }
    let slowSwitch = GradientSwitch()  // "Deeper when slow"
    // Advanced processing's tone for the speakers or headphones playing now: 0 = more bass, 0.5 = middle, 1 = more treble.
    let tone = GradientSlider(left: "Bass", right: "Treble", name: "Tone") { value in
        let percent = Int(((value * 2 - 1) * 100).rounded())
        return percent == 0 ? "Middle" : "\(abs(percent)) percent more \(percent < 0 ? "bass" : "treble")"
    }
    // The speakers or headphones playing now (followed even while What you hear is off).
    private var outputListener: Listener?
    private var outputUID = "", outputName = ""
    let testButton = NSButton(title: "Test", target: nil, action: nil)
    let dot = StatusDot()
    let micName = NSTextField(labelWithString: "Pitch Shift Mic")
    let installButton = NSButton(title: "Install Pitch Shift Mic", target: nil, action: nil)
    var footer: CardRow!
    private var installed: Bool?
    private var lastPhase: VoiceTest.Phase = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the colorful icon in the Dock (macOS's dark icon style would otherwise turn it grey).
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        buildMenu()
        buildWindow()
        // The tone slider shows the setting of the speakers or headphones playing now, and follows a change.
        outputListener = Listener(system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.outputMoved() }
        outputMoved()
        hear.onChange = { [weak self] in self?.refresh() }
        voice.onChange = { [weak self] in self?.refresh() }
        test.onChange = { [weak self] in self?.refresh() }
        refresh()
        showWindow()
        if preview != nil { showPreview(); return }
        // Show the window first: the first time, macOS asks for permission to grab sound and waits for an answer.
        DispatchQueue.main.async { [self] in
            if defaults.object(forKey: Keys.hearOn) as? Bool ?? true { hear.start() }
            if defaults.bool(forKey: Keys.voiceOn) {
                setVoice(true)  // asks for mic permission again if needed (each update looks like a new app to macOS)
            } else {
                DefaultMic.giveBack()  // in case the app didn't close cleanly last time
            }
            refresh()
        }
    }

    // Clicking the app on the Desktop or in the Dock while it's running brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        hear.stop()
        voice.stop()
        DefaultMic.giveBack()
    }

    func showWindow() {
        if preview != nil {
            // Pictures: the window stays out of sight under the desktop picture (screencapture -l still sees it), so
            // it never covers what's on screen, can't be clicked, and never switches apps.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            window.orderBack(nil)
            window.makeFirstResponder(nil)
            return
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Building

    func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector, String, NSEvent.ModifierFlags)]) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            for (name, action, key, modifiers) in items {
                if name == "-" { menu.addItem(.separator()); continue }
                let entry = menu.addItem(withTitle: name, action: action, keyEquivalent: key)
                entry.keyEquivalentModifierMask = modifiers
            }
            item.submenu = menu
            main.addItem(item)
        }
        submenu("Pitch Shift", [
            ("Hide Pitch Shift", #selector(NSApplication.hide(_:)), "h", .command),
            ("-", #selector(NSApplication.hide(_:)), "", []),
            ("Quit Pitch Shift", #selector(NSApplication.terminate(_:)), "q", .command),
        ])
        submenu("Edit", [
            ("Undo", Selector(("undo:")), "z", .command),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("-", #selector(NSText.cut(_:)), "", []),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ])
        submenu("Window", [
            ("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", .command),
            ("Zoom", #selector(NSWindow.performZoom(_:)), "", []),
            ("Close", #selector(NSWindow.performClose(_:)), "w", .command),
        ])
        NSApp.mainMenu = main
    }

    func buildWindow() {
        hearCard = ShiftCard(title: "What you hear")
        hearCard.picker.pullsDown = true  // a menu of apps to tick, not a single choice
        hearCard.picker.menu?.delegate = self
        hearCard.picker.target = self
        hearCard.picker.action = #selector(hearSourcePicked)
        hearCard.picker.setAccessibilityLabel("Apps")
        hearCard.onToggle = { [weak self] on in self?.setHear(on) }
        hearCard.onAmount = { [weak self] value in
            self?.hear.halfSteps = value
            self?.defaults.set(value, forKey: Keys.halfSteps)
            self?.refresh()
        }
        // Advanced processing (music): keeps the song balanced at big shifts. Turning it on asks first.
        advancedSwitch.onChange = { [weak self] on in self?.advancedPicked(on) }
        hearCard.addRow(ShiftCard.switchRow("Advanced processing", advancedSwitch))
        // Its tone, Bass ... Treble, kept for each speakers or headphones.
        tone.middleMark = true
        tone.onChange = { [weak self] value in self?.tonePicked(value) }
        let toneRow = CardRow(views: [tone])
        toneRow.onScale = { [unowned self] scale in
            tone.scale = scale
            tone.rowHeight = Theme.controlSize(scale) == .large ? 22 : 19  // like the Advanced processing switch
        }
        hearCard.addRow(toneRow, tight: true)

        style.onChange = { [weak self] value in self?.stylePicked(value) }
        testButton.bezelStyle = .rounded
        testButton.bezelColor = Theme.purple
        testButton.target = self
        testButton.action = #selector(testClicked)
        testButton.toolTip = "Record 5 seconds, then play it back"
        let testWidth = testButton.widthAnchor.constraint(equalToConstant: 72)
        testWidth.isActive = true
        let styleRow = CardRow(views: [style, testButton])
        styleRow.distribution = .fill
        styleRow.alignment = .top  // the slider's track lines up with the middle of Test; its labels hang below
        styleRow.onScale = { [unowned self, unowned styleRow] scale in
            testButton.useSize(Theme.controlSize(scale))
            testWidth.constant = (72 * scale).rounded()
            style.scale = scale
            style.rowHeight = testButton.intrinsicContentSize.height
            styleRow.spacing = (10 * scale).rounded()
        }

        micName.textColor = .secondaryLabelColor
        installButton.bezelStyle = .rounded
        installButton.target = self
        installButton.action = #selector(installDriver)
        footer = CardRow(views: [dot, micName, installButton])
        footer.onScale = { [unowned self] scale in
            micName.font = .systemFont(ofSize: 11 + (scale - 1) * 2.5)
            installButton.useSize(Theme.controlSize(scale))
            footer.spacing = (6 * scale).rounded()
        }

        // Deeper when slow: talking slowly makes the voice lower.
        slowSwitch.onChange = { [weak self] on in self?.slowPicked(on) }
        let slowRow = ShiftCard.switchRow("Deeper when slow", slowSwitch)

        voiceCard = ShiftCard(title: "Your voice", extraRows: [styleRow, slowRow, footer])
        voiceCard.picker.menu?.delegate = self
        voiceCard.picker.target = self
        voiceCard.picker.action = #selector(micPicked)
        voiceCard.picker.setAccessibilityLabel("Microphone")
        voiceCard.onToggle = { [weak self] on in self?.setVoice(on) }
        voiceCard.onAmount = { [weak self] value in
            self?.voice.halfSteps = value
            self?.defaults.set(value, forKey: Keys.voiceSteps)
            self?.refresh()
        }

        let background = BackgroundView()
        background.wantsLayer = true
        background.addSubview(hearCard)
        background.addSubview(voiceCard)

        // Tab goes through one card, then the other.
        let order = hearCard.keyViews + [advancedSwitch, tone] + voiceCard.keyViews + [style, testButton, slowSwitch, installButton]
        background.nextKeyView = order[0]
        for (view, next) in zip(order, order.dropFirst() + [order[0]]) { view.nextKeyView = next }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 588, height: 300),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Pitch Shift"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone]
        window.autorecalculatesKeyViewLoop = false
        window.contentView = background
        showDriverState()
        window.setContentSize(minSide)
        window.center()
        if let size = arg("--size")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            window.setContentSize(allowed(NSSize(width: size[0], height: size[1]), narrow: size[0] < minSide.width))
            window.center()
        } else if preview == nil {
            window.setFrameAutosaveName("Pitch Shift")  // remembers size and place (not for screenshots)
            let size = background.bounds.size
            window.setContentSize(allowed(size, narrow: size.width < minSide.width))
        }
        window.delegate = self
        arrange()
        rebuildHearMenu()
        rebuildMicMenu()
    }

    // MARK: Layout

    private let margin: CGFloat = 20, gap: CGFloat = 16, maxScale: CGFloat = 1.8
    private var minSide = NSSize.zero     // smallest window with the cards side by side
    private var minStacked = NSSize.zero  // smallest window with one card above the other
    private var stacked = false

    // Works out the smallest window sizes (call again when a row is shown or hidden).
    private func measure() {
        hearCard.forgetHeights()
        voiceCard.forgetHeights()
        let hearHeight = hearCard.neededHeight(at: 1), voiceHeight = voiceCard.neededHeight(at: 1)
        minSide = NSSize(width: 2 * ShiftCard.baseWidth + gap + 2 * margin, height: max(hearHeight, voiceHeight) + 2 * margin)
        minStacked = NSSize(width: ShiftCard.baseWidth + 2 * margin, height: hearHeight + voiceHeight + gap + 2 * margin)
        window.contentMinSize = NSSize(width: minStacked.width, height: minSide.height)
        window.contentMaxSize = NSSize(width: 1000, height: 640)
    }

    // A window can be small and wide (cards side by side) or narrow and tall (one above the other), not both.
    private func allowed(_ size: NSSize, narrow: Bool) -> NSSize {
        var size = size
        size.width = min(max(size.width, minStacked.width), window.contentMaxSize.width)
        size.height = min(max(size.height, minSide.height), window.contentMaxSize.height)
        if size.width < minSide.width && size.height < minStacked.height {
            if narrow { size.height = minStacked.height } else { size.width = minSide.width }
        }
        return size
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let size = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let narrow = (sender.contentView?.bounds.width ?? 0) < minSide.width
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: allowed(size, narrow: narrow))).size
    }

    func windowDidResize(_ notification: Notification) { arrange() }

    // The biggest scale at which the cards fit: limited by the card width, then shrunk until they fit the height.
    private func bestScale(_ size: NSSize, stacked: Bool) -> CGFloat {
        let width = stacked ? size.width - 2 * margin : (size.width - 2 * margin - gap) / 2
        let height = size.height - 2 * margin - (stacked ? gap : 0)
        func fits(_ s: CGFloat) -> Bool {
            let hearHeight = hearCard.neededHeight(at: s), voiceHeight = voiceCard.neededHeight(at: s)
            return (stacked ? hearHeight + voiceHeight : max(hearHeight, voiceHeight)) <= height
        }
        let widest = ((min(maxScale, width / ShiftCard.baseWidth)) * 100).rounded(.down) / 100
        if widest <= 1 || fits(widest) { return max(1, widest) }
        var low: CGFloat = 1, high = widest
        while high - low > 0.01 {
            let middle = ((low + high) / 2 * 100).rounded() / 100
            if middle == low || middle == high { break }
            if fits(middle) { low = middle } else { high = middle }
        }
        return low
    }

    // Places the cards: side by side, or one above the other when that lets everything be bigger.
    func arrange() {
        guard minSide != .zero, let size = window.contentView?.bounds.size else { return }
        let canSide = size.width >= minSide.width, canStack = size.height >= minStacked.height
        var useStack = !canSide
        var scale: CGFloat
        if canSide && canStack {
            let side = bestScale(size, stacked: false), stack = bestScale(size, stacked: true)
            useStack = stack > side + (stacked ? -0.05 : 0.05)  // a little stickiness so it doesn't flip back and forth
            scale = useStack ? stack : side
        } else {
            scale = bestScale(size, stacked: useStack)
        }
        let moved = useStack != stacked && voiceCard.frame.width > 0
        stacked = useStack

        let area = NSRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        let hearHeight = hearCard.neededHeight(at: scale), voiceHeight = voiceCard.neededHeight(at: scale)
        if stacked {
            let extra = max(0, (area.height - gap - hearHeight - voiceHeight) / 2)
            let top = (hearHeight + extra).rounded()
            hearCard.frame = NSRect(x: area.minX, y: area.maxY - top, width: area.width, height: top)
            voiceCard.frame = NSRect(x: area.minX, y: area.minY, width: area.width, height: area.height - top - gap)
            for card in [hearCard!, voiceCard!] {
                card.apply(scale: scale)
                card.place(width: area.width)
                card.spread(extra)
            }
        } else {
            let width = ((area.width - gap) / 2).rounded(.down)
            let extra = max(0, area.height - max(hearHeight, voiceHeight))
            hearCard.frame = NSRect(x: area.minX, y: area.minY, width: width, height: area.height)
            voiceCard.frame = NSRect(x: area.maxX - width, y: area.minY, width: width, height: area.height)
            for card in [hearCard!, voiceCard!] {
                card.apply(scale: scale)
                card.place(width: width)
                card.spread(extra)
            }
        }
        if moved { settle(voiceCard, from: stacked ? NSPoint(x: 0, y: -24) : NSPoint(x: 24, y: 0)) }
    }

    // When the layout changes, the "Your voice" card fades into its new place, coming up from below (or in from
    // the right). It stays smooth even while the window is still being resized.
    private func settle(_ card: NSView, from offset: NSPoint) {
        guard window.isVisible, let layer = card.layer else { return }
        let slide = CABasicAnimation(keyPath: "position")
        slide.isAdditive = true
        slide.fromValue = NSValue(point: Theme.reduceMotion ? .zero : offset)
        slide.toValue = NSValue(point: .zero)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = 0.25
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "settle")
    }

    // MARK: Pickers

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === hearCard.picker.menu { rebuildHearMenu() } else { rebuildMicMenu() }
    }

    private func icon(_ image: NSImage?, dimmed: Bool = false) -> NSImage? {
        guard let image else { return nil }
        let small = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.4 : 1)
            return true
        }
        return small
    }

    // The app picker: tick any number of apps, or All sound. The button shows what's chosen; a green dot marks
    // apps playing sound right now.
    func rebuildHearMenu() {
        let picker = hearCard.picker
        picker.removeAllItems()
        let menu = picker.menu!
        let chosen = hear.source.bundleIDs
        var apps = Apps.scan().map { (bundleID: $0.bundleID, name: $0.name, icon: $0.icon, running: true, playing: $0.isPlaying) }
        for saved in chosen where !apps.contains(where: { $0.bundleID == saved }) {
            let info = Apps.info(for: saved)
            apps.append((saved, info.name, info.icon, false, false))
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let speaker = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)

        // In a pull-down menu the first item is what the button shows.
        let picked = apps.filter { chosen.contains($0.bundleID) }
        let title = hear.source == .all ? "All sound" : picked.isEmpty ? "Choose apps" : picked.map(\.name).joined(separator: ", ")
        let titleItem = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        titleItem.image = hear.source == .all ? speaker : icon(picked.first?.icon)

        let all = menu.addItem(withTitle: "All sound", action: nil, keyEquivalent: "")
        all.image = speaker
        all.representedObject = "all"
        all.state = hear.source == .all ? .on : .off
        menu.addItem(.separator())
        for app in apps {
            let item = menu.addItem(withTitle: app.name, action: nil, keyEquivalent: "")
            item.image = icon(app.icon, dimmed: !app.running)
            item.representedObject = app.bundleID
            item.state = chosen.contains(app.bundleID) ? .on : .off
            let name = NSMutableAttributedString(string: app.name, attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: app.running ? NSColor.labelColor : NSColor.secondaryLabelColor])
            if app.playing {
                name.append(NSAttributedString(string: "  ●", attributes: [
                    .font: NSFont.menuFont(ofSize: 9), .foregroundColor: NSColor.systemGreen, .baselineOffset: 1.5]))
                item.toolTip = "Playing now"
                item.setAccessibilityLabel("\(app.name), playing now")
            }
            item.attributedTitle = name
        }
    }

    func rebuildMicMenu() {
        let picker = voiceCard.picker
        picker.removeAllItems()
        let mics = Mics.list()
        guard !mics.isEmpty else {
            picker.addItem(withTitle: "No microphone")
            picker.lastItem?.isEnabled = false
            return
        }
        let current = voice.currentMic.map(deviceUID)
        for mic in mics {
            picker.addItem(withTitle: mic.name)
            picker.lastItem?.representedObject = mic.uid
            picker.lastItem?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        }
        picker.selectItem(at: mics.firstIndex { $0.uid == current } ?? 0)
    }

    // Clicking "All sound" picks everything; clicking an app ticks or unticks it.
    @objc func hearSourcePicked() {
        guard let clicked = hearCard.picker.selectedItem?.representedObject as? String else { return }
        var source = HearSource.all
        if clicked != "all" {
            var bundleIDs = hear.source.bundleIDs
            if let i = bundleIDs.firstIndex(of: clicked) { bundleIDs.remove(at: i) } else { bundleIDs.append(clicked) }
            source = .apps(bundleIDs)
        }
        hear.source = source
        defaults.set(source.saved, forKey: Keys.hearSource)
        rebuildHearMenu()
        refresh()
    }

    @objc func micPicked() {
        guard let uid = voiceCard.picker.selectedItem?.representedObject as? String else { return }
        voice.micUID = uid
        defaults.set(uid, forKey: Keys.voiceMic)
        refresh()
    }

    func stylePicked(_ value: Float) {
        voice.cartoon = value
        guard preview == nil else { return }  // pictures change nothing
        defaults.set(value, forKey: Keys.voiceCartoon)
    }

    // The tone slider moved: it's kept for the speakers or headphones playing now.
    func tonePicked(_ value: Float) {
        guard !outputUID.isEmpty else { return }
        hear.setTone(((value * 2 - 1) * 100).rounded() / 100, for: outputUID)
        guard preview == nil else { return }  // pictures change nothing
        defaults.set(hear.tones, forKey: Keys.hearTone)
    }

    // The speakers or headphones changed: the tone slider shows theirs.
    func outputMoved() {
        let id = defaultOutput()
        outputUID = deviceUID(id)
        outputName = deviceName(id)
        refresh()
    }

    func slowPicked(_ on: Bool) {
        voice.slowDeeper = on
        guard preview == nil else { return }  // pictures change nothing
        defaults.set(on, forKey: Keys.voiceSlowDeeper)
    }

    @objc func testClicked() { test.click() }

    // MARK: Advanced processing

    private var advancedAlert: NSAlert?

    // Turning it on shows an alert first (it adds delay), unless "Don't show again" was ticked.
    func advancedPicked(_ on: Bool) {
        if on && !defaults.bool(forKey: Keys.hideAdvancedAlert) {
            askAdvanced()
            return
        }
        hear.advanced = on
        defaults.set(on, forKey: Keys.hearAdvanced)
        refresh()  // the tone slider works only with it on
    }

    // A sheet on the window: Turn On, or Cancel (the switch goes back off and nothing is saved).
    func askAdvanced() {
        guard advancedAlert == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Advanced processing may cause significant audio delay"
        alert.informativeText = "Sound may lag behind video. It's made for music."
        alert.addButton(withTitle: "Turn On").bezelColor = Theme.purple
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show again"
        advancedAlert = alert
        alert.beginSheetModal(for: window) { [weak self] answer in
            guard let self else { return }
            advancedAlert = nil
            if answer == .alertFirstButtonReturn && preview == nil {  // pictures change nothing
                if alert.suppressionButton?.state == .on { defaults.set(true, forKey: Keys.hideAdvancedAlert) }
                hear.advanced = true
                defaults.set(true, forKey: Keys.hearAdvanced)
            }
            refresh()  // shows the switch as it really is (off after Cancel)
        }
    }

    // MARK: Switches

    func setHear(_ on: Bool) {
        on ? hear.start() : hear.stop()
        defaults.set(on, forKey: Keys.hearOn)
        refresh()
    }

    func setVoice(_ on: Bool) {
        guard on else {
            voice.stop()
            DefaultMic.giveBack()
            defaults.set(false, forKey: Keys.voiceOn)
            refresh()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            voice.start()
            DefaultMic.takeOver()
            defaults.set(true, forKey: Keys.voiceOn)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { granted ? self.setVoice(true) : self.micDenied() }
            }
        default:
            micDenied()
        }
        refresh()
    }

    private func micDenied() {
        defaults.set(false, forKey: Keys.voiceOn)
        refresh()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    // Installs the Pitch Shift Mic driver (asks for the Mac password), for copies installed without the package.
    @objc func installDriver() {
        guard let script = Bundle.main.path(forResource: "install-driver", ofType: "sh") else { NSSound.beep(); return }
        let command = "/bin/bash '\(script)'"
        let source = "do shell script \"\(command)\" with prompt \"Pitch Shift needs your password to add Pitch Shift Mic.\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil else { return }
        // The Mac's sound system restarted; reconnect everything.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            let hearOn = hear.isOn, voiceOn = voice.isOn
            hear.stop()
            voice.stop()
            if hearOn { hear.start() }
            if voiceOn {
                voice.start()
                DefaultMic.takeOver()
            }
            rebuildMicMenu()
            refresh()
        }
    }

    // MARK: Showing state

    // For screenshots (--preview hear-on,voice-on,waiting,typing,recording,playing,listening,hover,menu,roll,
    // resize,no-driver,advanced-alert,light,tone,slow [--size 800x400]): shows a state, no sound.
    func showPreview() {
        guard let preview else { return }
        if preview.contains("light") { window.appearance = NSAppearance(named: .aqua) }
        if let cartoonArg { voice.cartoon = cartoonArg }  // where the style slider is (--cartoon-amount 0.5)
        if preview.contains("tone") { hear.advanced = true }  // Advanced processing on (nothing runs in pictures)
        if let toneArg, !outputUID.isEmpty { hear.setTone(toneArg, for: outputUID) }  // the tone slider (--tone-amount -0.4)
        if preview.contains("slow") { voice.slowDeeper = true }  // "Deeper when slow" on
        refresh()
        if preview.contains("typing") {
            window.makeFirstResponder(hearCard.amount)
            DispatchQueue.main.async { self.hearCard.amount.currentEditor()?.string = "2.5" }
        }
        if preview.contains("hover") { hearCard.amount.highlight = 1 }
        if preview.contains("roll") {  // slowed down 10 times, to catch the animations in a screenshot
            window.contentView?.layer?.speed = 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.hearCard.show(on: true, value: self.hear.halfSteps + 1, active: true)
                self.voiceCard.show(on: false, value: self.voice.halfSteps, active: false)
                self.lastPhase = .recording(5)
                Theme.crossfade(self.testButton, 0.2)
                self.testButton.title = "● 5"
                self.testButton.bezelColor = .systemRed
            }
        }
        if preview.contains("menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.hearCard.picker.performClick(nil) }
        }
        if preview.contains("advanced-alert") {  // the alert shown when Advanced processing is turned on
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.advancedSwitch.isOn = true
                self.askAdvanced()
            }
        }
        if preview.contains("resize") {  // grows the window tall, so the cards move one above the other
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                var frame = self.window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: 600, height: 640)))
                frame.origin = NSPoint(x: self.window.frame.minX, y: self.window.frame.maxY - frame.height)
                self.window.setFrame(frame, display: true, animate: true)
            }
        }
    }

    private var driverInstalled: Bool { Mics.driverInstalled && preview?.contains("no-driver") != true }

    // Shows "Pitch Shift Mic" or the Install button, and resizes the window's limits when that changes.
    private func showDriverState() {
        let now = driverInstalled
        guard now != installed else { return }
        installed = now
        dot.isHidden = !now
        micName.isHidden = !now
        installButton.isHidden = now
        measure()
        let size = window.contentView?.bounds.size ?? minSide
        let fixed = allowed(size, narrow: size.width < minSide.width)
        if fixed != size { window.setContentSize(fixed) }
        arrange()
    }

    private func waitingTip() -> String {
        let names = hear.source.bundleIDs.map { Apps.info(for: $0).name }
        return names.isEmpty ? "Waiting for sound" : "Waiting for sound from \(names.joined(separator: ", "))"
    }

    func refresh() {
        guard hearCard != nil else { return }
        let hearOn = preview.map { $0.contains("hear-on") } ?? hear.isOn
        let voiceOn = preview.map { $0.contains("voice-on") } ?? voice.isOn
        let waiting = preview.map { $0.contains("waiting") } ?? (hear.state == .waiting)
        hearCard.show(on: hearOn, value: hear.halfSteps, active: hearOn, waiting: waiting)
        if advancedAlert == nil { advancedSwitch.isOn = hear.advanced }  // stays on while the alert asks
        tone.value = (((hear.tones[outputUID] ?? 0) + 1) / 2 * 100).rounded() / 100
        tone.isEnabled = hear.advanced && hearOn
        tone.toolTip = outputName.isEmpty ? nil : "For \(outputName)"
        switch hear.state {
        case .playing(let speakers): hearCard.amount.toolTip = "Playing to \(speakers)"
        case .problem(let message): hearCard.amount.toolTip = message
        case .waiting: hearCard.amount.toolTip = waitingTip()
        case .off: hearCard.amount.toolTip = nil
        }

        showDriverState()
        let installed = driverInstalled
        let hasMic = !Mics.list().isEmpty
        voiceCard.show(on: voiceOn, value: voice.halfSteps, active: voiceOn && installed && hasMic)
        voiceCard.toggle.isEnabled = installed && hasMic
        voiceCard.picker.isEnabled = installed && hasMic
        style.value = voice.cartoon
        style.isEnabled = voiceOn && installed
        slowSwitch.isOn = voice.slowDeeper
        slowSwitch.isEnabled = voiceOn && installed
        if case .problem(let message) = voice.state { voiceCard.amount.toolTip = message } else { voiceCard.amount.toolTip = nil }

        let listening = preview.map { $0.contains("listening") } ?? voice.listening
        dot.isLive = voiceOn && installed && listening
        footer.toolTip = dot.isLive ? "An app is using Pitch Shift Mic" : "Choose Pitch Shift Mic as the microphone in Discord, Zoom or any app"
        micName.setAccessibilityValue(dot.isLive ? "Pitch Shift Mic, in use" : "Pitch Shift Mic, not in use")

        var phase = test.phase
        if let preview, preview.contains("recording") { phase = .recording(3) }
        if let preview, preview.contains("playing") { phase = .playing }
        if phase != lastPhase {
            Theme.crossfade(testButton, 0.2)
            lastPhase = phase
        }
        switch phase {
        case .idle:
            testButton.title = "Test"
            testButton.bezelColor = Theme.purple
            testButton.setAccessibilityLabel("Test")
            testButton.isEnabled = voiceOn && installed && hasMic
        case .recording(let left):
            testButton.title = "● \(left)"
            testButton.bezelColor = .systemRed
            testButton.setAccessibilityLabel("Recording, \(left) seconds left. Stop")
            testButton.isEnabled = true
        case .playing:
            testButton.title = "■ Stop"
            testButton.bezelColor = Theme.purple
            testButton.setAccessibilityLabel("Stop playing")
            testButton.isEnabled = true
        }
    }
}
