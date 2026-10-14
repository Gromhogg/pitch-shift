// The window: two cards side by side ("What you hear" and "Your voice"), each with an on/off switch, a big
// number you can click and type into, − 0 + buttons, and a picker. No extra text.
import AppKit
import AVFoundation

// The big number. Shows "+2" / "−1.5" / "0"; click it to type any amount from −24 to 24, Return to apply, Esc to cancel.
final class AmountField: NSTextField, NSTextFieldDelegate {
    var onCommit: (Float) -> Void = { _ in }
    var value: Float = 0 { didSet { if !editing { stringValue = Self.display(value) } } }
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

    override func becomeFirstResponder() -> Bool {
        editing = true
        cancelled = false
        stringValue = Self.plain(value)
        let ok = super.becomeFirstResponder()
        if ok { DispatchQueue.main.async { self.currentEditor()?.selectAll(nil) } } else { editing = false }
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
    let toggle = NSSwitch()
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
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggled)
        let header = NSStackView(views: [titleLabel, NSView(), toggle])
        header.distribution = .fill

        amount.onCommit = { [weak self] in self?.onAmount($0) }
        minus.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Lower")
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Higher")
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
    func show(on: Bool, value: Float, active: Bool, numberColor: NSColor = .labelColor) {
        toggle.state = on ? .on : .off
        amount.value = value
        amount.isEnabled = active
        amount.textColor = numberColor
        amount.alphaValue = active ? 1 : 0.35
        minus.isEnabled = active && value > -24
        plus.isEnabled = active && value < 24
        zero.isEnabled = active && value != 0
    }

    @objc private func toggled() { onToggle(toggle.state == .on) }
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
        buildMenu()
        buildWindow()
        hear.onChange = { [weak self] in self?.refresh() }
        voice.onChange = { [weak self] in self?.refresh() }
        test.onChange = { [weak self] in self?.refresh() }
        refresh()
        showWindow()
        // Show the window first: the first time, macOS asks for permission to grab sound and waits for an answer.
        DispatchQueue.main.async { [self] in
            if defaults.object(forKey: Keys.hearOn) as? Bool ?? true { hear.start() }
            if defaults.bool(forKey: Keys.voiceOn) && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { voice.start() }
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
        style.widthAnchor.constraint(equalToConstant: 152).isActive = true
        testButton.bezelStyle = .rounded
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

    func rebuildHearMenu() {
        let picker = hearCard.picker
        picker.removeAllItems()
        let menu = picker.menu!
        let all = menu.addItem(withTitle: "All sound", action: nil, keyEquivalent: "")
        all.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
        all.representedObject = "all"
        menu.addItem(.separator())
        var apps = Apps.scan().map { (bundleID: $0.bundleID, name: $0.name, icon: $0.icon, running: true) }
        if case .app(let saved) = hear.source, !apps.contains(where: { $0.bundleID == saved }) {
            let info = Apps.info(for: saved)
            apps.append((saved, info.name, info.icon, false))
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        for app in apps {
            let item = menu.addItem(withTitle: app.name, action: nil, keyEquivalent: "")
            item.image = icon(app.icon, dimmed: !app.running)
            item.representedObject = app.bundleID
            if !app.running {
                item.attributedTitle = NSAttributedString(string: app.name, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0)])
            }
        }
        let selected = hear.source.saved
        picker.selectItem(at: menu.items.firstIndex { ($0.representedObject as? String) == selected } ?? 0)
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

    @objc func hearSourcePicked() {
        guard let saved = hearCard.picker.selectedItem?.representedObject as? String else { return }
        hear.source = HearSource(saved: saved)
        defaults.set(saved, forKey: Keys.hearSource)
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
            defaults.set(false, forKey: Keys.voiceOn)
            refresh()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            voice.start()
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
            if voiceOn { voice.start() }
            rebuildMicMenu()
            refresh()
        }
    }

    // MARK: Showing state

    func refresh() {
        guard hearCard != nil else { return }
        let waiting = hear.state == .waiting
        hearCard.show(on: hear.isOn, value: hear.halfSteps, active: hear.isOn, numberColor: waiting ? .secondaryLabelColor : .labelColor)
        switch hear.state {
        case .playing(let speakers): hearCard.amount.toolTip = "Playing to \(speakers)"
        case .problem(let message): hearCard.amount.toolTip = message
        default: hearCard.amount.toolTip = nil
        }

        let installed = Mics.driverInstalled
        let hasMic = !Mics.list().isEmpty
        voiceCard.show(on: voice.isOn, value: voice.halfSteps, active: voice.isOn && installed && hasMic)
        voiceCard.toggle.isEnabled = installed && hasMic
        voiceCard.picker.isEnabled = installed && hasMic
        style.selectedSegment = voice.natural ? 0 : 1
        style.isEnabled = voice.isOn && installed
        if case .problem(let message) = voice.state { voiceCard.amount.toolTip = message } else { voiceCard.amount.toolTip = nil }

        dot.isHidden = !installed
        micName.isHidden = !installed
        installButton.isHidden = installed
        dot.textColor = voice.isOn && voice.listening ? .systemGreen : .tertiaryLabelColor

        switch test.phase {
        case .idle:
            testButton.attributedTitle = NSAttributedString(string: "Test")
            testButton.isEnabled = voice.isOn && installed && hasMic
        case .recording(let left):
            testButton.attributedTitle = NSAttributedString(string: "⏺ \(left)", attributes: [.foregroundColor: NSColor.systemRed])
            testButton.isEnabled = true
        case .playing:
            testButton.attributedTitle = NSAttributedString(string: "■ Stop")
            testButton.isEnabled = true
        }
    }
}
