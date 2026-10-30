// Auto-update (Mac). Once a day at most, and from "Check for Updates…" in the menu, the app fetches PitchShift.pkg.sig
// from the latest GitHub release: a small file, signed with the owner's update key, that says which version it is and
// exactly what its installer's bytes are. This is the only thing in the app that goes online. If that version is newer,
// an Update button shows in the title bar (AppDelegate.showUpdateButton). A click downloads the pkg of that version to
// the caches folder, checks it, and opens it in the Mac's Installer, which asks for the password. The pkg's own scripts
// then close this app (preinstall) and open the new one (postinstall).
//
// The pkg runs as the Mac's admin, so nothing is opened unless the signature and the bytes check out. The version comes
// from the signed file, never from GitHub's tag, so an old signed pkg can't be passed off as a new one.
//
// The Installer is opened without waiting for it, so the main thread stays free: closing the app gives the mic back
// there (onQuitSignals in main.swift), and if the Installer is cancelled nothing has changed. The app can't replace
// itself, because the installed copy belongs to the Mac's admin.
import AppKit
import CryptoKit

extension Keys {
    static let updateChecked = "updateChecked"  // when GitHub last answered
    static let updateFound = "updateFound"      // the .sig file of a newer version: the button stays after a restart
}

enum AppVersion {
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    // "3.10.1" as [3, 10, 1]; nil unless it's numbers with dots between them.
    static func numbers(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in part.utf8.allSatisfy { (48...57).contains($0) } ? Int(part) : nil }
        return numbers.count == parts.count ? numbers : nil
    }

    // Compared as numbers: 3.10 is newer than 3.9, and 3.6 is the same as 3.6.0.
    static func isNewer(_ version: String, than other: String) -> Bool {
        guard var a = numbers(version), var b = numbers(other) else { return false }
        let count = max(a.count, b.count)
        a += Array(repeating: 0, count: count - a.count)
        b += Array(repeating: 0, count: count - b.count)
        return b.lexicographicallyPrecedes(a)
    }
}

// What PitchShift.pkg.sig says, once its signature is checked. The file has exactly these lines (made by
// tools/update-keys.swift, which must match):
//   PSUPDATE1
//   version 3.6.0
//   size 229733627
//   sha256 (64 hex characters: the pkg's bytes)
//   signature (128 hex characters: Ed25519, of all the lines above)
struct SignedUpdate: Equatable {
    let version: String, size: Int64, sha256: String

    private var signedText: String { "PSUPDATE1\nversion \(version)\nsize \(size)\nsha256 \(sha256)\n" }

    init(sig text: String, publicKey: String) throws {
        guard let key = ProKey.unhex(publicKey).flatMap({ try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }) else {
            throw Problem(message: "no public key to check it with")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        func value(_ line: Int, _ name: String) -> String? {
            lines[line].hasPrefix(name + " ") ? String(lines[line].dropFirst(name.count + 1)) : nil
        }
        guard lines.count == 6, lines[0] == "PSUPDATE1", lines[5].isEmpty,
              let version = value(1, "version"), AppVersion.numbers(version) != nil,
              let size = value(2, "size").flatMap({ Int64($0) }), size > 0,
              let sha256 = value(3, "sha256"), sha256.count == 64,
              let signature = value(4, "signature").flatMap(ProKey.unhex), signature.count == 64 else {
            throw Problem(message: "it isn't an update signature file")
        }
        self.version = version
        self.size = size
        self.sha256 = sha256
        guard key.isValidSignature(signature, for: Data(signedText.utf8)) else {
            throw Problem(message: "the signature doesn't match")
        }
    }

    // Pictures only.
    fileprivate init(preview version: String) {
        self.version = version
        size = 1
        sha256 = ""
    }

    // Is this file the pkg that was signed? Reads all of it (about 230 MB), so never on the main thread.
    func check(file: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw Problem(message: "can't read the file") }
        defer { try? handle.close() }
        var hash = SHA256(), read: Int64 = 0
        while let chunk = autoreleasepool(invoking: { try? handle.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            hash.update(data: chunk)
            read += Int64(chunk.count)
        }
        guard read == size else { throw Problem(message: "it has \(read) bytes, not the \(size) that were signed") }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw Problem(message: "its bytes aren't the ones that were signed")
        }
    }
}

final class Updater: NSObject, URLSessionDownloadDelegate {
    static let github = URL(string: "https://github.com/Gromhogg/pitch-shift/releases")!
    static let shared = Updater(
        publicKey: UpdateConfig.publicKey, current: AppVersion.current, releases: github,
        folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pitch Shift/Updates"),
        saves: true)

    private let publicKey: String
    private let current: String
    private let releases: URL  // holds latest/download/PitchShift.pkg.sig and download/vX.Y.Z/PitchShift.pkg
    private let folder: URL
    private let saves: Bool    // false for --check-update-from: the app's settings stay as they are
    private var defaults: UserDefaults { .standard }
    private let checkEvery: TimeInterval = 24 * 60 * 60
    private let installerID = "com.apple.installer"

    private(set) var found: SignedUpdate?  // a newer version
    private(set) var percent: Int?         // while the pkg downloads and is checked
    var enabled: Bool { !publicKey.isEmpty }

    var onChange: () -> Void = {}
    var heldBack: () -> Bool = { false }  // an app is using Pitch Shift Mic, or Test runs: no Installer now
    var tell: (String, String) -> Void = { _, _ in }
    var stopsBeforeOpening: ((URL) -> Void)?  // checks only: takes the place of the Installer

    private var fetching = false
    private var asked = false  // from the menu: say what happened
    private var downloaded: URL?

    private lazy var session: URLSession = {
        let setup = URLSessionConfiguration.ephemeral
        setup.timeoutIntervalForRequest = 60
        return URLSession(configuration: setup, delegate: self, delegateQueue: .main)
    }()

    init(publicKey: String, current: String, releases: URL, folder: URL, saves: Bool) {
        self.publicKey = publicKey
        self.current = current
        self.releases = releases
        self.folder = folder
        self.saves = saves
    }

    // Pictures: the button as it looks. Nothing goes online.
    func pretend(percent: Int?) {
        found = SignedUpdate(preview: "3.6.0")
        self.percent = percent
        onChange()
    }

    // MARK: Checking

    func start() {
        guard enabled else { return }
        if let text = defaults.string(forKey: Keys.updateFound), let update = try? SignedUpdate(sig: text, publicKey: publicKey),
           AppVersion.isNewer(update.version, than: current) {
            found = update
        } else {
            defaults.removeObject(forKey: Keys.updateFound)
        }
        // The pkg can't be deleted when it's opened, since the Installer still needs it, so it goes here: at the launch
        // the update ends with. It stays only if the Installer is open right now and still waiting to install it.
        let installing = !NSRunningApplication.runningApplications(withBundleIdentifier: installerID).isEmpty
        removeDownloads(except: installing ? found.map(pkg) : nil)
        onChange()
        checkIfDue()
    }

    private func checkIfDue() {
        let age = Date().timeIntervalSince(defaults.object(forKey: Keys.updateChecked) as? Date ?? .distantPast)
        if percent == nil && (age >= checkEvery || age < 0) { fetch() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60 * 60) { [weak self] in self?.checkIfDue() }
    }

    // "Check for Updates…"
    func checkNow() {
        guard enabled else { return }
        guard percent == nil else { tell("The update is downloading", "The Update button shows how far it has got."); return }
        asked = true
        fetch()
    }

    private func fetch() {
        guard !fetching else { return }
        fetching = true
        session.dataTask(with: releases.appendingPathComponent("latest/download/PitchShift.pkg.sig")) { [weak self] data, response, error in
            self?.fetched(data, error == nil ? response as? HTTPURLResponse : nil)
        }.resume()
    }

    private func fetched(_ data: Data?, _ response: HTTPURLResponse?) {
        let say: (String, String) -> Void = asked ? tell : { _, _ in }
        asked = false
        fetching = false
        guard percent == nil else { return }  // what's downloading must stay what was found
        guard let response else { say("Couldn't check for updates", "Check your internet connection and try again."); return }
        if saves { defaults.set(Date(), forKey: Keys.updateChecked) }
        guard response.statusCode != 404 else { say("No update found", "You have version \(current)."); return }
        guard response.statusCode == 200 else {
            say("Couldn't check for updates", "GitHub answered with error \(response.statusCode). Try again later.")
            return
        }
        let text = data.map { String(decoding: $0.prefix(1024), as: UTF8.self) } ?? ""
        guard let update = try? SignedUpdate(sig: text, publicKey: publicKey) else {
            say("The update failed its safety check", "Its signature doesn't match, so it won't be installed.")
            return
        }
        guard AppVersion.isNewer(update.version, than: current) else {
            found = nil
            if saves { defaults.removeObject(forKey: Keys.updateFound) }
            onChange()
            say("Pitch Shift is up to date", "You have version \(current).")
            return
        }
        found = update
        if saves { defaults.set(text, forKey: Keys.updateFound) }
        removeDownloads(except: pkg(update))
        onChange()
        say("Pitch Shift \(update.version) is available", "Click Update at the top of the window. It shows when no app is using Pitch Shift Mic.")
    }

    // MARK: Installing

    private func pkg(_ update: SignedUpdate) -> URL { folder.appendingPathComponent("PitchShift-\(update.version).pkg") }

    func install() {
        guard let update = found, percent == nil, !heldBack() else { onChange(); return }
        percent = 0
        onChange()
        if FileManager.default.fileExists(atPath: pkg(update).path) {
            openIfGood(pkg(update), update, fresh: false)  // kept from before: a Cancel in the Installer, or a call
        } else {
            download(update)
        }
    }

    private func download(_ update: SignedUpdate) {
        session.downloadTask(with: releases.appendingPathComponent("download/v\(update.version)/PitchShift.pkg")).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let update = found else { return }
        guard totalBytesWritten <= update.size else { downloadTask.cancel(); return }
        let now = Int(totalBytesWritten * 100 / update.size)
        if now != percent {
            percent = now
            onChange()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let update = found, (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? manager.removeItem(at: pkg(update))
        if (try? manager.moveItem(at: location, to: pkg(update))) != nil { downloaded = pkg(update) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task is URLSessionDownloadTask, let update = found else { return }
        if let file = downloaded, error == nil {
            downloaded = nil
            openIfGood(file, update, fresh: true)
        } else {
            done()
            tell("Couldn't download the update", "Check your internet connection and try again.")
        }
    }

    private func done() {
        percent = nil
        onChange()
    }

    private func openIfGood(_ file: URL, _ update: SignedUpdate, fresh: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let good = (try? update.check(file: file)) != nil
            DispatchQueue.main.async { [self] in
                guard good else {
                    try? FileManager.default.removeItem(at: file)
                    guard fresh else { download(update); return }
                    done()
                    tell("The update failed its safety check", "The download doesn't match its signature, so it won't be installed.")
                    return
                }
                done()
                // Otherwise the file is kept: the button comes back once Pitch Shift Mic is free.
                if !heldBack() { open(file) }
            }
        }
    }

    private func open(_ file: URL) {
        if let stopsBeforeOpening { stopsBeforeOpening(file); return }
        guard let installer = NSWorkspace.shared.urlForApplication(withBundleIdentifier: installerID) else { couldNotOpen(); return }
        NSWorkspace.shared.open([file], withApplicationAt: installer, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if error != nil { DispatchQueue.main.async { self?.couldNotOpen() } }
        }
    }

    private func couldNotOpen() { tell("Couldn't open the Installer", "Try Update again in a moment.") }

    private func removeDownloads(except kept: URL?) {
        let manager = FileManager.default
        for file in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix("PitchShift-") && file.pathExtension == "pkg" && file.lastPathComponent != kept?.lastPathComponent {
            try? manager.removeItem(at: file)
        }
    }
}
