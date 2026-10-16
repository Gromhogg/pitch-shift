// Pitch Shift Pro: the $5 unlock (plan: notes/paid-unlock-plan.md, server: server/).
// A key is entered once: the server checks it and answers with a token signed with its private key. The token is
// kept in ~/Library/Application Support/Pitch Shift/Pro.json and checked at every launch with the public key in
// ProConfig.swift, with no internet. While Pro is locked, the paid settings use the free version's values (Free);
// what was saved is kept and comes back once Pro is unlocked.
import AppKit
import CryptoKit
import IOKit

// What the free version uses in place of the paid settings.
enum Free {
    static let cartoon: Float = 1  // the voice style stays at Cartoon
    static let slowDeeper = false  // Deeper when slow stays off
    static let tone: Float = 0     // Bass ↔ Treble stays in the middle
}

// The key: 25 characters, XXXXX-XXXXX-XXXXX-XXXXX-XXXXX, from 31 characters that can't be read two ways. The first
// 21 are the secret part; the last 4 a check part, so a typo is caught here before anything goes online. Must match
// server/src/key.js exactly.
enum ProKey {
    static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
    static let length = 25, bodyLength = 21

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

    // The first 4 bytes of SHA-256("PSPRO1:" + body), as a number below 31^4, in 4 characters.
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

    // The key in its usual form, or what's wrong with it.
    static func read(_ text: String) -> Result<String, Problem> {
        let raw = raw(text)
        guard raw.count == length else { return .failure(.length) }
        guard raw.allSatisfy(alphabet.contains) else { return .failure(.characters) }
        guard checkPart(String(raw.prefix(bodyLength))) == String(raw.suffix(length - bodyLength)) else { return .failure(.check) }
        return .success(grouped(raw))
    }

    // The id a token carries for its key: the first 16 bytes of SHA-256("pitch-shift-pro key id:" + key), in hex.
    static func id(_ key: String) -> String {
        hex(SHA256.hash(data: Data(("pitch-shift-pro key id:" + key).utf8)).prefix(16))
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

final class Pro {
    static let shared = Pro()

    // A build without the server set up (no public key) has nothing locked.
    static let publicKey: Curve25519.Signing.PublicKey? = Data(base64Encoded: ProConfig.publicKey)
        .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    var enabled: Bool { pretending != nil || Self.publicKey != nil }

    // Pro is unlocked: everything works. (Always true in a build without the server set up.)
    var unlocked: Bool { pretending ?? (Self.publicKey == nil || verified) }
    private(set) var key: String?  // the saved key
    private var verified = false
    private var pretending: Bool?  // pictures (--preview) show a state and touch no file
    var onChange: () -> Void = {}

    // Checks only: --pro-file F and --pro-server URL.
    var file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pitch Shift/Pro.json")
    var server = ProConfig.server

    // What Pro adds, for the unlock window.
    static let features = ["Natural ↔ Cartoon", "Bass ↔ Treble", "Deeper when slow", "the Soundboard"]

    private struct Saved: Codable {
        var key: String
        var token: String?
        var unlocked: String?  // when (for people, not checked)
        var checked: Double?   // last /check, seconds since 1970
    }

    // This Mac's id for the server: a SHA-256 of the Mac's hardware id mixed with "pitch-shift-pro", so it can't be
    // traced back or matched with anything else.
    static let machine: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? ""
        return ProKey.hex(SHA256.hash(data: Data(("pitch-shift-pro machine v1:" + uuid).utf8)).prefix(16))
    }()

    // For pictures: shows Pro locked or unlocked without reading or writing anything.
    func pretend(unlocked: Bool) {
        pretending = unlocked
        key = unlocked ? "FQH6E-GT28H-MM9M6-3PNV8-JE5JA" : nil  // the example key from server/test (unlocks nothing)
    }

    // At launch: reads the saved key and token and checks the token (no internet). If the token doesn't check out
    // but a key is saved (for example after a new server key), the key is sent again quietly in the background.
    func load(retry: Bool = false) {
        guard pretending == nil, Self.publicKey != nil else { return }
        let saved = read()
        key = saved?.key
        verified = saved.map { tokenIsGood($0.token, for: $0.key) } ?? false
        guard let saved else { return }
        if !verified && retry {
            activate(saved.key) { _ in }
        } else if verified && retry {
            recheckIfDue(saved)
        }
    }

    // Locks Pro again and forgets the key (--pro-reset).
    func reset() {
        try? FileManager.default.removeItem(at: file)
        key = nil
        verified = false
        onChange()
    }

    // MARK: Checking a token

    private func base64url(_ text: Substring) -> Data? {
        var clean = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        clean += String(repeating: "=", count: (4 - clean.count % 4) % 4)
        return Data(base64Encoded: clean)
    }

    // A token is good when its signature checks out with the public key and it was made for this key and this Mac.
    func tokenIsGood(_ token: String?, for key: String) -> Bool {
        guard let publicKey = Self.publicKey, let token else { return false }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = base64url(parts[0]), let signature = base64url(parts[1]),
              publicKey.isValidSignature(signature, for: Data(parts[0].utf8)),
              let fields = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return false }
        return fields["v"] as? Int == 1 && fields["p"] as? String == "pitch-shift-pro"
            && fields["k"] as? String == ProKey.id(key) && fields["m"] as? String == Self.machine
    }

    // MARK: The saved file

    private func read() -> Saved? {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data),
              case .success(let key) = ProKey.read(saved.key) else { return nil }
        return Saved(key: key, token: saved.token, unlocked: saved.unlocked, checked: saved.checked)
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

    // MARK: Talking to the server

    enum Outcome: Equatable {
        case unlocked
        case problem(String)
    }

    static func message(for problem: ProKey.Problem) -> String {
        problem == .characters ? "That key has a typo: keys never use 0, 1, I, L or O." : "That key has a typo. Check it and try again."
    }

    private static func message(forServer error: String?) -> String {
        switch error {
        case "typo": return message(for: .check)
        case "not-found": return "That key wasn't found. If you just bought it, try again in a minute."
        case "revoked": return "That key was turned off because the payment was refunded."
        case "test-key": return "That's a test key. It doesn't work in this version."
        case "rate-limited": return "Too many tries. Wait a minute and try again."
        default: return "Something went wrong. Try again in a minute."
        }
    }

    // POSTs { key, machine } to the server; answers with the JSON reply, or nil when the server can't be reached.
    private func post(_ path: String, key: String, done: @escaping (Int, [String: Any]?) -> Void) {
        guard let url = URL(string: server + path) else { done(0, nil); return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["key": key, "machine": Self.machine, "app": version])
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let reply = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done(status, reply) }
        }.resume()
    }

    // Checks a typed key (typos first, with no internet), then asks the server, then keeps the token.
    func activate(_ typed: String, done: @escaping (Outcome) -> Void) {
        guard Self.publicKey != nil, !server.isEmpty else { done(.problem("Unlocking isn't set up in this copy of Pitch Shift.")); return }
        let key: String
        switch ProKey.read(typed) {
        case .success(let good): key = good
        case .failure(let problem): done(.problem(Self.message(for: problem))); return
        }
        post("/activate", key: key) { [self] status, reply in
            guard status != 0 else { done(.problem("Can't reach the internet. Check your connection and try again.")); return }
            guard reply?["ok"] as? Bool == true, let token = reply?["token"] as? String else {
                done(.problem(Self.message(forServer: reply?["error"] as? String)))
                return
            }
            guard tokenIsGood(token, for: key) else { done(.problem(Self.message(forServer: "bad-token"))); return }
            write(Saved(key: key, token: token, unlocked: ISO8601DateFormatter().string(from: Date()), checked: Date().timeIntervalSince1970))
            self.key = key
            let was = unlocked
            verified = true
            if !was { onChange() }
            done(.unlocked)
        }
    }

    // ProConfig.recheckDays > 0: every so many days, asks whether the key was turned off (a refund). Only a clear
    // "revoked" locks Pro; no internet or any other answer changes nothing.
    private func recheckIfDue(_ saved: Saved) {
        guard ProConfig.recheckDays > 0, !server.isEmpty,
              Date().timeIntervalSince1970 - (saved.checked ?? 0) > Double(ProConfig.recheckDays) * 86_400 else { return }
        post("/check", key: saved.key) { [self] status, reply in
            guard status == 200, let answer = reply?["status"] as? String else { return }
            if answer == "revoked" {
                write(Saved(key: saved.key, token: nil, unlocked: nil, checked: Date().timeIntervalSince1970))
                verified = false
                onChange()
            } else {
                write(Saved(key: saved.key, token: saved.token, unlocked: saved.unlocked, checked: Date().timeIntervalSince1970))
            }
        }
    }

    // For --pro-status.
    var status: String {
        guard Self.publicKey != nil else { return "Pro: not set up in this build (nothing is locked)" }
        guard let key else { return "Pro: locked (no key saved in \(file.path))" }
        let ending = "…-" + key.suffix(5)
        return verified ? "Pro: unlocked (key \(ending), this Mac \(Self.machine))" : "Pro: locked (key \(ending) saved, but its token doesn't check out)"
    }
}

// The unlock window: a sheet on the main window. Locked: Buy for $5, a box for the key, Unlock. Unlocked: a thank-you
// and the end of the key.
final class ProSheet: NSObject, NSTextFieldDelegate {
    static let shared = ProSheet()
    private var panel: NSPanel?
    private let field = NSTextField()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let unlockButton = NSButton(title: "Unlock", target: nil, action: nil)
    private let buyButton = NSButton(title: "Buy for \(ProConfig.price)", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var busy = false
    private var width: CGFloat = 380  // the sheet's width: 380, or the window's width in a narrow window
    private lazy var fieldWidth = field.widthAnchor.constraint(equalToConstant: 340)
    var isOpen: Bool { panel != nil }

    override init() {
        super.init()
        buyButton.bezelStyle = .rounded
        buyButton.bezelColor = Theme.purple
        buyButton.target = self
        buyButton.action = #selector(buy)
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

    // The icon, "Pitch Shift Pro" and one line under it.
    private func header(_ line: String) -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 48), icon.heightAnchor.constraint(equalToConstant: 48)])
        let title = NSTextField(labelWithString: "Pitch Shift Pro")
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
        let line = "\(list.prefix(1).uppercased() + list.dropFirst()). \(ProConfig.price) once, for all your Macs."
        buyButton.isEnabled = URL(string: ProConfig.buyURL) != nil && !ProConfig.buyURL.isEmpty
        field.stringValue = ""
        field.isEnabled = true
        show("", color: .secondaryLabelColor)
        cancelButton.isEnabled = true
        unlockButton.isEnabled = false
        busy = false
        return stack([header(line), buyButton, field, message, buttonRow([cancelButton, unlockButton])])
    }

    private func unlockedView() -> NSView {
        let key = Pro.shared.key.map { NSTextField(labelWithString: "Key …-\($0.suffix(5))") }
        key?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        key?.textColor = .secondaryLabelColor
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        return stack([header("Unlocked on this Mac. Thank you!")] + (key.map { [$0] } ?? []) + [buttonRow([done])])
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
        unlockButton.isEnabled = raw.count == ProKey.length && typo == nil && !busy
        show(typo.map(Pro.message) ?? "", color: typo == nil ? .secondaryLabelColor : .systemRed)
    }

    @objc private func buy() {
        guard let url = URL(string: ProConfig.buyURL), preview == nil else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func unlock() {
        guard !busy, preview == nil else { return }
        busy = true
        unlockButton.isEnabled = false
        field.isEnabled = false
        show("Checking…", color: .secondaryLabelColor)
        Pro.shared.activate(field.stringValue) { [weak self] outcome in
            guard let self else { return }
            busy = false
            field.isEnabled = true
            switch outcome {
            case .unlocked:
                showDone()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.close() }
            case .problem(let text):
                show(text, color: .systemRed)
                unlockButton.isEnabled = true
                panel?.makeFirstResponder(field)
            }
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
        field.stringValue = "FQH6E-GT28H-MM9M6-3PNV8-JE5JB"
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    func showUnlockedMessage() {
        field.stringValue = "FQH6E-GT28H-MM9M6-3PNV8-JE5JA"
        showDone()
    }
}
