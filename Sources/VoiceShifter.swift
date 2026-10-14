// "Your voice": takes a microphone, changes its pitch with Rubber Band's low-delay live shifter, and sends it into
// "Pitch Shift Mic" (a virtual mic people pick in Discord, Zoom, ...). It only runs while some app is actually
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
    var natural: Bool
    var silent: Bool  // during Test playback, so the replay isn't sent into a live call
}

// One running voice chain: a private combined device of [real mic + hidden side of Pitch Shift Mic] with one
// sound callback, so both run on the mic's clock (Core Audio corrects the tiny clock difference).
final class VoiceChain {
    let micName: String
    let sampleRate: Double
    let blockSize: Int
    let startDelay: Int
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let shifter: RubberBandLiveState
    private let params: OSAllocatedUnfairLock<VoiceParams>
    private var applied: VoiceParams
    private let micOutputStreams: Int
    // Sound-thread buffers, made once up front (no memory is made on the sound thread).
    private let inBlock: UnsafeMutablePointer<Float>
    private let outBlock: UnsafeMutablePointer<Float>
    private var inCount = 0
    private let ring: UnsafeMutablePointer<Float>
    private let ringSize: Int
    private var ringRead = 0
    private var ringCount = 0
    // For the command-line test: replaces the mic with a made-up sound.
    var testSource: ((UnsafeMutablePointer<Float>, Int) -> Void)?

    init(mic: AudioDeviceID, feed: AudioDeviceID, params: OSAllocatedUnfairLock<VoiceParams>) throws {
        micName = deviceName(mic)
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
        let formant = start.natural ? RubberBandLiveOptionFormantPreserved.rawValue : RubberBandLiveOptionFormantShifted.rawValue
        shifter = rubberband_live_new(UInt32(rate), 1, Int32(RubberBandLiveOptionWindowShort.rawValue | formant))
        rubberband_live_set_pitch_scale(shifter, pow(2, Double(start.halfSteps) / 12))
        blockSize = Int(rubberband_live_get_block_size(shifter))
        startDelay = Int(rubberband_live_get_start_delay(shifter))
        inBlock = .allocate(capacity: blockSize)
        outBlock = .allocate(capacity: blockSize)
        ringSize = blockSize * 8 + 16384
        ring = .allocate(capacity: ringSize)
        ring.initialize(repeating: 0, count: ringSize)
        ringCount = blockSize  // start one block "ahead" so the output never runs dry

        let micUID = deviceUID(mic)
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
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { [unowned self] _, input, _, output, _ in
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

        for i in 0..<frames {
            var value: Float
            if applied.halfSteps == 0 {
                value = source[i]
            } else {
                inBlock[inCount] = source[i]
                inCount += 1
                if inCount == blockSize {
                    var inPointer: UnsafePointer<Float>? = UnsafePointer(inBlock)
                    var outPointer: UnsafeMutablePointer<Float>? = outBlock
                    rubberband_live_shift(shifter, &inPointer, &outPointer)
                    for j in 0..<blockSize where ringCount < ringSize {
                        ring[(ringRead + ringCount) % ringSize] = outBlock[j]
                        ringCount += 1
                    }
                    inCount = 0
                }
                if ringCount > 0 {
                    value = ring[ringRead]
                    ringRead = (ringRead + 1) % ringSize
                    ringCount -= 1
                } else {
                    value = 0
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
        if latest.natural != applied.natural {
            let formant = latest.natural ? RubberBandLiveOptionFormantPreserved.rawValue : RubberBandLiveOptionFormantShifted.rawValue
            rubberband_live_set_formant_option(shifter, Int32(formant))
        }
        if latest.halfSteps != applied.halfSteps && latest.halfSteps != 0 {
            if applied.halfSteps == 0 {  // coming back from normal pitch: start fresh
                rubberband_live_reset(shifter)
                inCount = 0
                ringRead = 0
                for j in 0..<blockSize { ring[j] = 0 }
                ringCount = blockSize
            }
            rubberband_live_set_pitch_scale(shifter, pow(2, Double(latest.halfSteps) / 12))
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
        rubberband_live_delete(shifter)
        inBlock.deallocate()
        outBlock.deallocate()
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
    var natural: Bool { didSet { pushParams() } }
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

    init(halfSteps: Float, natural: Bool, micUID: String?) {
        self.halfSteps = halfSteps
        self.natural = natural
        self.micUID = micUID
        params = OSAllocatedUnfairLock(initialState: VoiceParams(halfSteps: halfSteps, natural: natural, silent: false))
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
        let steps = halfSteps, natural = natural
        params.withLock { $0.halfSteps = steps; $0.natural = natural }
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
        closeChain()
        watchVirtualMic()
        update()
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

    init(device: AudioDeviceID, seconds: Double) throws {
        self.device = device
        sampleRate = nominalRate(device)
        capacity = Int(sampleRate * seconds)
        samples = .allocate(capacity: max(1, capacity))
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { [unowned self] _, input, _, _, _ in
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
