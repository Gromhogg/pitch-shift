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
    static func resolve(_ savedUID: String?) -> AudioDeviceID? { choose(savedUID).mic }

    // Like resolve, and also says which mic was passed over (for --list). With no saved mic, the mic of Bluetooth
    // headphones that are also playing the Mac's sound is passed over for the built-in mic: opening it switches the
    // headphones into call mode, where everything they play sounds thin and hollow. A mic picked on purpose is kept.
    static func choose(_ savedUID: String?) -> (mic: AudioDeviceID?, skipped: AudioDeviceID?) {
        let choices = list()
        if let savedUID, choices.contains(where: { $0.uid == savedUID }), let id = device(uid: savedUID) { return (id, nil) }
        // While Pitch Shift Mic is the Mac's default mic, the real one is the mic that was default before.
        let fallback = DefaultMic.realMic ?? defaultInput()
        guard choices.contains(where: { $0.uid == deviceUID(fallback) }) else { return (builtIn, nil) }
        if let builtIn, isHeadsetMic(fallback, of: defaultOutput()) { return (builtIn, fallback) }
        return (fallback, nil)
    }

    static var builtIn: AudioDeviceID? {
        allDevices().first { transportType($0) == kAudioDeviceTransportTypeBuiltIn && streamCount($0, kAudioDevicePropertyScopeInput) > 0 }
    }

    // True when `mic` belongs to the same Bluetooth headphones as `output` (macOS shows them as two devices with
    // the same address, like "AC-80-0A-E9-3A-03:input" and "AC-80-0A-E9-3A-03:output", and the same name).
    static func isHeadsetMic(_ mic: AudioDeviceID, of output: AudioDeviceID) -> Bool {
        let bluetooth = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE]
        guard mic != 0, output != 0, bluetooth.contains(transportType(mic)), bluetooth.contains(transportType(output)) else { return false }
        func address(_ uid: String) -> String { String(uid.split(separator: ":").first ?? "") }
        let micAddress = address(deviceUID(mic))
        return mic == output || (!micAddress.isEmpty && micAddress == address(deviceUID(output))) || deviceName(mic) == deviceName(output)
    }

    // The mic of the Bluetooth headphones `output`, if they have one (for --watch-output).
    static func headsetMic(of output: AudioDeviceID) -> AudioDeviceID? {
        allDevices().first { streamCount($0, kAudioDevicePropertyScopeInput) > 0 && isHeadsetMic($0, of: output) }
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
    let cushion: Int  // sound kept ready beyond what one callback needs (Rubber Band hands it back in uneven pieces)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let stretcher: VoiceStretcher
    private var shifter: RubberBandState { stretcher.state }
    private let params: OSAllocatedUnfairLock<VoiceParams>
    private var applied: VoiceParams
    private let micOutputStreams: Int
    // Sound-thread buffers, made once up front (no memory is made on the sound thread).
    private let maxPiece = 4096  // the most Rubber Band is given or asked for at once
    private let piece: UnsafeMutablePointer<Float>
    private let ring: UnsafeMutablePointer<Float>
    private let ringSize: Int
    private var ringRead = 0
    private var ringCount = 0
    private var waiting = true      // filling the cushion before sound goes out
    private var fresh = true        // just started: the first wait may overshoot, so trim it
    private var lowest = Int.max    // least spare sound in the ring since the last check
    private var sinceCheck = 0
    private let checkEvery: Int
    private let extraAllowed: Int
    // For the command-line test: replaces the mic with a made-up sound.
    var testSource: ((UnsafeMutablePointer<Float>, Int) -> Void)?
    private(set) var firstInputTime: UInt64 = 0  // host time of the first mic sample (for the delay test)

    init(mic: AudioDeviceID, feed: AudioDeviceID, params: OSAllocatedUnfairLock<VoiceParams>) throws {
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
        // 20 ms is enough at every amount and callback size tried (16-96 kHz); more would only add delay.
        cushion = Int(rate * 0.02)
        extraAllowed = Int(rate * 0.005)
        checkEvery = Int(rate * 0.5)
        piece = .allocate(capacity: maxPiece)
        ringSize = Int(rate) + maxPiece  // about a second; it never gets close to full
        ring = .allocate(capacity: ringSize)
        ring.initialize(repeating: 0, count: ringSize)

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
            self.render(input, output)
        }
        guard status == noErr, let proc else {
            throw Problem(message: "Can't use \(micName).")
        }
        turnOffMicOutputs(proc)
        guard AudioDeviceStart(aggregate, proc) == noErr else {
            throw Problem(message: "Can't use \(micName).")
        }
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

        let shifting = applied.halfSteps != 0
        if shifting { shift(source, frames) }
        for i in 0..<frames {
            var value: Float = 0
            if !shifting {
                value = source[i]
            } else if !waiting {
                if ringCount > 0 {
                    value = ring[ringRead]
                    ringRead = (ringRead + 1) % ringSize
                    ringCount -= 1
                } else {
                    waiting = true  // ran dry (only right after a big amount change): build the cushion again
                }
            }
            if applied.silent { value = 0 }
            value = max(-1, min(1, value))
            for b in micOutputStreams..<outs.count {
                guard let d = outs[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let ch = Int(outs[b].mNumberChannels)
                for c in 0..<ch { d[i * ch + c] = value }
            }
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
        while true {
            let ready = min(Int(rubberband_available(shifter)), maxPiece)
            if ready <= 0 { break }
            var output: UnsafeMutablePointer<Float>? = piece
            let got = Int(rubberband_retrieve(shifter, &output, UInt32(ready)))
            for j in 0..<got where ringCount < ringSize {
                ring[(ringRead + ringCount) % ringSize] = piece[j]
                ringCount += 1
            }
        }
        // Sound goes out once the ring holds this callback's worth plus the cushion.
        if waiting && ringCount >= cushion + frames {
            waiting = false
            if fresh { skip(ringCount - cushion - frames) }  // the first piece can overshoot: don't keep that as delay
            fresh = false
            lowest = .max
            sinceCheck = 0
        }
        // Twice a second: if the ring never got below the cushion (after the amount went up), skip the extra delay.
        if !waiting { lowest = min(lowest, ringCount - frames) }
        sinceCheck += frames
        if sinceCheck >= checkEvery {
            if !waiting && lowest != .max && lowest > cushion + extraAllowed { skip(lowest - cushion) }
            lowest = .max
            sinceCheck = 0
        }
    }

    private func skip(_ count: Int) {
        let n = max(0, min(count, ringCount))
        ringRead = (ringRead + n) % ringSize
        ringCount -= n
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
        if stretcher.set(halfSteps: latest.halfSteps) {  // coming back from normal pitch: start fresh
            ringRead = 0
            ringCount = 0
            waiting = true
            fresh = true
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
        ring.deallocate()
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
        // With no mic picked, the mic follows the Mac's default mic, and the headphones in use (see Mics.choose).
        listeners = [
            Listener(system, kAudioHardwarePropertyDevices) { [weak self] in self?.devicesChanged() },
            Listener(system, kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
                if self?.micUID == nil { self?.devicesChanged() }
            },
            Listener(system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
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

    // Keep the chain on while the Test button is recording (even if no app is listening). When Test is done and no
    // app is listening, the mic is closed right away.
    func hold(_ on: Bool) {
        holdCount = max(0, holdCount + (on ? 1 : -1))
        update(closeNow: !on)
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
    // Otherwise the real mic is closed, so Bluetooth headphones go back to full quality.
    func update(closeNow: Bool = false) {
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
        if listening || holdCount > 0 {
            stopLater?.cancel()
            stopLater = nil
            if chain == nil {
                do {
                    let made = try VoiceChain(mic: mic, feed: feed, params: params)
                    made.testSource = testSource
                    chain = made
                } catch {
                    setState(.problem((error as? Problem)?.message ?? "\(error)"))
                    return
                }
            }
            setState(.live)
        } else {
            if closeNow {
                stopLater?.cancel()
                stopLater = nil
                closeChain()
            }
            // Wait a moment before stopping: apps often stop and restart the mic right away.
            if chain != nil && stopLater == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.stopLater = nil
                    guard let self, !isRunningSomewhere(virtualMic), self.holdCount == 0 else { return }
                    self.closeChain()
                    self.setState(.ready)
                }
                stopLater = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
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
