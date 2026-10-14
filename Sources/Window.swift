// The window: two cards side by side ("What you hear" and "Your voice"), each with an on/off switch, a big
// number you can click and type into, − 0 + buttons, and a picker. No extra text.
import AppKit
import AVFoundation

// The icon's colors: purple to pink.
enum Theme {
    static let purple = NSColor(red: 0.45, green: 0.25, blue: 0.95, alpha: 1)
    static let pink = NSColor(red: 0.95, green: 0.3, blue: 0.6, alpha: 1)
    static let mid = purple.blended(withFraction: 0.5, of: pink)!
    static let gradient = NSGradient(starting: purple, ending: pink)!
}

// An on/off switch in the icon's colors (the standard switch can't be recolored).
final class GradientSwitch: NSView {
    var onChange: (Bool) -> Void = { _ in }
    var isEnabled = true { didSet { needsDisplay = true } }
    var isOn = false {
        didSet {
            guard oldValue != isOn else { return }
            setAccessibilityValue(isOn ? 1 : 0)
            slide()
        }
    }
    private var knob: CGFloat = 0  // 0 = off (left), 1 = on (right)
    private var animation: Timer?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(0)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 38, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        let track = bounds.insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25 * alpha + 0.1).setFill()
        shape.fill()
        if knob > 0 {
            NSGraphicsContext.current?.cgContext.setAlpha(knob * alpha)
            Theme.gradient.draw(in: shape, angle: 0)
            NSGraphicsContext.current?.cgContext.setAlpha(1)
        }
        let size = track.height - 4
        let circle = NSRect(x: track.minX + 2 + knob * (track.width - size - 4), y: track.minY + 2, width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.7).setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isOn.toggle()
        onChange(isOn)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        isOn.toggle()
        onChange(isOn)
        return true
    }

    // Slides the knob over about 0.15 s.
    private func slide() {
        animation?.invalidate()
        let target: CGFloat = isOn ? 1 : 0
        guard window != nil else { knob = target; needsDisplay = true; return }
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let step: CGFloat = 1.0 / 9
            self.knob = target > self.knob ? min(target, self.knob + step) : max(target, self.knob - step)
            self.needsDisplay = true
            if self.knob == target { timer.invalidate() }
        }
    }
}

// The big number. Shows "+2" / "−1.5" / "0"; click it to type any amount from −24 to 24, Return to apply, Esc to cancel.
final class AmountField: NSTextField, NSTextFieldDelegate {
    var onCommit: (Float) -> Void = { _ in }
    var value: Float = 0 { didSet { if !editing { stringValue = Self.display(value) } } }
    var gradientStrength: CGFloat = 1 { didSet { needsDisplay = true } }  // lower = lighter (chosen app not running)
    private var editing = false
    private var cancelled = false

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
        return (min(24, max(-24, number)) * 100).rounded() / 100
    }

    // Draws the number, then paints the icon's gradient over just the text.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !editing, let context = NSGraphicsContext.current?.cgContext, let font else { return }
        let size = (stringValue as NSString).size(withAttributes: [.font: font])
        let textRect = NSRect(x: bounds.midX - size.width / 2, y: bounds.minY, width: size.width, height: bounds.height)
        context.saveGState()
        context.setBlendMode(.sourceAtop)
        context.setAlpha(gradientStrength)
        Theme.gradient.draw(in: textRect, angle: 0)
        context.restoreGState()
    }

    override func becomeFirstResponder() -> Bool {
        editing = true
        cancelled = false
        stringValue = Self.plain(value)
        let ok = super.becomeFirstResponder()
        if ok {
            DispatchQueue.main.async {
                (self.currentEditor() as? NSTextView)?.insertionPointColor = Theme.mid
                self.currentEditor()?.selectAll(nil)
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
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        editing = false
        needsDisplay = true
        if !cancelled {
            if let number = Self.parse(stringValue) {
                value = number
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

// One card: title + switch, big number, − 0 +, a picker, and any extra rows.
final class ShiftCard: NSBox {
    let toggle = GradientSwitch()
    let amount = AmountField()
    let minus = NSButton()
    let zero = NSButton(title: "0", target: nil, action: nil)
    let plus = NSButton()
    let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    var onToggle: (Bool) -> Void = { _ in }
    var onAmount: (Float) -> Void = { _ in }
    private let stack = NSStackView()

    init(title: String, extraRows: [NSView]) {
        super.init(frame: .zero)
        boxType = .custom
        cornerRadius = 12
        borderWidth = 1
        borderColor = .separatorColor
        fillColor = .controlBackgroundColor
        contentViewMargins = .zero
        titlePosition = .noTitle

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        toggle.onChange = { [weak self] in self?.onToggle($0) }
        let header = NSStackView(views: [titleLabel, NSView(), toggle])
        header.distribution = .fill

        amount.onCommit = { [weak self] in self?.onAmount($0) }
        // − 0 + in the icon's middle color (plain tinting doesn't apply to these buttons).
        let tint = NSImage.SymbolConfiguration(paletteColors: [Theme.mid])
        minus.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Lower")?.withSymbolConfiguration(tint)
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Higher")?.withSymbolConfiguration(tint)
        zero.attributedTitle = NSAttributedString(string: "0", attributes: [.foregroundColor: Theme.mid, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)])
        for (button, action) in [(minus, #selector(lower)), (zero, #selector(reset)), (plus, #selector(higher))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }
        let buttons = NSStackView(views: [minus, zero, plus])
        buttons.spacing = 8

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        for view in [header, amount, buttons, picker] + extraRows { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(4, after: header)
        stack.setCustomSpacing(8, after: amount)
        stack.setCustomSpacing(16, after: buttons)
        header.widthAnchor.constraint(equalToConstant: 232).isActive = true
        picker.widthAnchor.constraint(equalToConstant: 232).isActive = true
        amount.widthAnchor.constraint(equalToConstant: 232).isActive = true

        let content = NSView()
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 264),
        ])
        contentView = content
    }

    required init?(coder: NSCoder) { fatalError() }

    // Updates the number and buttons; `active` dims everything when the card is switched off.
    func show(on: Bool, value: Float, active: Bool, waiting: Bool = false) {
        toggle.isOn = on
        amount.value = value
        amount.isEnabled = active
        amount.gradientStrength = waiting ? 0.45 : 1
        amount.alphaValue = active ? 1 : 0.35
        minus.isEnabled = active && value > -24
        plus.isEnabled = active && value < 24
        zero.isEnabled = active && value != 0
    }

    @objc private func lower() { onAmount(max(-24, ((amount.value - 1) * 100).rounded() / 100)) }
    @objc private func higher() { onAmount(min(24, ((amount.value + 1) * 100).rounded() / 100)) }
    @objc private func reset() { onAmount(0) }
}

enum Keys {
    static let hearOn = "hearOn", hearSource = "hearSource", halfSteps = "halfSteps"
    static let voiceOn = "voiceOn", voiceSteps = "voiceSteps", voiceNatural = "voiceNatural", voiceMic = "voiceMic"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let defaults = UserDefaults.standard
    lazy var hear = HearShifter(
        halfSteps: defaults.object(forKey: Keys.halfSteps) as? Float ?? 2,
        source: HearSource(saved: defaults.string(forKey: Keys.hearSource) ?? defaults.string(forKey: "source")))
    lazy var voice = VoiceShifter(
        halfSteps: defaults.object(forKey: Keys.voiceSteps) as? Float ?? 3,
        natural: defaults.object(forKey: Keys.voiceNatural) as? Bool ?? true,
        micUID: defaults.string(forKey: Keys.voiceMic))
    lazy var test = VoiceTest(voice: voice)

    var window: NSWindow!
    var hearCard: ShiftCard!
    var voiceCard: ShiftCard!
    let style = NSSegmentedControl(labels: ["Natural", "Cartoon"], trackingMode: .selectOne, target: nil, action: nil)
    let testButton = NSButton(title: "Test", target: nil, action: nil)
    let dot = NSTextField(labelWithString: "●")
    let micName = NSTextField(labelWithString: "Pitch Shift Mic")
    let installButton = NSButton(title: "Install Pitch Shift Mic", target: nil, action: nil)
    var footer: NSStackView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the colorful icon in the Dock (macOS's dark icon style would otherwise turn it grey).
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        buildMenu()
        buildWindow()
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
            ("Close", #selector(NSWindow.performClose(_:)), "w", .command),
        ])
        NSApp.mainMenu = main
    }

    func buildWindow() {
        hearCard = ShiftCard(title: "What you hear", extraRows: [])
        hearCard.picker.pullsDown = true  // a menu of apps to tick, not a single choice
        hearCard.picker.menu?.delegate = self
        hearCard.picker.target = self
        hearCard.picker.action = #selector(hearSourcePicked)
        hearCard.onToggle = { [weak self] on in self?.setHear(on) }
        hearCard.onAmount = { [weak self] value in
            self?.hear.halfSteps = value
            self?.defaults.set(value, forKey: Keys.halfSteps)
            self?.refresh()
        }

        style.target = self
        style.action = #selector(stylePicked)
        style.selectedSegmentBezelColor = Theme.mid
        style.widthAnchor.constraint(equalToConstant: 152).isActive = true
        testButton.bezelStyle = .rounded
        testButton.bezelColor = Theme.purple
        testButton.target = self
        testButton.action = #selector(testClicked)
        testButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let styleRow = NSStackView(views: [style, testButton])
        styleRow.spacing = 8
        dot.font = .systemFont(ofSize: 9)
        micName.font = .systemFont(ofSize: 11)
        micName.textColor = .secondaryLabelColor
        installButton.bezelStyle = .rounded
        installButton.target = self
        installButton.action = #selector(installDriver)
        footer = NSStackView(views: [dot, micName, installButton])
        footer.spacing = 4

        voiceCard = ShiftCard(title: "Your voice", extraRows: [styleRow, footer])
        voiceCard.picker.menu?.delegate = self
        voiceCard.picker.target = self
        voiceCard.picker.action = #selector(micPicked)
        voiceCard.onToggle = { [weak self] on in self?.setVoice(on) }
        voiceCard.onAmount = { [weak self] value in
            self?.voice.halfSteps = value
            self?.defaults.set(value, forKey: Keys.voiceSteps)
            self?.refresh()
        }

        let cards = NSStackView(views: [hearCard, voiceCard])
        cards.orientation = .horizontal
        cards.alignment = .top
        cards.spacing = 16
        hearCard.heightAnchor.constraint(equalTo: voiceCard.heightAnchor).isActive = true

        let background = BackgroundView()
        background.addSubview(cards)
        cards.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cards.topAnchor.constraint(equalTo: background.topAnchor, constant: 20),
            cards.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            cards.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            cards.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -20),
        ])

        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Pitch Shift"
        window.isReleasedWhenClosed = false
        window.contentView = background
        window.setContentSize(background.fittingSize)
        window.center()
        rebuildHearMenu()
        rebuildMicMenu()
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

    // The app picker: tick any number of apps, or All sound. The button shows what's chosen.
    func rebuildHearMenu() {
        let picker = hearCard.picker
        picker.removeAllItems()
        let menu = picker.menu!
        let chosen = hear.source.bundleIDs
        var apps = Apps.scan().map { (bundleID: $0.bundleID, name: $0.name, icon: $0.icon, running: true) }
        for saved in chosen where !apps.contains(where: { $0.bundleID == saved }) {
            let info = Apps.info(for: saved)
            apps.append((saved, info.name, info.icon, false))
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
            if !app.running {
                item.attributedTitle = NSAttributedString(string: app.name, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0)])
            }
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

    @objc func stylePicked() {
        voice.natural = style.selectedSegment == 0
        defaults.set(voice.natural, forKey: Keys.voiceNatural)
    }

    @objc func testClicked() { test.click() }

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

    // For screenshots (--preview hear-on,voice-on,waiting,typing,recording,playing,light): shows a state, no sound.
    func showPreview() {
        guard let preview else { return }
        if preview.contains("light") { window.appearance = NSAppearance(named: .aqua) }
        refresh()
        if preview.contains("typing") {
            window.makeFirstResponder(hearCard.amount)
            DispatchQueue.main.async { self.hearCard.amount.currentEditor()?.string = "2.5" }
        }
    }

    func refresh() {
        guard hearCard != nil else { return }
        let hearOn = preview.map { $0.contains("hear-on") } ?? hear.isOn
        let voiceOn = preview.map { $0.contains("voice-on") } ?? voice.isOn
        let waiting = preview.map { $0.contains("waiting") } ?? (hear.state == .waiting)
        hearCard.show(on: hearOn, value: hear.halfSteps, active: hearOn, waiting: waiting)
        switch hear.state {
        case .playing(let speakers): hearCard.amount.toolTip = "Playing to \(speakers)"
        case .problem(let message): hearCard.amount.toolTip = message
        default: hearCard.amount.toolTip = nil
        }

        let installed = Mics.driverInstalled
        let hasMic = !Mics.list().isEmpty
        voiceCard.show(on: voiceOn, value: voice.halfSteps, active: voiceOn && installed && hasMic)
        voiceCard.toggle.isEnabled = installed && hasMic
        voiceCard.picker.isEnabled = installed && hasMic
        style.selectedSegment = voice.natural ? 0 : 1
        style.isEnabled = voiceOn && installed
        if case .problem(let message) = voice.state { voiceCard.amount.toolTip = message } else { voiceCard.amount.toolTip = nil }

        dot.isHidden = !installed
        micName.isHidden = !installed
        installButton.isHidden = installed
        dot.textColor = voiceOn && voice.listening ? .systemGreen : .tertiaryLabelColor

        var phase = test.phase
        if let preview, preview.contains("recording") { phase = .recording(3) }
        if let preview, preview.contains("playing") { phase = .playing }
        switch phase {
        case .idle:
            testButton.attributedTitle = NSAttributedString(string: "Test")
            testButton.isEnabled = voiceOn && installed && hasMic
        case .recording(let left):
            testButton.attributedTitle = NSAttributedString(string: "⏺ \(left)", attributes: [.foregroundColor: NSColor.systemRed])
            testButton.isEnabled = true
        case .playing:
            testButton.attributedTitle = NSAttributedString(string: "■ Stop")
            testButton.isEnabled = true
        }
    }
}
