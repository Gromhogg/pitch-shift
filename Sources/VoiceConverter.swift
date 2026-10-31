// Turns a downloaded RVC v2 voice (.pth) into a voice folder, in seconds and with no Python: reads the voice's numbers
// (VoicePth.swift), works out the weights the AI voice needs, and writes them into a copy of a template made for its
// sample rate (voices/templates/, made by tools/voice-converter/make_template.py). The model.mil and weight.bin it
// writes are byte for byte what tools/voice-converter/convert_voice.py writes, so the rounding below follows PyTorch and
// coremltools step by step. Keep the two in step. The AI voice runs only on Apple silicon, and Swift's Float16 exists
// only there, so an Intel Mac stops at a plain message.
import Foundation

#if arch(arm64)
import Accelerate
import CoreML
import CryptoKit

enum VoiceConverter {
    // Writes <name>.mlmodelc and a voice.json with no Natural block into `folder`. `shown`: the file's name, for messages.
    static func convert(_ pth: URL, shown: String, name: String, into folder: URL) throws {
        let voice = try RVCVoice(pth, shown: shown)
        guard let template = VoiceLibrary.builtInFolder?.appendingPathComponent("templates/\(voice.rate)"),
              let text = try? String(contentsOf: template.appendingPathComponent("model.mil"), encoding: .utf8) else {
            throw Problem(message: "This copy of Pitch Shift is missing its voice files. Install it again.")
        }
        var writer = try ModelWriter(voice, shown: shown)
        var layout = try writer.fill(text)
        var analytics = try Data(contentsOf: template.appendingPathComponent("analytics/coremldata.bin"))
        var hash = SHA256()
        hash.update(data: layout.weights)
        hash.update(data: Data(layout.text.utf8))
        // Each voice gets its own model hash, not the template's.
        if let label = analytics.range(of: Data("modelHash".utf8)), label.upperBound + 8 + 44 <= analytics.count {
            let start = label.upperBound + 8
            analytics.replaceSubrange(start..<(start + 44), with: Data(hash.finalize()).base64EncodedData())
        }

        let fm = FileManager.default
        let modelName = VoiceImport.slug(name) + ".mlmodelc"
        let model = folder.appendingPathComponent(modelName)
        try fm.createDirectory(at: model.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try fm.createDirectory(at: model.appendingPathComponent("analytics"), withIntermediateDirectories: true)
        try Data(layout.text.utf8).write(to: model.appendingPathComponent("model.mil"))
        try layout.weights.write(to: model.appendingPathComponent("weights/weight.bin"))
        layout.weights = Data()
        try fm.copyItem(at: template.appendingPathComponent("coremldata.bin"), to: model.appendingPathComponent("coremldata.bin"))
        try analytics.write(to: model.appendingPathComponent("analytics/coremldata.bin"))
        try checkSound(model, rate: voice.rate, shown: shown)

        let manifest: [String: Any] = [
            "name": name, "version": 1,
            "realistic": ["model": modelName, "encoder": "contentvec_ahead.mlmodelc", "rate": voice.rate, "eqAmount": 0.5],
            "credits": "Converted from \(shown) with Pitch Shift's voice converter (RVC v2, \(voice.rate / 1000) kHz).",
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: folder.appendingPathComponent("voice.json"))
    }

    // Plays speech-like numbers through the new voice (as convert_voice.py's check_inputs): it must make sound.
    private static func checkSound(_ model: URL, rate: Int, shown: String) throws {
        let silent = Problem(message: "“\(shown)” makes no sound once it's turned into a Pitch Shift voice, so it wasn't added.")
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        guard let loaded = try? MLModel(contentsOf: model, configuration: config),
              let features = shape(of: "features", in: loaded), let pitch = shape(of: "pitch", in: loaded),
              let source = shape(of: "source", in: loaded), let noise = shape(of: "noise", in: loaded),
              let pick = shape(of: "pick", in: loaded) else { throw silent }
        var random = Noise()
        let windowFrames = pitch[1], picked = pick[0], rows = features[1], columns = features[2]
        let inputs: [String: MLMultiArray] = [
            "features": try array(features, .float32) { (out: UnsafeMutableBufferPointer<Float>) in
                for c in 0..<columns {
                    var value: Float = 0
                    for r in 0..<rows {
                        value += random.normal() * 0.05
                        out[r * columns + c] = value
                    }
                }
            },
            "pitch": try array(pitch, .int32) { (out: UnsafeMutableBufferPointer<Int32>) in out.update(repeating: 60) },
            "source": try array(source, .float32) { (out: UnsafeMutableBufferPointer<Float>) in
                for i in out.indices { out[i] = 0.1 * sin(Float(i) * 2 * .pi * 180 / Float(rate)) }
            },
            "noise": try array(noise, .float32) { (out: UnsafeMutableBufferPointer<Float>) in
                for i in out.indices { out[i] = random.normal() }
            },
            "pick": try array(pick, .int32) { (out: UnsafeMutableBufferPointer<Int32>) in
                for i in out.indices { out[i] = Int32(windowFrames - picked - 15 + i) }
            },
        ]
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: inputs),
              let audio = (try? loaded.prediction(from: provider))?.featureValue(for: "audio")?.multiArrayValue else { throw silent }
        var peak: Float = 0
        for i in 0..<audio.count {
            let value = audio[i].floatValue
            guard value.isFinite else { throw silent }
            peak = max(peak, abs(value))
        }
        guard peak >= 1e-5 else { throw silent }
    }

    private static func shape(of input: String, in model: MLModel) -> [Int]? {
        model.modelDescription.inputDescriptionsByName[input]?.multiArrayConstraint?.shape.map(\.intValue)
    }

    private static func array<T: MLShapedArrayScalar>(_ shape: [Int], _ type: MLMultiArrayDataType, fill: (UnsafeMutableBufferPointer<T>) -> Void) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
        array.withUnsafeMutableBufferPointer(ofType: T.self) { pointer, _ in fill(pointer) }
        return array
    }

    // The same numbers each time: a voice that passes once passes always.
    private struct Noise {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func uniform() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) + 0.5) / Float(1 << 24)
        }
        mutating func normal() -> Float { (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform()) }
    }
}

// The .pth's checks, as convert_voice.py's load_checkpoint: an RVC v2 voice with pitch, the app's speech reader, and a
// shape one of the templates fits.
private struct RVCVoice {
    let file: PthFile
    let tensors: [String: PthFile.Tensor]
    let rate: Int

    // Sizes that aren't in the weights, so a template can only fit if they match.
    private static let upsampling: [Int: (rates: [Int], kernels: [Int])] = [
        48000: ([12, 10, 2, 2], [24, 20, 4, 4]),
        40000: ([10, 10, 2, 2], [16, 16, 4, 4]),
        32000: ([10, 8, 2, 2], [20, 16, 4, 4]),
    ]

    init(_ url: URL, shown: String) throws {
        let terminal = "Turn it into a voice with the one line under “Your own voices” in Pitch Shift's README (github.com/Gromhogg/pitch-shift)."
        let notVoice = Problem(message: "“\(shown)” can't be read as an RVC voice. If you're sure it is one: \(terminal)")
        let unusual = Problem(message: "“\(shown)” has an unusual shape that Pitch Shift can't turn into a voice by itself. \(terminal)")
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 2_000_000_000 {
            throw Problem(message: "“\(shown)” is too big to be a voice.")
        }
        let file: PthFile
        do {
            file = try PthFile(url)
        } catch let refused as PthFile.Refused {
            if refused.why == .older {
                throw Problem(message: "“\(shown)” is an older kind of .pth file that Pitch Shift can't open by itself. \(terminal)")
            }
            throw notVoice
        }
        self.file = file
        guard case .dict(let top) = file.top else { throw notVoice }
        let info = file.dicts[top]
        guard let weights = info["weight"] ?? info["model"], case .dict(let index) = weights else {
            throw Problem(message: "“\(shown)” isn't an RVC voice (it has no voice inside).")
        }
        var tensors: [String: PthFile.Tensor] = [:]
        for (key, value) in file.dicts[index] {
            guard case .tensor(let tensor) = value else { throw notVoice }
            tensors[key] = tensor
        }
        self.tensors = tensors
        guard let phone = tensors["enc_p.emb_phone.weight"], tensors["emb_g.weight"] != nil, phone.shape.count == 2 else {
            throw Problem(message: "“\(shown)” isn't an RVC voice Pitch Shift knows.")
        }
        if Self.text(info["version"])?.lowercased() == "v1" || phone.shape[1] == 256 {
            throw Problem(message: "“\(shown)” is an RVC v1 voice. Pitch Shift needs RVC v2 voices (most voices made since mid-2023 are v2): look for a v2 version of it.")
        }
        guard phone.shape[1] == 768 else {
            throw Problem(message: "“\(shown)” has an unusual speech input (\(phone.shape[1]) values). Pitch Shift needs a standard RVC v2 voice.")
        }
        if ["0", "False"].contains(Self.text(info["f0"]) ?? "1") || tensors["enc_p.emb_pitch.weight"] == nil {
            throw Problem(message: "“\(shown)” was made without pitch (an RVC “no f0” voice). Pitch Shift needs a voice made with pitch.")
        }
        let vocoder = Self.text(info["vocoder"]) ?? "HiFi-GAN"
        guard ["HiFi-GAN", "hifigan", ""].contains(vocoder) else {
            throw Problem(message: "“\(shown)” uses the \(vocoder) sound maker. Pitch Shift only runs RVC's standard one (HiFi-GAN).")
        }
        let reader = (Self.text(info["embedder_model"]) ?? "contentvec").lowercased()
        guard ["contentvec", "hubert", "hubert_base", "custom", ""].contains(reader) else {
            throw Problem(message: "“\(shown)” was made with the \(reader) speech reader. Pitch Shift's reader is ContentVec (RVC's standard).")
        }

        var rate: Int?
        if let named = Self.text(info["sr"]) { rate = ["32k": 32000, "40k": 40000, "48k": 48000][named.lowercased()] ?? Int(named) }
        var config: [PthFile.Value] = []
        if case .list(let list)? = info["config"] { config = file.lists[list] }
        if config.count >= 18 {
            rate = rate ?? Self.number(config[17])
            let sizes = [2, 3, 4, 5, 6, 7, 16].map { Self.number(config[$0]) }
            guard sizes == [192, 192, 768, 2, 6, 3, 256], Self.text(config[9]) == "1" else {
                throw Problem(message: "“\(shown)” has an unusual model size. Pitch Shift needs a standard RVC v2 voice.")
            }
            let dilations: [[Int]?] = {
                guard case .list(let list) = config[11] else { return [] }
                return file.lists[list].map { file.ints($0) }
            }()
            guard let rate, let wanted = Self.upsampling[rate], file.ints(config[12]) == wanted.rates,
                  file.ints(config[14]) == wanted.kernels, Self.number(config[13]) == 512,
                  file.ints(config[10]) == [3, 7, 11], dilations == [[1, 3, 5], [1, 3, 5], [1, 3, 5]] else {
                if let rate, ![32000, 40000, 48000].contains(rate) {
                    throw Problem(message: "“\(shown)” was made at \(rate) Hz. Pitch Shift can use voices made at 32, 40 or 48 kHz.")
                }
                throw unusual
            }
        } else if rate == nil {  // a base model: its size tells the rate
            let first = tensors["dec.ups.0.weight_v"] ?? tensors["dec.ups.0.parametrizations.weight.original1"]
            rate = first?.shape.last.flatMap { [24: 48000, 20: 32000, 16: 40000][$0] }
        }
        guard let rate, Self.upsampling[rate] != nil else {
            throw Problem(message: "“\(shown)” was made at a rate Pitch Shift can't use. It can use voices made at 32, 40 or 48 kHz.")
        }
        self.rate = rate
    }

    private static func text(_ value: PthFile.Value?) -> String? {
        switch value {
        case .text(let text)?: return text
        case .int(let n)?: return String(n)
        case .bool(let on)?: return on ? "True" : "False"
        default: return nil
        }
    }

    private static func number(_ value: PthFile.Value) -> Int? {
        if case .int(let n) = value { return n }
        return nil
    }
}

// weight.bin: a 64-byte head, then for each stored tensor a 64-byte record and its numbers, each starting on a multiple of 64.
private struct BlobFile {
    enum Kind: UInt32 { case half = 1, byte = 4 }

    private(set) var bytes = Data(count: 64)
    private var count: UInt32 = 0

    mutating func add<T>(_ values: [T], _ kind: Kind) -> Int {
        let offset = bytes.count
        let size = values.count * MemoryLayout<T>.stride
        var record = Data(count: 64)
        record.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(0xDEAD_BEEF).littleEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: kind.rawValue.littleEndian, toByteOffset: 4, as: UInt32.self)
            raw.storeBytes(of: UInt64(size).littleEndian, toByteOffset: 8, as: UInt64.self)
            raw.storeBytes(of: UInt64(offset + 64).littleEndian, toByteOffset: 16, as: UInt64.self)
        }
        bytes.append(record)
        values.withUnsafeBytes { bytes.append(contentsOf: $0) }
        bytes.append(Data(count: (64 - size % 64) % 64))
        count += 1
        return offset
    }

    func finished() -> Data {
        var done = bytes
        done.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: count.littleEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(2).littleEndian, toByteOffset: 4, as: UInt32.self)
        }
        return done
    }
}

// Walks the template's model.mil, and for each place that takes numbers works them out from the voice and stores them.
private struct ModelWriter {
    private enum Source {
        case plain(PthFile.Tensor)
        case normed(length: PthFile.Tensor, direction: PthFile.Tensor)  // weight norm: length * direction / |direction|
    }

    private let voice: RVCVoice
    private let broken: Problem   // parts missing or the wrong size
    private let damaged: Problem  // numbers that can't be used
    private var sources: [String: Source] = [:]  // by the name model.mil gives each
    private var blobs = BlobFile()
    private var speakerOffsets: [String: [Float]] = [:]
    private var tables = 0  // position tables done
    private var lastWeight = ""

    init(_ voice: RVCVoice, shown: String) throws {
        self.voice = voice
        broken = Problem(message: "“\(shown)” has parts missing or the wrong size for an RVC v2 voice, so Pitch Shift can't use it.")
        damaged = Problem(message: "“\(shown)” has broken numbers in it, so Pitch Shift can't use it.")
        for (key, tensor) in voice.tensors {
            if key.hasPrefix("enc_q.") || key.hasPrefix("dec.m_source.l_sin_gen") || key == "emb_g.weight" { continue }
            if key.hasSuffix("weight_v") || key.hasSuffix("parametrizations.weight.original1") { continue }
            for (length, direction) in [("weight_g", "weight_v"), ("parametrizations.weight.original0", "parametrizations.weight.original1")]
            where key.hasSuffix(length) {
                let base = String(key.dropLast(length.count))
                guard let other = voice.tensors[base + direction] else { throw broken }
                sources[try Self.modelName(base + "weight")] = .normed(length: tensor, direction: other)
            }
            if !key.hasSuffix("weight_g"), !key.hasSuffix("parametrizations.weight.original0") {
                sources[try Self.modelName(key)] = .plain(tensor)
            }
        }
    }

    // "flow.flows.6.enc.pre.weight" -> "flows_3_enc_pre_weight" (the odd flows are flips, with no weights).
    private static func modelName(_ key: String) throws -> String {
        var name = key
        if name.hasPrefix("enc_p.encoder.") {
            name = "enc_p." + name.dropFirst("enc_p.encoder.".count)
        } else if name.hasPrefix("flow.flows.") {
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count > 3, let flow = Int(parts[2]), flow % 2 == 0 else {
                throw Problem(message: "This voice has an unusual flow layout, so Pitch Shift can't use it.")
            }
            name = "flows.\(flow / 2)." + parts[3...].joined(separator: ".")
        } else if name.hasPrefix("dec.m_source.l_linear.") {
            name = "dec.l_linear." + name.dropFirst("dec.m_source.l_linear.".count)
        }
        return name.replacingOccurrences(of: ".", with: "_")
    }

    mutating func fill(_ template: String) throws -> (text: String, weights: Data) {
        var out = ""
        out.reserveCapacity(template.utf8.count + 100_000)
        var staying: [String] = []
        for line in template.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.contains("BLOBFILE") else {
                out += line
                out += "\n"
                continue
            }
            guard let open = line.range(of: "["), let close = line.range(of: "]> "),
                  let space = line[close.upperBound...].firstIndex(of: " ") else { throw broken }
            let dims = line[open.upperBound..<close.lowerBound]
            let shape = dims.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let name = String(line[close.upperBound..<space])
            let quantizing = name.hasSuffix("_quantized")
            let numbers = try Self.half(try values(for: name, shape: shape), damaged)
            if quantizing, let quantized = try Self.quantized(numbers, shape, axis: Self.axis(in: line), damaged: damaged) {
                let data = blobs.add(quantized.data, .byte), zero = blobs.add(quantized.zeros, .byte), scale = blobs.add(quantized.scales, .half)
                let pieces = line.components(separatedBy: "(@)")
                guard pieces.count == 4 else { throw broken }
                out += "\(pieces[0])(\(data))\(pieces[1])(\(scale))\(pieces[2])(\(zero))\(pieces[3])\n"
            } else if quantizing {
                let plain = String(name.dropLast("_quantized".count))
                let at = blobs.add(numbers, .half)
                let indent = line[..<open.lowerBound].prefix { $0 == " " }
                out += "\(indent)tensor<fp16, [\(dims)]> \(plain) = const()[name = tensor<string, []>(\"\(plain)\"), val = tensor<fp16, [\(dims)]>"
                out += "(BLOBFILE(path = tensor<string, []>(\"@model_path/weights/weight.bin\"), offset = tensor<uint64, []>(\(at))))];\n"
                staying.append(plain)
            } else {
                let at = blobs.add(numbers, .half)
                out += line.replacingOccurrences(of: "(@)", with: "(\(at))") + "\n"
            }
        }
        out.removeLast()  // the template's last line ended in \n, so the split gave one empty line more
        for plain in staying { out = out.replacingOccurrences(of: plain + "_quantized", with: plain) }
        let weight = try take("dec_l_linear_weight", [1, 1]), bias = try take("dec_l_linear_bias", [1])
        out = out.replacingOccurrences(of: "@WEIGHT@", with: try Self.written(weight[0], damaged))
        out = out.replacingOccurrences(of: "@BIAS@", with: try Self.written(bias[0], damaged))
        guard sources.isEmpty else { throw broken }
        return (out, blobs.finished())
    }

    private static func axis(in line: Substring) -> Int { line.contains("axis = tensor<int32, []>(1)") ? 1 : 0 }

    // As model.mil writes a number.
    private static func written(_ value: Float, _ damaged: Problem) throws -> String {
        let number = Float16(value)
        guard number.isFinite else { throw damaged }
        return String(format: "%a", Double(number))
    }

    private static func half(_ values: [Float], _ damaged: Problem) throws -> [Float16] {
        var finite = true
        let numbers = values.map { value -> Float16 in
            let number = Float16(value)
            finite = finite && number.isFinite
            return number
        }
        guard finite else { throw damaged }
        return numbers
    }

    private mutating func values(for name: String, shape: [Int]) throws -> [Float] {
        if name.hasPrefix("g_") {
            var own = String(name.dropFirst(2))
            if own.hasSuffix("_quantized") { own.removeLast("_quantized".count) }
            guard own.hasSuffix("_to_fp16") else { throw broken }
            own.removeLast("_to_fp16".count)
            lastWeight = own.hasSuffix("_weight") ? String(own.dropLast("_weight".count)) : lastWeight
            return try take(own, shape)
        }
        if name.hasPrefix("var_") { return try positionTable(shape) }
        if name.hasPrefix("const_") { return try biasWithSpeaker(shape) }
        throw broken
    }

    // The numbers of one part of the voice, used once. Weight norm is folded into plain weights here.
    private mutating func take(_ name: String, _ shape: [Int]) throws -> [Float] {
        guard let source = sources.removeValue(forKey: name) else { throw broken }
        switch source {
        case .plain(let tensor):
            guard tensor.shape == shape, let values = voice.file.floats(tensor) else { throw broken }
            return values
        case .normed(let length, let direction):
            let rows = shape[0]
            guard direction.shape == shape, length.shape == [rows] + [Int](repeating: 1, count: shape.count - 1),
                  var values = voice.file.floats(direction), let lengths = voice.file.floats(length) else { throw broken }
            let columns = values.count / rows
            values.withUnsafeMutableBufferPointer { all in
                for row in 0..<rows {
                    let slice = UnsafeMutableBufferPointer(rebasing: all[(row * columns)..<((row + 1) * columns)])
                    let factor = lengths[row] / Self.norm(UnsafeBufferPointer(slice))
                    for i in slice.indices { slice[i] *= factor }
                }
            }
            return values
        }
    }

    // In the same order as PyTorch's norm (four running sums), so it rounds the same.
    private static func norm(_ values: UnsafeBufferPointer<Float>) -> Float {
        var sums = SIMD4<Float>(repeating: 0)
        var i = 0
        while i + 4 <= values.count {
            let four = SIMD4(values[i], values[i + 1], values[i + 2], values[i + 3])
            sums += four * four
            i += 4
        }
        var sum = sums[0] + sums[1] + sums[2] + sums[3]
        while i < values.count {
            sum += values[i] * values[i]
            i += 1
        }
        return sum.squareRoot()
    }

    // Every layer's relative position table, padded to the window (RVC's window of 10 frames each way), one kind turned on its side.
    private mutating func positionTable(_ shape: [Int]) throws -> [Float] {
        guard shape.count == 4 else { throw broken }
        let sideways = tables % 2 == 0, layer = tables / 2
        tables += 1
        let columns = sideways ? shape[2] : shape[3], rows = sideways ? shape[3] : shape[2], used = 21
        let table = try take("enc_p_attn_layers_\(layer)_emb_rel_\(sideways ? "k" : "v")", [1, used, columns])
        guard rows >= used else { throw broken }
        let pad = (rows - used) / 2
        var out = [Float](repeating: 0, count: rows * columns)
        for r in 0..<used {
            for c in 0..<columns {
                out[sideways ? c * rows + r + pad : (r + pad) * columns + c] = table[r * columns + c]
            }
        }
        return out
    }

    // The speaker is fixed, so its 1x1 layer is a constant, which coremltools adds to the bias of the layer before it.
    private mutating func biasWithSpeaker(_ shape: [Int]) throws -> [Float] {
        var bias = try take(lastWeight + "_bias", shape)
        let offset: [Float]
        if lastWeight == "dec_conv_pre" {
            offset = try speakerOffset("dec_cond")
        } else {
            let parts = lastWeight.split(separator: "_")
            guard parts.count == 6, parts[0] == "flows", let layer = Int(parts[5]) else { throw broken }
            let all = try speakerOffset("flows_\(parts[1])_enc_cond_layer")
            guard (layer + 1) * bias.count <= all.count else { throw broken }
            offset = Array(all[(layer * bias.count)..<((layer + 1) * bias.count)])
        }
        guard offset.count == bias.count else { throw broken }
        for i in bias.indices { bias[i] += offset[i] }
        return bias
    }

    private mutating func speakerOffset(_ layer: String) throws -> [Float] {
        if let done = speakerOffsets[layer] { return done }
        guard let embedding = voice.tensors["emb_g.weight"], embedding.shape.count == 2, embedding.shape[1] == 256,
              embedding.shape[0] > 0, let outputs = sources[layer + "_bias"].flatMap(Self.firstDimension), outputs > 0,
              let speaker = voice.file.floats(PthFile.Tensor(number: embedding.number, file: embedding.file, start: embedding.start, shape: [1, 256])) else {
            throw broken
        }
        let weight = try take(layer + "_weight", [outputs, 256, 1])
        var result = try take(layer + "_bias", [outputs])
        // Accelerate's own sum, as PyTorch uses for this layer. Its rounding depends on where the weights sit in memory,
        // so they go on a 64-byte boundary, as PyTorch keeps them.
        let aligned = UnsafeMutableRawBufferPointer.allocate(byteCount: weight.count * MemoryLayout<Float>.size, alignment: 64)
        defer { aligned.deallocate() }
        weight.withUnsafeBytes { aligned.copyMemory(from: $0) }
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(outputs), 1, 256, 1, aligned.bindMemory(to: Float.self).baseAddress,
                    256, speaker, 1, 1, &result, 1)
        speakerOffsets[layer] = result
        return result
    }

    private static func firstDimension(_ source: Source) -> Int? {
        if case .plain(let tensor) = source, tensor.shape.count == 1 { return tensor.shape[0] }
        return nil
    }

    // A weight's 8-bit form with a scale and zero point per channel, following coremltools' linear quantizer. numpy works
    // out every 16-bit sum in 32 bits and rounds it to 16, which is why every step here goes through Float.
    // nil: the weight has a nearly flat slice along some axis, so it stays 16-bit (convert_voice.py's quantize()).
    private static func quantized(_ values: [Float16], _ shape: [Int], axis: Int, damaged: Problem) throws -> (data: [Int8], zeros: [Int8], scales: [Float16])? {
        guard shape.count == 2 || shape.count == 3 else { throw damaged }
        let a = shape[0], b = shape[1], c = shape.count == 3 ? shape[2] : 1
        // The smallest and largest number of each slice along each axis, in one list: axis 0, then 1, then 2.
        var lows = [Float16](repeating: .infinity, count: a + b + c), highs = [Float16](repeating: -.infinity, count: a + b + c)
        lows.withUnsafeMutableBufferPointer { low in
            highs.withUnsafeMutableBufferPointer { high in
                var n = 0
                for i in 0..<a {
                    for j in a..<(a + b) {
                        for k in (a + b)..<(a + b + c) {
                            let x = values[n]
                            n += 1
                            for slice in [i, j, k] {
                                if x < low[slice] { low[slice] = x }
                                if x > high[slice] { high[slice] = x }
                            }
                        }
                    }
                }
            }
        }
        for slice in lows.indices where Float(highs[slice]) - Float(lows[slice]) < Float(3e-5) { return nil }
        var scales: [Float16] = [], zeros: [Float16] = []
        let first = axis == 0 ? 0 : a
        for channel in 0..<shape[axis] {
            let low = min(0, lows[first + channel]), high = max(0, highs[first + channel])
            let range = Float16(Float(high) - Float(low))
            let scale = Float16(Float(range) / 255)
            let top = Float16(-128 * Float(high)), bottom = Float16(127 * Float(low))
            let point = Float16(Float(Float16(Float(top) - Float(bottom))) / Float(range))
            guard scale.isFinite, scale > 0, point.isFinite else { throw damaged }
            scales.append(scale)
            zeros.append(max(-128, min(127, point.rounded(.toNearestOrEven))))
        }
        var data = [Int8](repeating: 0, count: values.count)
        values.withUnsafeBufferPointer { numbers in
            data.withUnsafeMutableBufferPointer { out in
                var n = 0
                for i in 0..<a {
                    for j in 0..<b {
                        let channel = axis == 0 ? i : j
                        let scale = Float(scales[channel]), zero = zeros[channel]
                        for _ in 0..<c {
                            let step = Float16(Float(numbers[n]) / scale).rounded(.toNearestOrEven)
                            out[n] = Int8(max(-128, min(127, step + zero)))
                            n += 1
                        }
                    }
                }
            }
        }
        return (data, zeros.map { Int8($0) }, scales)
    }
}
#else
enum VoiceConverter {
    static func convert(_ pth: URL, shown: String, name: String, into folder: URL) throws {
        throw Problem(message: "AI voices need a Mac with Apple silicon (M1 or newer), so “\(shown)” can't be added on this Mac.")
    }
}
#endif
