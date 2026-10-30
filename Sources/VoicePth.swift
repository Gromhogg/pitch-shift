// Opens a downloaded RVC voice (.pth) without Python. A .pth is a zip file: a pickle (Python's saved objects) that says
// what is in the voice, plus one file of numbers per tensor. In Python a pickle can run code when it's opened. This
// reader runs nothing: it knows only the few things a voice is made of and stops at anything else, and it checks every
// size and offset before using it, because voices come from strangers.
import Foundation

extension Data {
    fileprivate func number<T: FixedWidthInteger>(at offset: Int, as type: T.Type = T.self) -> T? {
        guard offset >= 0, offset <= count - MemoryLayout<T>.size else { return nil }
        return withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}

// A zip file's list of files. nil if it isn't a zip file that makes sense.
struct ZipListing {
    struct Entry {
        let name: String
        let method: UInt16  // 0: stored as is
        let packed: Int
        let size: Int
        let header: Int
    }

    let bytes: Data
    let entries: [Entry]

    init?(_ bytes: Data) {
        self.bytes = bytes
        var end = bytes.count - 22  // the end record is within the last 64 KB
        let lowest = max(0, end - 65535)
        while end >= lowest, bytes.number(at: end, as: UInt32.self) != 0x0605_4b50 { end -= 1 }
        guard end >= lowest, var count = bytes.number(at: end + 10, as: UInt16.self).map(Int.init),
              var at = bytes.number(at: end + 16, as: UInt32.self).map(Int.init) else { return nil }
        if count == 0xFFFF || at == 0xFFFF_FFFF {  // zip64 (PyTorch's own zip files use it)
            guard bytes.number(at: end - 20, as: UInt32.self) == 0x0706_4b50,
                  let record = bytes.number(at: end - 12, as: UInt64.self).map({ Int(clamping: $0) }),
                  bytes.number(at: record, as: UInt32.self) == 0x0606_4b50,
                  let total = bytes.number(at: record + 32, as: UInt64.self),
                  let start = bytes.number(at: record + 48, as: UInt64.self) else { return nil }
            count = Int(clamping: total)
            at = Int(clamping: start)
        }
        guard count <= 100_000 else { return nil }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard bytes.number(at: at, as: UInt32.self) == 0x0201_4b50,
                  let method = bytes.number(at: at + 10, as: UInt16.self),
                  let packed32 = bytes.number(at: at + 20, as: UInt32.self),
                  let size32 = bytes.number(at: at + 24, as: UInt32.self),
                  let nameLength = bytes.number(at: at + 28, as: UInt16.self).map(Int.init),
                  let extraLength = bytes.number(at: at + 30, as: UInt16.self).map(Int.init),
                  let commentLength = bytes.number(at: at + 32, as: UInt16.self).map(Int.init),
                  let header32 = bytes.number(at: at + 42, as: UInt32.self),
                  at + 46 + nameLength + extraLength + commentLength <= bytes.count else { return nil }
            var packed = Int(packed32), size = Int(size32), header = Int(header32)
            // Values too big for 32 bits are in the zip64 extra field, in this order.
            var extra = at + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd,
                  let id = bytes.number(at: extra, as: UInt16.self),
                  let length = bytes.number(at: extra + 2, as: UInt16.self).map(Int.init) {
                if id == 1 {
                    var field = extra + 4
                    let fieldEnd = min(field + length, extraEnd)
                    func large(_ value: inout Int) {
                        guard value == 0xFFFF_FFFF, field + 8 <= fieldEnd,
                              let wide = bytes.number(at: field, as: UInt64.self) else { return }
                        value = Int(clamping: wide)
                        field += 8
                    }
                    large(&size)
                    large(&packed)
                    large(&header)
                }
                extra += 4 + length
            }
            guard header < bytes.count else { return nil }
            let name = String(decoding: bytes[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(name: name, method: method, packed: packed, size: size, header: header))
            at += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    // Where a file that was stored as is lies in the zip file.
    func content(_ entry: Entry) -> Range<Int>? {
        guard entry.method == 0, entry.packed == entry.size,
              bytes.number(at: entry.header, as: UInt32.self) == 0x0403_4b50,
              let nameLength = bytes.number(at: entry.header + 26, as: UInt16.self).map(Int.init),
              let extraLength = bytes.number(at: entry.header + 28, as: UInt16.self).map(Int.init) else { return nil }
        let start = entry.header + 30 + nameLength + extraLength
        guard start <= bytes.count, entry.size <= bytes.count - start else { return nil }
        return start..<(start + entry.size)
    }

    // A zip file about to be unpacked: nil if it would be huge or write outside the folder it's unpacked in.
    func problem(shown: String) -> Problem? {
        var total = 0
        for entry in entries {
            let (sum, overflow) = total.addingReportingOverflow(entry.size)
            guard !overflow, sum <= 4_000_000_000 else { return Problem(message: "“\(shown)” is too big to be a voice.") }
            total = sum
            if entry.name.hasPrefix("/") || entry.name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..") {
                return Problem(message: "“\(shown)” can't be unpacked.")
            }
        }
        return nil
    }
}

// What a .pth holds.
final class PthFile {
    enum Number: Equatable { case half, float, double }

    struct Tensor {
        let number: Number
        let file: String  // the zip entry's last part
        let start: Int    // in numbers from the file's start
        let shape: [Int]
    }

    enum Value {
        case nothing
        case bool(Bool)
        case int(Int)
        case real(Double)
        case text(String)
        case tensor(Tensor)
        case list(Int)  // lists and tuples: an index into `lists`, so a hostile file can't nest them into a stack overflow
        case dict(Int)  // an index into `dicts`
        case name(String)  // a Python name the file used: only ones on the list below get past REDUCE
        case storage(Number, String)
        case mark
    }

    private let archive: ZipListing
    private var files: [String: ZipListing.Entry] = [:]
    private(set) var lists: [[Value]] = []
    private(set) var dicts: [[String: Value]] = []
    private(set) var top: Value = .nothing

    struct Refused: Error {
        enum Why { case older, notVoice }
        let why: Why
    }

    // Older .pth files are a bare pickle followed by numbers, with no zip file around them.
    init(_ url: URL) throws {
        let bytes = try Data(contentsOf: url, options: .alwaysMapped)
        guard bytes.prefix(2) == Data([0x50, 0x4B]) else {
            throw Refused(why: bytes.first == 0x80 ? .older : .notVoice)
        }
        guard let archive = ZipListing(bytes) else { throw Refused(why: .notVoice) }
        self.archive = archive
        guard let pickle = archive.entries.first(where: { $0.name.hasSuffix("/data.pkl") || $0.name == "data.pkl" }) else {
            throw Refused(why: .notVoice)
        }
        let root = String(pickle.name.dropLast("data.pkl".count))
        for entry in archive.entries where entry.name.hasPrefix(root) { files[String(entry.name.dropFirst(root.count))] = entry }
        if let order = files["byteorder"], let range = archive.content(order), bytes[range] != Data("little".utf8) {
            throw Refused(why: .notVoice)
        }
        guard let range = archive.content(pickle), range.count <= 8_000_000 else { throw Refused(why: .notVoice) }
        try read(bytes[range])
    }

    // The numbers of a tensor stored in row order (the only way a voice stores them), as 32-bit floats.
    func floats(_ tensor: Tensor) -> [Float]? {
        var count = 1
        for dim in tensor.shape {
            guard dim >= 0 else { return nil }
            let (product, overflow) = count.multipliedReportingOverflow(by: dim)
            guard !overflow, product <= 400_000_000 else { return nil }
            count = product
        }
        let size = tensor.number == .half ? 2 : tensor.number == .float ? 4 : 8
        guard let entry = files["data/" + tensor.file], let range = archive.content(entry), tensor.start >= 0,
              tensor.start <= range.count / size, count <= range.count / size - tensor.start else { return nil }
        let first = range.lowerBound + tensor.start * size
        return archive.bytes.withUnsafeBytes { raw in
            let source = UnsafeRawBufferPointer(rebasing: raw[first..<(first + count * size)])
            return [Float](unsafeUninitializedCapacity: count) { out, made in
                switch tensor.number {
                case .half: for i in 0..<count { out[i] = PthFile.half(source.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)) }
                case .float: for i in 0..<count { out[i] = source.loadUnaligned(fromByteOffset: i * 4, as: Float.self) }
                case .double: for i in 0..<count { out[i] = Float(source.loadUnaligned(fromByteOffset: i * 8, as: Double.self)) }
                }
                made = count
            }
        }
    }

    // 16-bit float to 32-bit, by hand: Swift's Float16 doesn't exist on Intel.
    private static func half(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16, exponent = UInt32(bits >> 10) & 31, fraction = UInt32(bits) & 0x3FF
        if exponent == 31 { return Float(bitPattern: sign | 0x7F80_0000 | fraction << 13) }
        if exponent > 0 { return Float(bitPattern: sign | (exponent + 112) << 23 | fraction << 13) }
        let value = Float(fraction) * Float(sign: .plus, exponent: -24, significand: 1)
        return sign != 0 ? -value : value
    }

    // MARK: The pickle

    private func read(_ pickle: Data) throws {
        var at = pickle.startIndex
        let end = pickle.endIndex
        var stack: [Value] = []
        var memo: [UInt32: Value] = [:]

        func bytes(_ n: Int) throws -> Data {
            guard n >= 0, n <= end - at else { throw Refused(why: .notVoice) }
            defer { at += n }
            return pickle[at..<(at + n)]
        }
        func unsigned(_ n: Int) throws -> UInt32 {
            var value: UInt32 = 0
            for (i, byte) in try bytes(n).enumerated() { value |= UInt32(byte) << UInt32(8 * i) }
            return value
        }
        func pop() throws -> Value {
            guard let value = stack.popLast() else { throw Refused(why: .notVoice) }
            return value
        }
        func popToMark() throws -> [Value] {
            guard let mark = stack.lastIndex(where: { if case .mark = $0 { return true } else { return false } }) else {
                throw Refused(why: .notVoice)
            }
            defer { stack.removeSubrange(mark...) }
            return Array(stack[(mark + 1)...])
        }
        func list(_ items: [Value]) -> Value {
            lists.append(items)
            return .list(lists.count - 1)
        }
        func keyText(_ key: Value) throws -> String {
            switch key {
            case .text(let text): return text
            case .int(let n): return String(n)
            default: throw Refused(why: .notVoice)
            }
        }
        func setItems(_ items: [Value]) throws {
            guard items.count % 2 == 0, case .dict(let index) = try pop() else { throw Refused(why: .notVoice) }
            stack.append(.dict(index))
            for i in stride(from: 0, to: items.count, by: 2) { dicts[index][try keyText(items[i])] = items[i + 1] }
        }
        func append(_ items: [Value]) throws {
            guard case .list(let index) = try pop() else { throw Refused(why: .notVoice) }
            stack.append(.list(index))
            lists[index] += items
        }

        loop: while true {
            guard at < end else { throw Refused(why: .notVoice) }
            let code = pickle[at]
            at += 1
            switch code {
            case 0x80: _ = try bytes(1)  // PROTO
            case 0x2E: break loop        // STOP
            case 0x28: stack.append(.mark)
            case 0x4E: stack.append(.nothing)
            case 0x88: stack.append(.bool(true))
            case 0x89: stack.append(.bool(false))
            case 0x4B: stack.append(.int(Int(try unsigned(1))))
            case 0x4D: stack.append(.int(Int(try unsigned(2))))
            case 0x4A: stack.append(.int(Int(Int32(bitPattern: try unsigned(4)))))
            case 0x8A:  // LONG1
                let raw = try bytes(Int(try unsigned(1)))
                guard raw.count <= 8 else { throw Refused(why: .notVoice) }
                var value: UInt64 = (raw.last ?? 0) >= 0x80 ? .max : 0
                for byte in raw.reversed() { value = value << 8 | UInt64(byte) }
                stack.append(.int(Int(truncatingIfNeeded: value)))
            case 0x47:  // BINFLOAT, big-endian
                var value: UInt64 = 0
                for byte in try bytes(8) { value = value << 8 | UInt64(byte) }
                stack.append(.real(Double(bitPattern: value)))
            case 0x58: stack.append(.text(String(decoding: try bytes(Int(try unsigned(4))), as: UTF8.self)))
            case 0x55: stack.append(.text(String(decoding: try bytes(Int(try unsigned(1))), as: UTF8.self)))
            case 0x54: stack.append(.text(String(decoding: try bytes(Int(try unsigned(4))), as: UTF8.self)))
            case 0x71: guard let top = stack.last else { throw Refused(why: .notVoice) }; memo[try unsigned(1)] = top
            case 0x72: guard let top = stack.last else { throw Refused(why: .notVoice) }; memo[try unsigned(4)] = top
            case 0x68, 0x6A:
                guard let value = memo[try unsigned(code == 0x68 ? 1 : 4)] else { throw Refused(why: .notVoice) }
                stack.append(value)
            case 0x7D:
                dicts.append([:])
                stack.append(.dict(dicts.count - 1))
            case 0x5D, 0x29: stack.append(list([]))
            case 0x85, 0x86, 0x87:
                let n = Int(code) - 0x84
                guard stack.count >= n else { throw Refused(why: .notVoice) }
                let items = Array(stack.suffix(n))
                stack.removeLast(n)
                stack.append(list(items))
            case 0x74: stack.append(list(try popToMark()))
            case 0x73:
                let value = try pop()
                let key = try pop()
                try setItems([key, value])
            case 0x75: try setItems(try popToMark())
            case 0x61: try append([try pop()])
            case 0x65: try append(try popToMark())
            case 0x63:  // GLOBAL: two lines of text, only remembered here
                let names = try [line(pickle, &at), line(pickle, &at)]
                stack.append(.name(names.joined(separator: " ")))
            case 0x62:  // BUILD: extra details on a saved dict (training checkpoints have some), left out here
                _ = try pop()
                guard case .dict? = stack.last else { throw Refused(why: .notVoice) }
            case 0x51:  // BINPERSID: ("storage", type, file, device, size)
                guard case .list(let index) = try pop(), lists[index].count == 5,
                      case .text("storage") = lists[index][0], case .name(let type) = lists[index][1],
                      case .text(let file) = lists[index][2], let number = Self.storages[type] else {
                    throw Refused(why: .notVoice)
                }
                stack.append(.storage(number, file))
            case 0x52:  // REDUCE
                guard case .list(let arguments) = try pop(), case .name(let name) = try pop() else {
                    throw Refused(why: .notVoice)
                }
                stack.append(try build(name, lists[arguments]))
            default:
                throw Refused(why: .notVoice)
            }
        }
        guard let result = stack.last else { throw Refused(why: .notVoice) }
        top = result
    }

    private func line(_ pickle: Data, _ at: inout Data.Index) throws -> String {
        guard let newline = pickle[at...].firstIndex(of: 0x0A), newline - at <= 200 else { throw Refused(why: .notVoice) }
        defer { at = newline + 1 }
        return String(decoding: pickle[at..<newline], as: UTF8.self)
    }

    private static let storages: [String: Number] = ["torch HalfStorage": .half, "torch FloatStorage": .float, "torch DoubleStorage": .double]

    // The only Python calls a voice needs, done here by hand. Anything else stops the reading.
    private func build(_ name: String, _ arguments: [Value]) throws -> Value {
        switch name {
        case "collections OrderedDict", "typing OrderedDict":
            guard arguments.isEmpty else { throw Refused(why: .notVoice) }
            dicts.append([:])
            return .dict(dicts.count - 1)
        case "torch._utils _rebuild_tensor_v2", "torch._utils _rebuild_tensor":
            guard arguments.count >= 4, case .storage(let number, let file) = arguments[0],
                  case .int(let start) = arguments[1], let shape = ints(arguments[2]), let strides = ints(arguments[3]),
                  shape.count == strides.count, inRowOrder(shape, strides) else { throw Refused(why: .notVoice) }
            return .tensor(Tensor(number: number, file: file, start: start, shape: shape))
        case "torch._utils _rebuild_parameter":
            guard let tensor = arguments.first, case .tensor = tensor else { throw Refused(why: .notVoice) }
            return tensor
        default:
            throw Refused(why: .notVoice)
        }
    }

    func ints(_ value: Value) -> [Int]? {
        guard case .list(let index) = value else { return nil }
        var numbers: [Int] = []
        for item in lists[index] {
            guard case .int(let n) = item else { return nil }
            numbers.append(n)
        }
        return numbers
    }

    private func inRowOrder(_ shape: [Int], _ strides: [Int]) -> Bool {
        var step = 1
        for (dim, stride) in zip(shape, strides).reversed() {
            guard dim == 1 || stride == step else { return false }
            let (product, overflow) = step.multipliedReportingOverflow(by: dim)
            guard !overflow else { return false }
            step = product
        }
        return true
    }
}
