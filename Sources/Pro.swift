// Pitch Shift Pro: the $5 unlock (plan: notes/paid-unlock-plan.md). People email the owner for a key; the owner makes
// it on their Mac with tools/pro-keys.sh and emails it back. The app checks a key on its own, with no internet: a key
// is a serial number plus a part only the owner's secret can make (see ProKey). An accepted key is kept in
// ~/Library/Application Support/Pitch Shift/Pro.json and checked again at every launch. While Pro is locked, the paid
// settings use the free version's values (Free); what was saved is kept and comes back once Pro is unlocked.
import AppKit
import CryptoKit

// What the free version uses in place of the paid settings.
enum Free {
    static let cartoon: Float = 1  // the voice style stays at Cartoon
    static let slowDeeper = false  // Deeper when slow stays off
    static let tone: Float = 0     // Bass ↔ Treble stays in the middle
    // Auto EQ and the Voice changer stay off.
}

// The key: 25 characters, XXXXX-XXXXX-XXXXX-XXXXX-XXXXX, from 31 characters that can't be read two ways
// (no 0, 1, I, L or O). The first 5 are a serial number; the next 16 come from HMAC-SHA-256 of the serial with the
// owner's secret, so nobody without the secret can make a key; the last 4 are a check part, so a typo is caught
// right away. Must match tools/pro-keys.sh exactly (tools/pro-keys-test.txt has fixed examples both check).
enum ProKey {
    static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
    static let length = 25, bodyLength = 21, serialLength = 5

    enum Problem: Error, Equatable { case length, characters, check }

    // What was typed or pasted, in capitals, with spaces, dashes and anything else that isn't a letter or digit gone.
    static func raw(_ text: String) -> String {
        String(text.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    // "ABCDEFGHJK…" → "ABCDE-FGHJK-…"
    static func grouped(_ raw: String) -> String {
        var groups: [String] = []
        var rest = Substring(raw)
        while !rest.isEmpty {
            groups.append(String(rest.prefix(5)))
            rest = rest.dropFirst(5)
        }
        return groups.joined(separator: "-")
    }

    // The check part: the first 4 bytes of SHA-256("PSPRO1:" + the first 21 characters), as a number below 31^4, in
    // 4 characters.
    static func checkPart(_ body: String) -> String {
        let hash = Array(SHA256.hash(data: Data(("PSPRO1:" + body).utf8)))
        var number = (UInt32(hash[0]) << 24 | UInt32(hash[1]) << 16 | UInt32(hash[2]) << 8 | UInt32(hash[3])) % 923_521
        var out = ""
        for _ in 0..<4 {
            out = String(alphabet[Int(number % 31)]) + out
            number /= 31
        }
        return out
    }

    // The secret part: HMAC-SHA-256 of "PSPRO2:" + serial with the secret (its text as written), 16 characters,
    // each from two of its bytes (a number below 65536, taken modulo 31).
    static func secretPart(serial: String, secret: String) -> String {
        let code = Array(HMAC<SHA256>.authenticationCode(for: Data(("PSPRO2:" + serial).utf8), using: SymmetricKey(data: Data(secret.utf8))))
        return String((0..<16).map { alphabet[Int((UInt16(code[2 * $0]) << 8 | UInt16(code[2 * $0 + 1])) % 31)] })
    }

    // The whole key for a serial (5 characters from the alphabet), in its usual form.
    static func make(serial: String, secret: String) -> String? {
        guard serial.count == serialLength, serial.allSatisfy(alphabet.contains) else { return nil }
        let body = serial + secretPart(serial: serial, secret: secret)
        return grouped(body + checkPart(body))
    }

    // The key in its usual form, or what's wrong with how it was typed (only the typo check, no secret needed).
    static func read(_ text: String) -> Result<String, Problem> {
        let raw = raw(text)
        guard raw.count == length else { return .failure(.length) }
        guard raw.allSatisfy(alphabet.contains) else { return .failure(.characters) }
        guard checkPart(String(raw.prefix(bodyLength))) == String(raw.suffix(length - bodyLength)) else { return .failure(.check) }
        return .success(grouped(raw))
    }

    // Was this key made with this secret?
    static func isGenuine(_ text: String, secret: String) -> Bool {
        guard !secret.isEmpty, case .success = read(text) else { return false }
        let raw = raw(text)
        let serial = String(raw.prefix(serialLength))
        return String(raw.dropFirst(serialLength).prefix(bodyLength - serialLength)) == secretPart(serial: serial, secret: secret)
    }
}

final class Pro {
    static let shared = Pro()

    // The secret keys are checked with (built in by build.sh). Empty: nothing is locked. Checks only: --pro-secret.
    var secret = ProConfig.keySecret
    var enabled: Bool { pretending != nil || !secret.isEmpty }

    // Pro is unlocked: everything works. (Always true in a build without the secret.)
    var unlocked: Bool { pretending ?? (secret.isEmpty || verified) }
    private(set) var key: String?  // the saved key
    private var verified = false
    private var pretending: Bool?  // pictures (--preview) show a state and touch no file
    var onChange: () -> Void = {}

    // Checks only: --pro-file F.
    var file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pitch Shift/Pro.json")

    // What Pro adds, for the unlock window.
    static let features = ["the Voice changer", "Natural ↔ Cartoon", "Bass ↔ Treble", "Auto EQ", "Deeper when slow",
                           "the Soundboard"]

    // Pictures only: a key made with a test secret (it unlocks nothing).
    static let exampleKey = ProKey.make(serial: "TEST2", secret: "pitch-shift-pro-test-secret") ?? ""

    private struct Saved: Codable {
        var key: String
        var unlocked: String?  // when (for people, not checked)
    }

    // For pictures: shows Pro locked or unlocked without reading or writing anything.
    func pretend(unlocked: Bool) {
        pretending = unlocked
        key = unlocked ? Self.exampleKey : nil
    }

    // At launch: reads the saved key and checks it (no internet).
    func load() {
        guard pretending == nil, !secret.isEmpty else { return }
        key = read()?.key
        verified = key.map { ProKey.isGenuine($0, secret: secret) } ?? false
    }

    // Locks Pro again and forgets the key (--pro-reset).
    func reset() {
        try? FileManager.default.removeItem(at: file)
        key = nil
        verified = false
        onChange()
    }

    // MARK: The saved file

    private func read() -> Saved? {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data),
              case .success(let key) = ProKey.read(saved.key) else { return nil }
        return Saved(key: key, unlocked: saved.unlocked)
    }

    private func write(_ saved: Saved) {
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(saved) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: Checking a key

    enum Outcome: Equatable {
        case unlocked
        case problem(String)
    }

    static func message(for problem: ProKey.Problem) -> String {
        problem == .characters ? "That key has a typo: keys never use 0, 1, I, L or O." : "That key has a typo. Check it and try again."
    }

    static let wrongKey = "That key doesn't work. Check it and try again."

    // Checks a typed key (typos first, then whether the owner's secret made it), then keeps it.
    func activate(_ typed: String) -> Outcome {
        guard !secret.isEmpty else { return .problem("Unlocking isn't set up in this copy of Pitch Shift.") }
        let key: String
        switch ProKey.read(typed) {
        case .success(let good): key = good
        case .failure(let problem): return .problem(Self.message(for: problem))
        }
        guard ProKey.isGenuine(key, secret: secret) else { return .problem(Self.wrongKey) }
        write(Saved(key: key, unlocked: ISO8601DateFormatter().string(from: Date())))
        self.key = key
        let was = unlocked
        verified = true
        if !was { onChange() }
        return .unlocked
    }

    // For --pro-status.
    var status: String {
        guard !secret.isEmpty else { return "Pro: not set up in this build (nothing is locked)" }
        guard let key else { return "Pro: locked (no key saved in \(file.path))" }
        let ending = "…-" + key.suffix(5)
        return verified ? "Pro: unlocked (key \(ending))" : "Pro: locked (key \(ending) saved, but it doesn't work in this copy)"
    }
}

// The unlock window: a sheet on the main window. Locked: "Pitch Shift Pro: $5", what it adds, the address to email
// for a key with an "Email for a key" button (opens Mail), a box for the key, and Unlock. Unlocked: a thank-you and
// the end of the key.
final class ProSheet: NSObject, NSTextFieldDelegate {
    static let shared = ProSheet()
    private var panel: NSPanel?
    private let field = NSTextField()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let unlockButton = NSButton(title: "Unlock", target: nil, action: nil)
    private let emailButton = NSButton(title: "Email for a key", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var width: CGFloat = 380  // the sheet's width: 380, or the window's width in a narrow window
    private lazy var fieldWidth = field.widthAnchor.constraint(equalToConstant: 340)
    var isOpen: Bool { panel != nil }

    // A new email to the owner, with the subject filled in (opens in the Mail app, or whatever app handles email).
    static let mailURL = URL(string: "mailto:\(ProConfig.email)?subject=Pitch%20Shift%20Pro%20key")

    override init() {
        super.init()
        emailButton.bezelStyle = .rounded
        emailButton.bezelColor = Theme.purple
        emailButton.target = self
        emailButton.action = #selector(email)
        emailButton.toolTip = ProConfig.email
        field.placeholderString = "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
        field.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        field.alignment = .center
        field.delegate = self
        field.setAccessibilityLabel("Your key")
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        fieldWidth.isActive = true
        message.font = .systemFont(ofSize: 12)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(close)
        unlockButton.bezelStyle = .rounded
        unlockButton.keyEquivalent = "\r"
        unlockButton.bezelColor = Theme.purple
        unlockButton.target = self
        unlockButton.action = #selector(unlock)
    }

    // `alone` (pictures only, the pro-alone state): its own window next to the main one instead of a sheet, for when
    // macOS can't picture a window with a sheet on it (an off-screen window).
    func show(on window: NSWindow, alone: Bool = false) {
        guard panel == nil else { return }
        width = min(380, max(300, window.frame.width.rounded(.down)))
        fieldWidth.constant = width - 40
        field.font = .monospacedSystemFont(ofSize: width < 340 ? 13 : 14, weight: .medium)
        message.preferredMaxLayoutWidth = width - 40
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Pitch Shift Pro"
        panel.appearance = window.appearance  // light or dark, like the main window
        let content = Pro.shared.unlocked ? unlockedView() : lockedView()
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        self.panel = panel
        if alone {
            panel.level = window.level
            panel.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: window.frame.minY - 20))
            panel.orderBack(nil)
            return
        }
        window.beginSheet(panel) { [weak self] _ in self?.panel = nil }
        if !Pro.shared.unlocked { panel.makeFirstResponder(field) }
    }

    @objc func close() {
        guard let panel else { return }
        panel.sheetParent?.endSheet(panel)
    }

    // The icon, a title and a line under it.
    private func header(_ heading: String, _ line: String) -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 48), icon.heightAnchor.constraint(equalToConstant: 48)])
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let about = NSTextField(wrappingLabelWithString: line)
        about.font = .systemFont(ofSize: 12)
        about.textColor = .secondaryLabelColor
        about.preferredMaxLayoutWidth = width - 40 - 60
        let words = NSStackView(views: [title, about])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 3
        let row = NSStackView(views: [icon, words])
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private func stack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        NSLayoutConstraint.activate([stack.widthAnchor.constraint(equalToConstant: width)])
        return stack
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [spacer] + buttons)
        row.spacing = 10
        NSLayoutConstraint.activate([row.widthAnchor.constraint(equalToConstant: width - 40)])
        return row
    }

    private func lockedView() -> NSView {
        let list = Pro.features.dropLast().joined(separator: ", ") + " and " + (Pro.features.last ?? "")
        let line = "\(list.prefix(1).uppercased() + list.dropFirst()). Email \(ProConfig.email) for a key."
        field.stringValue = ""
        field.isEnabled = true
        show("", color: .secondaryLabelColor)
        cancelButton.isEnabled = true
        unlockButton.isEnabled = false
        return stack([header("Pitch Shift Pro: \(ProConfig.price)", line), emailButton, field, message,
                      buttonRow([cancelButton, unlockButton])])
    }

    private func unlockedView() -> NSView {
        let key = Pro.shared.key.map { NSTextField(labelWithString: "Key …-\($0.suffix(5))") }
        key?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        key?.textColor = .secondaryLabelColor
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        return stack([header("Pitch Shift Pro", "Unlocked on this Mac. Thank you!")] + (key.map { [$0] } ?? []) + [buttonRow([done])])
    }

    private func show(_ text: String, color: NSColor) {
        message.stringValue = text
        message.textColor = color
        message.isHidden = text.isEmpty
    }

    // Typing or pasting: capitals, dashes put in, at most 25 characters; a full key is checked for typos right away.
    func controlTextDidChange(_ obj: Notification) {
        let raw = String(ProKey.raw(field.stringValue).prefix(ProKey.length))
        let grouped = ProKey.grouped(raw)
        if field.stringValue != grouped { field.stringValue = grouped }
        // Unlock works once the whole key is typed and has no typo.
        var typo: ProKey.Problem?
        if raw.count == ProKey.length, case .failure(let problem) = ProKey.read(raw) { typo = problem }
        unlockButton.isEnabled = raw.count == ProKey.length && typo == nil
        show(typo.map(Pro.message) ?? "", color: typo == nil ? .secondaryLabelColor : .systemRed)
    }

    @objc private func email() {
        guard let url = Self.mailURL, preview == nil else { return }  // pictures open nothing
        NSWorkspace.shared.open(url)
    }

    @objc private func unlock() {
        guard preview == nil else { return }
        switch Pro.shared.activate(field.stringValue) {
        case .unlocked:
            showDone()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.close() }
        case .problem(let text):
            show(text, color: .systemRed)
            panel?.makeFirstResponder(field)
        }
    }

    private func showDone() {
        show("Unlocked. Thank you!", color: .systemGreen)
        unlockButton.isEnabled = false
        cancelButton.isEnabled = false
        field.isEnabled = false
    }

    // Pictures: a key with a typo in the box, or the "Unlocked" message.
    func showTypo() {
        let key = Pro.exampleKey
        let last = key.last.flatMap { ProKey.alphabet.firstIndex(of: $0) } ?? 0
        field.stringValue = String(key.dropLast()) + String(ProKey.alphabet[(last + 1) % ProKey.alphabet.count])
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    func showUnlockedMessage() {
        field.stringValue = Pro.exampleKey
        showDone()
    }
}
