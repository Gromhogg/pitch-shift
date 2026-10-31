// Update signing, for the owner: the program behind tools/update-keys.sh (see there for how to use it).
// Runs with the Swift that comes with the Mac's Command Line Tools; nothing else to install.
//
// PKG.sig, the file the app checks, has exactly these lines (must match SignedUpdate in Sources/Updater.swift):
//   PSUPDATE1
//   version 3.6.0
//   size 229733627
//   sha256 (64 hex characters: the pkg's bytes)
//   signature (128 hex characters: Ed25519, of all the lines above)
import CryptoKit
import Foundation

let environment = ProcessInfo.processInfo.environment
let folder = URL(fileURLWithPath: environment["PITCH_SHIFT_KEYS_DIR"]
    ?? NSHomeDirectory() + "/Library/Application Support/Pitch Shift Keys")
let privateFile = folder.appendingPathComponent("update-private.txt")
let publicFile = folder.appendingPathComponent("update-public.txt")

func stop(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}

func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
func unhex(_ text: String) -> Data? {
    let text = text.filter { !$0.isWhitespace }
    guard text.count % 2 == 0 else { return nil }
    var data = Data(), index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
        data.append(byte)
        index = next
    }
    return data
}

func readText(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
func loadPrivate() -> Curve25519.Signing.PrivateKey? {
    readText(privateFile).flatMap(unhex).flatMap { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
}
// The public half that goes into the app: what build.sh uses.
func builtInPublic() -> Curve25519.Signing.PublicKey? {
    let text = environment["UPDATE_PUBLIC_KEY"].flatMap { $0.isEmpty ? nil : $0 } ?? readText(publicFile)
    return text.flatMap(unhex).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
}

// The private half, once it's sure the app could check what it signs. A pair that doesn't match would leave every copy
// of the app refusing the update.
func matchingPrivate() -> Curve25519.Signing.PrivateKey {
    guard let signer = loadPrivate() else {
        stop("No update-private.txt that can be read in \(folder.path). Run tools/update-keys.sh setup, or copy your backup of the Pitch Shift Keys folder back.")
    }
    guard let publicKey = builtInPublic() else {
        stop("No public key to go with update-private.txt in \(folder.path). Run tools/update-keys.sh setup (it makes update-public.txt again from the private half).")
    }
    guard signer.publicKey.rawRepresentation == publicKey.rawRepresentation else {
        stop("update-private.txt doesn't belong with the public key that goes into the app, so the app would refuse this update.")
    }
    return signer
}

// Writes a file only this Mac user can read.
func writePrivate(_ text: String, to url: URL) {
    guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
        stop("Couldn't write \(url.path)")
    }
}

func sha256(of file: URL) -> (hash: String, size: Int64)? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    var hash = SHA256(), size: Int64 = 0
    while let chunk = autoreleasepool(invoking: { try? handle.read(upToCount: 1 << 20) }), !chunk.isEmpty {
        hash.update(data: chunk)
        size += Int64(chunk.count)
    }
    return (hex(hash.finalize()), size)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first ?? "" {
case "setup":
    let manager = FileManager.default
    let havePrivate = manager.fileExists(atPath: privateFile.path), havePublic = manager.fileExists(atPath: publicFile.path)
    if havePrivate || havePublic {
        if havePrivate && !havePublic, let key = loadPrivate() {
            writePrivate(hex(key.publicKey.rawRepresentation) + "\n", to: publicFile)
            print("The update key pair is in \(folder.path) (update-public.txt was missing and was made again from the private half).")
        } else if !havePrivate {
            stop("update-public.txt is in \(folder.path) but update-private.txt is missing. Copy it back from your backup of the Pitch Shift Keys folder (a new pair would make every copy of the app refuse new updates).")
        } else if loadPrivate() == nil {
            stop("update-private.txt in \(folder.path) can't be read. Copy it back from your backup; nothing was changed.")
        } else {
            print("The update key pair is already in \(folder.path); nothing was changed.")
        }
        exit(0)
    }
    try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    let key = Curve25519.Signing.PrivateKey()
    writePrivate(hex(key.rawRepresentation) + "\n", to: privateFile)
    writePrivate(hex(key.publicKey.rawRepresentation) + "\n", to: publicFile)
    print("Made an update key pair in \(folder.path): update-private.txt (signs updates: never share it, never put it in git) and update-public.txt (goes into the app).")
    print("Back up the whole Pitch Shift Keys folder now (for example on a USB stick).")

case "check":
    _ = matchingPrivate()
    print("The update key pair is good.")

case "sign":
    guard arguments.count == 3 else { stop("Use: tools/update-keys.sh sign PKG VERSION") }
    let pkg = URL(fileURLWithPath: arguments[1]), version = arguments[2]
    guard version.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
        stop("The version must be numbers with dots between them, like 3.6.0: the app reads it as numbers.")
    }
    let signer = matchingPrivate()
    guard let (hash, size) = sha256(of: pkg), size > 0 else { stop("Can't read \(pkg.path)") }
    let message = "PSUPDATE1\nversion \(version)\nsize \(size)\nsha256 \(hash)\n"
    guard let signature = try? signer.signature(for: Data(message.utf8)) else { stop("Couldn't sign \(pkg.path)") }
    let out = pkg.appendingPathExtension("sig")
    do {
        try (message + "signature \(hex(signature))\n").write(to: out, atomically: true, encoding: .utf8)
    } catch { stop("Couldn't write \(out.path)") }
    print("Signed version \(version): \(out.path)")

case "help", "-h", "--help", "":
    print("""
    tools/update-keys.sh setup                makes your update key pair, once (never replaces one that's there)
    tools/update-keys.sh check                says whether the two halves belong together
    tools/update-keys.sh sign PKG VERSION     writes PKG.sig next to PKG
    """)
default:
    stop("Unknown: \(arguments[0]) (try tools/update-keys.sh help)")
}
