// "Your voice": takes a microphone, changes its pitch with Rubber Band (its newer engine, in live mode), and sends it
// into "Pitch Shift Mic" (a virtual mic people pick in Discord, Zoom, ...). It only runs while some app is actually
// listening to Pitch Shift Mic, so the real mic (and Bluetooth call mode) is only on when needed.
import AppKit
import AVFoundation
import CoreAudio
import os

let virtualMicUID = "PitchShiftMic_UID"        // the mic people see
let virtualMicFeedUID = "PitchShiftMic_2_UID"  // its hidden other side, which the app writes into

struct MicInfo: Equatable {
    let uid: String
    let name: String
}

enum Mics {
    static var virtualMic: AudioDeviceID? { device(uid: virtualMicUID) }
    static var virtualFeed: AudioDeviceID? { device(uid: virtualMicFeedUID) }
    static var driverInstalled: Bool { virtualMic != nil && virtualFeed != nil }

    // Real microphones to choose from (no virtual devices like Pitch Shift Mic or BlackHole, and no combined devices).
    static func list() -> [MicInfo] {
        allDevices().filter { id in
            let transport = transportType(id)
            return streamCount(id, kAudioDevicePropertyScopeInput) > 0
                && transport != kAudioDeviceTransportTypeVirtual
                && transport != kAudioDeviceTransportTypeAggregate
        }.map { MicInfo(uid: deviceUID($0), name: deviceName($0)) }
    }

    // The saved mic if it's plugged in, else the Mac's default mic, else the built-in one.
    static func resolve(_ savedUID: String?) -> AudioDeviceID? {
        let choices = list()
        if let savedUID, choices.contains(where: { $0.uid == savedUID }), let id = device(uid: savedUID) { return id }
        // While Pitch Shift Mic is the Mac's default mic, the real one is the mic that was default before.
        let fallback = DefaultMic.realMic ?? defaultInput()
        if choices.contains(where: { $0.uid == deviceUID(fallback) }) { return fallback }
        return allDevices().first { transportType($0) == kAudioDeviceTransportTypeBuiltIn && streamCount($0, kAudioDevicePropertyScopeInput) > 0 }
    }
}

// Settings the sound thread reads. Changed from the window, read without waiting on the sound thread.
struct VoiceParams {
    var halfSteps: Float
    var cartoon: Float  // voice style: 0 = Natural, 1 = Cartoon, in between = a blend
    var silent: Bool    // during Test playback, so the replay isn't sent into a live call
}

// Rubber Band settings for the voice (the Windows version uses the same ones, with a Natural/Cartoon switch).
// Not the "live shifter" (rubberband_live_*): it only keeps the voice's shape (formants) up to about 10 kHz and
// moves everything above that up like Cartoon, which put a loud hiss on every word in Natural ("buzzy", like a Z).
// This keeps formants over the whole range, with about the same delay.
// Formants are always "preserved": Rubber Band only uses a formant scale (below) with that option on. The style
// slider then sets how far they move (see voiceFormantScale).
let voiceShifterOptions = Int32(RubberBandOptionProcessRealTime.rawValue | RubberBandOptionEngineFiner.rawValue
    | RubberBandOptionWindowShort.rawValue | RubberBandOptionPitchHighConsistency.rawValue | RubberBandOptionFormantPreserved.rawValue)

// How far the voice's shape (formants) moves for a style from 0 (Natural) to 1 (Cartoon). The formants end up
// moved by pitch^cartoon: not at all for Natural, as much as the pitch for Cartoon. Rubber Band counts the formant
// scale on top of the pitch change (checked in its source, R3Stretcher::adjustFormant), so it gets
// pitch^(cartoon - 1). At 0 it gets 0, its own "keep the formants" value (exactly the old Natural); at 1 it gets 1,
// which leaves the sound as the pitch change makes it (exactly the old Cartoon).
func voiceFormantScale(halfSteps: Float, cartoon: Float) -> Double {
    cartoon <= 0 ? 0 : pow(2, Double(halfSteps) / 12 * Double(min(cartoon, 1) - 1))
}

// The voice's Rubber Band shifter (used by the live chain and by the offline check --render-voice).
// A new style glides there over a short moment, so moving the slider never clicks.
final class VoiceStretcher {
    let state: RubberBandState
    private(set) var halfSteps: Float
    private var cartoon: Float      // the style asked for
    private var cartoonNow: Float   // the style in use (glides toward `cartoon`)
    private let glideStep: Float    // how much the style may move per sample

    init?(rate: Double, halfSteps: Float, cartoon: Float) {
        guard let made = rubberband_new(UInt32(rate), 1, voiceShifterOptions, 1, pow(2, Double(halfSteps) / 12)) else { return nil }
        state = made
        self.halfSteps = halfSteps
        self.cartoon = max(0, min(1, cartoon))
        cartoonNow = self.cartoon
        glideStep = Float(1 / (0.15 * rate))  // all the way from Natural to Cartoon in 0.15 s
        rubberband_set_max_process_size(state, 4096)
        rubberband_set_formant_scale(state, voiceFormantScale(halfSteps: halfSteps, cartoon: self.cartoon))
    }

    deinit { rubberband_delete(state) }

    // Returns true when the shifter started fresh (coming back from normal pitch), so old sound should be dropped.
    func set(halfSteps new: Float) -> Bool {
        guard new != halfSteps else { return false }
        let fresh = halfSteps == 0 && new != 0
        if fresh { rubberband_reset(state) }
        if new != 0 { rubberband_set_pitch_scale(state, pow(2, Double(new) / 12)) }
        halfSteps = new
        rubberband_set_formant_scale(state, voiceFormantScale(halfSteps: halfSteps, cartoon: cartoonNow))
        return fresh
    }

    func set(cartoon new: Float) { cartoon = max(0, min(1, new)) }

    // Moves the style toward where it's heading; call once for each piece of `frames` samples.
    func glide(_ frames: Int) {
        guard cartoonNow != cartoon else { return }
        let step = glideStep * Float(frames)
        cartoonNow = abs(cartoon - cartoonNow) <= step ? cartoon : cartoonNow + (cartoon > cartoonNow ? step : -step)
        rubberband_set_formant_scale(state, voiceFormantScale(halfSteps: halfSteps, cartoon: cartoonNow))
    }
}

// One running voice chain: a private combined device of [real mic + hidden side of Pitch Shift Mic] with one
// sound callback, so both run on the mic's clock (Core Audio corrects the tiny clock difference).
final class VoiceChain {
    let micName: String
    let micUID: String
    let devices: [AudioDeviceID]  // the mic and both sides of Pitch Shift Mic, as Core Audio numbered them
    let sampleRate: Double
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let stretcher: VoiceStretcher
    private var shifter: RubberBandState { stretcher.state }
    private let params: OSAllocatedUnfairLock<VoiceParams>
    private var applied: VoiceParams
    private let micOutputStreams: Int
    // Sound-thread buffers, made once up front (no memory is made on the sound thread).
    // Callbacks are small (128 samples), so Rubber Band gets them whole; pieces of up to 4096 only matter for a
    // device that insists on big callbacks, and the size of the pieces doesn't change the delay.
    private let maxPiece = 4096  // the most Rubber Band is given or asked for at once
    private let piece: UnsafeMutablePointer<Float>
    private let ring: VoiceRing  // shifted sound waiting to go out
    // For the command-line test: replaces the mic with a made-up sound.
    var testSource: ((UnsafeMutablePointer<Float>, Int) -> Void)?
    private(set) var firstInputTime: UInt64 = 0  // host time of the first mic sample (for the delay test)
    private(set) var blockInputTime: UInt64 = 0  // host time of the current callback's first mic sample (for the delay test)
    // Counts for --test-voice --watch, copied out after each callback without ever waiting on the sound thread.
    let stats = OSAllocatedUnfairLock(initialState: VoiceStats())
    private var counts = VoiceStats()
    private var overloadListener: Listener?

    init(mic: AudioDeviceID, feed: AudioDeviceID, params: OSAllocatedUnfairLock<VoiceParams>, bufferFrames: UInt32? = nil,
         testSource: ((UnsafeMutablePointer<Float>, Int) -> Void)? = nil) throws {
        self.testSource = testSource  // set before the sound starts, so a test never sends the real mic
        micName = deviceName(mic)
        micUID = deviceUID(mic)
        devices = [mic, Mics.virtualMic ?? 0, feed]
        let rate = nominalRate(mic)
        guard rate > 0 else { throw Problem(message: "Can't use \(micName).") }
        sampleRate = rate
        // Both sides of a combined device must run at the same rate; change Pitch Shift Mic, never the real mic.
        if nominalRate(feed) != rate {
            guard setNominalRate(feed, rate) else { throw Problem(message: "Pitch Shift Mic can't run at \(Int(rate)) Hz.") }
            for _ in 0..<20 where nominalRate(feed) != rate { Thread.sleep(forTimeInterval: 0.05) }
        }
        micOutputStreams = streamCount(mic, kAudioDevicePropertyScopeOutput)

        self.params = params
        let start = params.withLock { $0 }
        applied = start
        guard let made = VoiceStretcher(rate: rate, halfSteps: start.halfSteps, cartoon: start.cartoon) else {
            throw Problem(message: "Can't use \(micName).")
        }
        stretcher = made
        piece = .allocate(capacity: maxPiece)
        ring = VoiceRing(rate: rate)

        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pitch Shift Voice",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: micUID],
                [kAudioSubDeviceUIDKey: virtualMicFeedUID, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate) == noErr else {
            throw Problem(message: "Can't use \(micName).")  // deinit cleans up
        }
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { [unowned self] _, input, inputTime, output, _ in
            if self.firstInputTime == 0 { self.firstInputTime = inputTime.pointee.mHostTime }
            self.blockInputTime = inputTime.pointee.mHostTime
            self.render(input, output)
        }
        guard status == noErr, let proc else {
            throw Problem(message: "Can't use \(micName).")
        }
        turnOffMicOutputs(proc)
        // Small callbacks: the sound waits one callback on the way in and one on the way out, so 128 samples
        // (2.7 ms at 48 kHz) instead of the usual 512 (10.7 ms) cuts about 16 ms. Only this chain's own callbacks
        // change; other apps using the same mic keep theirs.
        var frames = bufferFrames ?? (rate > 48000 ? 256 : 128)
        let range = getValue(aggregate, kAudioDevicePropertyBufferFrameSizeRange, default: AudioValueRange(mMinimum: 0, mMaximum: 0))
        if range.mMaximum > 0 { frames = UInt32(min(max(Double(frames), range.mMinimum), range.mMaximum)) }
        var sizeAddress = address(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(aggregate, &sizeAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        overloadListener = Listener(aggregate, kAudioDeviceProcessorOverload) { [weak self] in
            self?.stats.withLock { $0.overloads += 1 }
        }
        guard AudioDeviceStart(aggregate, proc) == noErr else {
            throw Problem(message: "Can't use \(micName).")
        }
    }

    // Where the delay comes from (for --test-voice --watch), in milliseconds.
    var delayParts: String {
        let rate = sampleRate
        func ms(_ frames: UInt32) -> String { String(format: "%.1f", Double(frames) / rate * 1000) }
        func io(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String {
            let latency = getValue(id, kAudioDevicePropertyLatency, scope, default: UInt32(0))
            let safety = getValue(id, kAudioDevicePropertySafetyOffset, scope, default: UInt32(0))
            let buffer = getValue(id, kAudioDevicePropertyBufferFrameSize, scope, default: UInt32(0))
            let stream = getArray(id, kAudioDevicePropertyStreams, scope, of: AudioStreamID.self).first
                .map { getValue($0, kAudioStreamPropertyLatency, default: UInt32(0)) } ?? 0
            return "buffer \(buffer) (\(ms(buffer)) ms), latency \(ms(latency + stream)) ms, safety \(ms(safety)) ms"
        }
        let pad = rubberband_get_preferred_start_pad(shifter), start = rubberband_get_start_delay(shifter)
        return """
            combined device: in \(io(aggregate, kAudioDevicePropertyScopeInput)) | out \(io(aggregate, kAudioDevicePropertyScopeOutput))
              mic \(micName): \(io(devices[0], kAudioDevicePropertyScopeInput))
              hidden feed: \(io(devices[2], kAudioDevicePropertyScopeOutput)); Pitch Shift Mic: \(io(devices[1], kAudioDevicePropertyScopeInput))
              Rubber Band: start delay \(ms(start)) ms, start pad \(ms(pad)) ms, pieces up to \(maxPiece)
              waiting sound: starts at one callback + \(ms(UInt32(ring.startCushion))) ms, then kept \(ms(UInt32(ring.margin))) ms above the lowest point
            """
    }

    // Some mics (like USB headsets) also have speakers; tell Core Audio this chain doesn't use them.
    private func turnOffMicOutputs(_ proc: AudioDeviceIOProcID) {
        let total = streamCount(aggregate, kAudioDevicePropertyScopeOutput)
        guard micOutputStreams > 0, total > micOutputStreams else { return }
        let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + MemoryLayout<UInt32>.size * max(0, total - 1)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(total)
        let flags = (raw + MemoryLayout.offset(of: \AudioHardwareIOProcStreamUsage.mStreamIsOn)!).bindMemory(to: UInt32.self, capacity: total)
        for i in 0..<total { flags[i] = i < micOutputStreams ? 0 : 1 }
        var addr = address(kAudioDevicePropertyIOProcStreamUsage, kAudioDevicePropertyScopeOutput)
        AudioObjectSetPropertyData(aggregate, &addr, 0, nil, UInt32(size), raw)
    }

    // Runs on Core Audio's sound thread for every small piece of sound.
    private func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        if let latest = params.withLockIfAvailable({ $0 }) { apply(latest) }
        let outs = UnsafeMutableAudioBufferListPointer(output)
        guard outs.count > micOutputStreams else { return }
        let feed = outs[micOutputStreams]
        let feedChannels = Int(feed.mNumberChannels)
        guard feedChannels > 0 else { return }
        let frames = Int(feed.mDataByteSize) / (feedChannels * MemoryLayout<Float>.size)
        stretcher.glide(frames)
        for i in 0..<micOutputStreams { if let d = outs[i].mData { memset(d, 0, Int(outs[i].mDataByteSize)) } }

        // The mic, mixed to one channel (stereo mics are averaged; bigger audio interfaces use input 1).
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let source = inBlockScratch(frames)
        if let testSource {
            testSource(source, frames)
        } else if let first = ins.first, let data = first.mData?.assumingMemoryBound(to: Float.self), first.mNumberChannels > 0 {
            let ch = Int(first.mNumberChannels)
            let available = min(frames, Int(first.mDataByteSize) / (ch * MemoryLayout<Float>.size))
            let averaged = ch <= 2 ? ch : 1
            for i in 0..<available {
                var sum: Float = 0
                for c in 0..<averaged { sum += data[i * ch + c] }
                source[i] = sum / Float(averaged)
            }
            for i in available..<frames { source[i] = 0 }
        } else {
            for i in 0..<frames { source[i] = 0 }
        }

        // At normal pitch the mic goes straight out; otherwise the shifted sound replaces it in the same buffer.
        let shifting = applied.halfSteps != 0
        if shifting {
            shift(source, frames)
            ring.read(into: source, frames)
        }
        for i in 0..<frames {
            var value = applied.silent ? 0 : source[i]
            value = max(-1, min(1, value))
            for b in micOutputStreams..<outs.count {
                guard let d = outs[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let ch = Int(outs[b].mNumberChannels)
                for c in 0..<ch { d[i * ch + c] = value }
            }
        }
        publish(frames, shifting: shifting)
    }

    // Copies the counts out for --watch (never waits: if the main thread is reading, this callback is left out).
    private func publish(_ frames: Int, shifting: Bool) {
        counts.frames = frames
        counts.ring = ring.count
        counts.sending = shifting && !ring.waiting
        counts.delay = counts.sending
            ? counts.given - counts.returned + ring.count + Int(rubberband_get_start_delay(shifter)) - Int(rubberband_get_preferred_start_pad(shifter))
            : 0
        counts.margin = ring.margin
        counts.dryOuts = ring.dryOuts
        counts.trims = ring.trims
        counts.trimmed = ring.trimmed
        counts.replays = ring.replays
        counts.replayed = ring.replayed
        let now = counts
        stats.withLockIfAvailable { s in
            let overloads = s.overloads, lowest = s.lowest
            s = now
            s.overloads = overloads
            s.lowest = now.sending ? min(lowest, now.ring) : lowest
        }
    }

    // Gives one callback's sound to Rubber Band and moves everything it has ready into the ring.
    private func shift(_ source: UnsafeMutablePointer<Float>, _ frames: Int) {
        var done = 0
        while done < frames {
            let count = min(maxPiece, frames - done)
            var input: UnsafePointer<Float>? = UnsafePointer(source + done)
            rubberband_process(shifter, &input, UInt32(count), 0)
            done += count
        }
        counts.given += frames
        while true {
            let ready = min(Int(rubberband_available(shifter)), maxPiece)
            if ready <= 0 { break }
            var output: UnsafeMutablePointer<Float>? = piece
            let got = Int(rubberband_retrieve(shifter, &output, UInt32(ready)))
            if got <= 0 { break }
            counts.returned += got
            ring.write(piece, got)
        }
        ring.settle(frames)
    }

    // A scratch buffer for one callback's worth of mic sound (made once, grown only if Core Audio asks for more).
    private var scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    private var scratchSize = 8192
    private func inBlockScratch(_ frames: Int) -> UnsafeMutablePointer<Float> {
        if frames > scratchSize {  // only happens if the buffer size changes; rare
            scratch.deallocate()
            scratch = .allocate(capacity: frames)
            scratchSize = frames
        }
        return scratch
    }

    private func apply(_ latest: VoiceParams) {
        stretcher.set(cartoon: latest.cartoon)
        let changed = latest.halfSteps != stretcher.halfSteps
        if stretcher.set(halfSteps: latest.halfSteps) {  // coming back from normal pitch: start fresh
            counts.given = 0
            counts.returned = 0
            ring.reset()
        } else if changed && latest.halfSteps != 0 {
            ring.amountChanged()
        }
        applied = latest
    }

    func stop() {
        if let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        proc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
    }

    private func cleanUp() {
        piece.deallocate()
        scratch.deallocate()
    }

    private var stopped = false
    func close() {
        guard !stopped else { return }
        stopped = true
        stop()
        cleanUp()
    }

    deinit { close() }
}

// What the voice chain is doing (for --test-voice --watch). Sizes are in samples.
struct VoiceStats {
    var frames = 0           // samples per callback
    var ring = 0             // shifted sound waiting to go out, after the last callback
    var lowest = Int.max     // the least waiting since the watch last looked (reset by the reader)
    var sending = false      // shifted sound is going out (not filling up, not at normal pitch)
    var delay = 0            // Rubber Band + the ring, from a mic sample to it going out
    var given = 0            // samples given to Rubber Band
    var returned = 0         // samples Rubber Band gave back
    var margin = 0           // sound kept above the lowest point
    var dryOuts = 0          // the ring ran dry (a short gap, faded out and back in)
    var trims = 0            // extra waiting sound dropped (crossfaded) to cut the delay
    var trimmed = 0
    var replays = 0          // a few ms sent again (crossfaded) because the ring got very low
    var replayed = 0
    var overloads = 0        // Core Audio said a callback came too late
}

enum VoiceState: Equatable {
    case off
    case noDriver   // Pitch Shift Mic isn't installed
    case noMic      // no microphone found
    case ready      // on, waiting for an app to listen
    case live       // running
    case problem(String)
}

// Decides when the voice chain runs, which mic it uses, and rebuilds it when devices change.
final class VoiceShifter {
    var halfSteps: Float { didSet { pushParams() } }
    var cartoon: Float { didSet { pushParams() } }  // voice style: 0 = Natural, 1 = Cartoon
    var micUID: String? { didSet { if oldValue != micUID { rebuild() } } }  // nil = the Mac's default mic
    var onChange: () -> Void = {}
    var testSource: ((UnsafeMutablePointer<Float>, Int) -> Void)?
    var testBufferFrames: UInt32?  // --test-voice --buffer N: the callback size to ask for
    private(set) var state: VoiceState = .off
    private(set) var listening = false  // some app is using Pitch Shift Mic right now
    private(set) var chain: VoiceChain?
    let params: OSAllocatedUnfairLock<VoiceParams>
    private var running = false
    private var holdCount = 0
    private var listeners: [Listener] = []
    private var micListeners: [Listener] = []
    private var stopLater: DispatchWorkItem?
    private let debounce = Debouncer(0.3)
    private var rebuilds: [Date] = []

    init(halfSteps: Float, cartoon: Float, micUID: String?) {
        self.halfSteps = halfSteps
        self.cartoon = cartoon
        self.micUID = micUID
        params = OSAllocatedUnfairLock(initialState: VoiceParams(halfSteps: halfSteps, cartoon: cartoon, silent: false))
    }

    var isOn: Bool { running }
    var currentMic: AudioDeviceID? { Mics.resolve(micUID) }

    func start() {
        guard !running else { return }
        running = true
        listeners = [
            Listener(system, kAudioHardwarePropertyDevices) { [weak self] in self?.devicesChanged() },
            Listener(system, kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
                if self?.micUID == nil { self?.devicesChanged() }
            },
        ]
        watchVirtualMic()
        update()
    }

    func stop() {
        guard running else { return }
        running = false
        listeners = []
        micListeners = []
        stopLater?.cancel()
        closeChain()
        listening = false
        setState(.off)
    }

    // Keep the chain on while the Test button is recording (even if no app is listening).
    func hold(_ on: Bool) {
        holdCount = max(0, holdCount + (on ? 1 : -1))
        update()
    }

    func setSilent(_ silent: Bool) {
        params.withLock { $0.silent = silent }
    }

    private func pushParams() {
        let steps = halfSteps, cartoon = cartoon
        params.withLock { $0.halfSteps = steps; $0.cartoon = cartoon }
    }

    private func setState(_ new: VoiceState) {
        guard new != state else { onChange(); return }
        state = new
        onChange()
    }

    // Watches whether an app (Discord, Zoom, ...) is listening to Pitch Shift Mic, and its sample rate.
    private func watchVirtualMic() {
        micListeners = []
        guard let mic = Mics.virtualMic, let feed = Mics.virtualFeed else { return }
        micListeners = [
            Listener(mic, kAudioDevicePropertyDeviceIsRunningSomewhere) { [weak self] in self?.update() },
            Listener(feed, kAudioDevicePropertyNominalSampleRate) { [weak self] in self?.devicesChanged() },
        ]
        if let current = currentMic {
            micListeners.append(Listener(current, kAudioDevicePropertyNominalSampleRate) { [weak self] in self?.devicesChanged() })
        }
    }

    private func devicesChanged() {
        guard running else { return }
        rebuilds = rebuilds.filter { $0.timeIntervalSinceNow > -10 } + [Date()]
        let wait = rebuilds.count > 5 ? 3.0 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.debounce.call { self?.rebuild() }
        }
    }

    private func rebuild() {
        guard running else { return }
        if let chain, !needsNewChain(chain) { return }
        closeChain()
        watchVirtualMic()
        update()
    }

    // Making or closing our own private combined device also counts as "devices changed", so without this check
    // the chain restarted itself every few seconds (a short gap in the voice each time). Only start over when the
    // mic, Pitch Shift Mic, or a sample rate really changed.
    private func needsNewChain(_ chain: VoiceChain) -> Bool {
        guard let mic = currentMic, let virtualMic = Mics.virtualMic, let feed = Mics.virtualFeed,
              [mic, virtualMic, feed] == chain.devices, deviceUID(mic) == chain.micUID else { return true }
        return nominalRate(mic) != chain.sampleRate || nominalRate(feed) != chain.sampleRate
    }

    // Run the chain only when it's on, everything needed is there, and someone is listening (or Test is running).
    func update() {
        guard running else { return }
        guard Mics.driverInstalled, let virtualMic = Mics.virtualMic, let feed = Mics.virtualFeed else {
            closeChain()
            setState(.noDriver)
            return
        }
        listening = isRunningSomewhere(virtualMic)
        guard let mic = currentMic else {
            closeChain()
            setState(.noMic)
            return
        }
        if listening || holdCount > 0 || testSource != nil {
            stopLater?.cancel()
            stopLater = nil
            if chain == nil {
                do {
                    let made = try VoiceChain(mic: mic, feed: feed, params: params, bufferFrames: testBufferFrames, testSource: testSource)
                    chain = made
                } catch {
                    setState(.problem((error as? Problem)?.message ?? "\(error)"))
                    return
                }
            }
            setState(.live)
        } else {
            // Wait a moment before stopping: apps often stop and restart the mic right away.
            if chain != nil && stopLater == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.stopLater = nil
                    guard let self, !isRunningSomewhere(virtualMic), self.holdCount == 0 else { return }
                    self.closeChain()
                    self.setState(.ready)
                }
                stopLater = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            }
            if chain == nil { setState(.ready) } else { onChange() }
        }
    }

    private func closeChain() {
        chain?.close()
        chain = nil
    }
}

// Records sound from a device into memory (used by Test to record what Pitch Shift Mic sends).
final class Recorder {
    let sampleRate: Double
    private let device: AudioDeviceID
    private var proc: AudioDeviceIOProcID?
    private let samples: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var count = 0
    private(set) var firstInputTime: UInt64 = 0  // host time of the first recorded sample (for the delay test)

    init(device: AudioDeviceID, seconds: Double) throws {
        self.device = device
        sampleRate = nominalRate(device)
        capacity = Int(sampleRate * seconds)
        samples = .allocate(capacity: max(1, capacity))
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { [unowned self] _, input, inputTime, _, _ in
            if self.firstInputTime == 0 { self.firstInputTime = inputTime.pointee.mHostTime }
            guard let first = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).first,
                  let data = first.mData?.assumingMemoryBound(to: Float.self), first.mNumberChannels > 0 else { return }
            let ch = Int(first.mNumberChannels)
            let frames = Int(first.mDataByteSize) / (ch * MemoryLayout<Float>.size)
            for i in 0..<frames where self.count < self.capacity {
                self.samples[self.count] = data[i * ch]
                self.count += 1
            }
        }
        guard status == noErr, let proc, AudioDeviceStart(device, proc) == noErr else {
            throw Problem(message: "Can't record.")  // deinit cleans up
        }
    }

    // What has been recorded so far, from `start` on (for --test-voice --watch; may lag a callback behind).
    func recorded(from start: Int) -> [Float] {
        let end = count
        return start < end ? Array(UnsafeBufferPointer(start: samples + start, count: end - start)) : []
    }

    // Stops and returns what was recorded (one channel).
    func finish() -> [Float] {
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        proc = nil
        return Array(UnsafeBufferPointer(start: samples, count: count))
    }

    deinit {
        if proc != nil { _ = finish() }
        samples.deallocate()
    }
}

// The Test button: record 5 seconds of what Pitch Shift Mic sends, then play it back.
final class VoiceTest {
    enum Phase: Equatable { case idle, recording(Int), playing }
    private(set) var phase: Phase = .idle
    var onChange: () -> Void = {}
    private let voice: VoiceShifter
    private var recorder: Recorder?
    private var countdown: DispatchWorkItem?
    private var engine: AVAudioEngine?
    private let seconds = 5

    init(voice: VoiceShifter) { self.voice = voice }

    func click() {
        switch phase {
        case .idle: startRecording()
        case .recording: finishRecording()
        case .playing: finishPlaying()
        }
    }

    private func setPhase(_ new: Phase) {
        phase = new
        onChange()
    }

    private func startRecording() {
        guard let mic = Mics.virtualMic else { NSSound.beep(); return }
        voice.hold(true)
        do {
            recorder = try Recorder(device: mic, seconds: Double(seconds))
        } catch {
            voice.hold(false)
            NSSound.beep()
            return
        }
        tick(seconds)
    }

    // Counts down once a second while recording.
    private func tick(_ left: Int) {
        guard left > 0 else { finishRecording(); return }
        setPhase(.recording(left))
        let work = DispatchWorkItem { [weak self] in self?.tick(left - 1) }
        countdown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func finishRecording() {
        countdown?.cancel()
        countdown = nil
        guard let recorder else { return }
        let samples = recorder.finish()
        let rate = recorder.sampleRate
        self.recorder = nil
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0.001, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            voice.hold(false)
            NSSound.beep()  // nothing came through
            setPhase(.idle)
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { memcpy(buffer.floatChannelData![0], $0.baseAddress!, samples.count * MemoryLayout<Float>.size) }

        voice.setSilent(true)  // don't send the replay into a live call
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch {
            voice.setSilent(false)
            voice.hold(false)
            setPhase(.idle)
            return
        }
        self.engine = engine
        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async { self?.finishPlaying() }
        }
        player.play()
        setPhase(.playing)
    }

    private func finishPlaying() {
        guard phase == .playing else { return }
        engine?.stop()
        engine = nil
        voice.setSilent(false)
        voice.hold(false)
        setPhase(.idle)
    }
}

// Offline check (--render-voice): shifts a sound file with the voice's own Rubber Band settings, in 512-sample
// pieces like the live chain, and writes one channel. `changes` moves the style part way through
// ((seconds, style) pairs), to check that it changes smoothly.
func renderVoiceFile(input: String, output: String, halfSteps: Float, cartoon: Float, changes: [(Double, Float)]) throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: input))
    let rate = file.processingFormat.sampleRate
    let length = Int(file.length)
    guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(length)) else {
        throw Problem(message: "Could not read \(input).")
    }
    try file.read(into: source)
    // One channel, like the live chain (two channels are averaged, more use the first).
    let channels = Int(file.processingFormat.channelCount)
    let used = channels <= 2 ? channels : 1
    var mono = [Float](repeating: 0, count: length)
    for c in 0..<used {
        let data = source.floatChannelData![c]
        for i in 0..<length { mono[i] += data[i] / Float(used) }
    }
    var result = mono
    if halfSteps != 0 {
        guard let stretcher = VoiceStretcher(rate: rate, halfSteps: halfSteps, cartoon: cartoon) else {
            throw Problem(message: "Could not start Rubber Band.")
        }
        let block = 512
        var skip = Int(rubberband_get_start_delay(stretcher.state))  // so the output lines up with the input
        var chunk = [Float](repeating: 0, count: block)
        var piece = [Float](repeating: 0, count: 4096)
        result = []
        result.reserveCapacity(length)
        var position = 0
        while result.count < length && position < length + Int(rate) {
            if let change = changes.last(where: { Int($0.0 * rate) <= position }) { stretcher.set(cartoon: change.1) }
            stretcher.glide(block)
            for i in 0..<block { chunk[i] = position + i < length ? mono[position + i] : 0 }
            chunk.withUnsafeBufferPointer { p in
                var pointer: UnsafePointer<Float>? = p.baseAddress
                rubberband_process(stretcher.state, &pointer, UInt32(block), 0)
            }
            position += block
            while rubberband_available(stretcher.state) > 0 {
                let want = min(Int(rubberband_available(stretcher.state)), piece.count)
                let got = piece.withUnsafeMutableBufferPointer { p in
                    var pointer: UnsafeMutablePointer<Float>? = p.baseAddress
                    return Int(rubberband_retrieve(stretcher.state, &pointer, UInt32(want)))
                }
                if got <= 0 { break }
                let drop = min(skip, got)
                skip -= drop
                result.append(contentsOf: piece[drop..<got])
            }
        }
        if result.count > length { result.removeLast(result.count - length) }
    }
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, result.count))) else {
        throw Problem(message: "Could not write \(output).")
    }
    buffer.frameLength = AVAudioFrameCount(result.count)
    _ = result.withUnsafeBufferPointer { memcpy(buffer.floatChannelData![0], $0.baseAddress!, result.count * MemoryLayout<Float>.size) }
    let out = try AVAudioFile(forWriting: URL(fileURLWithPath: output), settings: format.settings)
    try out.write(from: buffer)
}
