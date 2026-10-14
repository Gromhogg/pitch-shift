// "What you hear": grabs one app's sound (or all sound) with a macOS audio tap, which also mutes the original,
// changes the pitch with Rubber Band, and plays it to whatever speakers or headphones are picked in the Sound menu.
import AppKit
import AVFoundation
import CoreAudio

// Grabs the sound of some apps (or of every app but this one) and mutes the original.
final class Capture {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let description: CATapDescription
    private(set) var format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    init(_ description: CATapDescription, onSound: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.description = description
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else {
            throw Problem(message: "Could not grab the sound.")
        }
        // A private, hidden sound device that only holds the tap. Leaving the real speakers out of it keeps
        // headphone mics switched off (a Bluetooth mic turning on would drop the headphones into low-quality call mode).
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pitch Shift",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &device) == noErr else {
            stop()
            throw Problem(message: "Could not grab the sound.")
        }
        let streamFormat = getValue(device, kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeInput, default: AudioStreamBasicDescription())
        let format = AVAudioFormat(standardFormatWithSampleRate: streamFormat.mSampleRate > 0 ? streamFormat.mSampleRate : 48000, channels: 2)!
        self.format = format

        // Runs on Core Audio's sound thread: copy the sound into a left/right buffer and pass it on.
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, first.mNumberChannels > 0, first.mData != nil else { return }
            let frames = Int(first.mDataByteSize) / (Int(first.mNumberChannels) * MemoryLayout<Float>.size)
            guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
            copy.frameLength = AVAudioFrameCount(frames)
            var channel = 0
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let count = Int(buffer.mNumberChannels)
                for c in 0..<count where channel + c < 2 {
                    let dst = copy.floatChannelData![channel + c]
                    for i in 0..<frames { dst[i] = data[i * count + c] }
                }
                channel += count
            }
            if channel == 1 { memcpy(copy.floatChannelData![1], copy.floatChannelData![0], frames * MemoryLayout<Float>.size) }
            onSound(copy)
        }
        guard status == noErr, AudioDeviceStart(device, proc) == noErr else {
            stop()
            throw Problem(message: "Could not grab the sound.")
        }
    }

    // Changes which processes are grabbed without stopping (an app's helper processes come and go).
    func update(processes: [AudioObjectID]) -> Bool {
        description.processes = processes
        var addr = address(kAudioTapPropertyDescription)
        var value = description
        return AudioObjectSetPropertyData(tap, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), &value) == noErr
    }

    // Removing the tap also unmutes the original sound.
    func stop() {
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        proc = nil
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        device = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}

// Changes the pitch with Rubber Band and plays to one speaker or headphone device.
// Rubber Band's "R3" mode keeps bass and drums much better than Apple's built-in pitch shifter.
// A small cushion of sound sits before the speakers so it doesn't crackle. Only used on audioQueue.
final class Player {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let device: AudioDeviceID
    let format: AVAudioFormat
    private var shifter: RubberBandState?
    private var halfSteps: Float
    private let startFrames: AVAudioFrameCount
    private let maxFrames: AVAudioFrameCount
    private var queuedFrames: AVAudioFrameCount = 0
    private var playing = false
    private(set) var received: AVAudioFrameCount = 0
    private(set) var loudest: Float = 0
    private(set) var dropouts = 0  // times the cushion ran dry (a tiny gap)
    private(set) var skips = 0     // times sound was skipped to catch up

    init(device: AudioDeviceID, format: AVAudioFormat, halfSteps: Float) throws {
        self.device = device
        self.format = format
        self.halfSteps = halfSteps
        // Rubber Band hands back sound in pieces of at most ~16 ms, so a 50 ms cushion is enough; more is just delay.
        startFrames = AVAudioFrameCount(format.sampleRate * 0.05)
        maxFrames = AVAudioFrameCount(format.sampleRate * 0.15)
        let options = Int32(RubberBandOptionProcessRealTime.rawValue | RubberBandOptionEngineFiner.rawValue | RubberBandOptionChannelsTogether.rawValue)
        shifter = rubberband_new(UInt32(format.sampleRate), format.channelCount, options, 1, pow(2, Double(halfSteps) / 12))
        if let shifter { rubberband_set_max_process_size(shifter, 1024) }

        guard useDevice(engine.outputNode.audioUnit!, device) else { throw Problem(message: "Could not play to \(deviceName(device)).") }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
    }

    deinit {
        engine.stop()
        if let shifter { rubberband_delete(shifter) }
    }

    func stop() { engine.stop() }

    func setHalfSteps(_ value: Float) {
        if let shifter {
            if halfSteps == 0 && value != 0 { rubberband_reset(shifter) }  // clear out old sound
            rubberband_set_pitch_scale(shifter, pow(2, Double(value) / 12))
        }
        halfSteps = value
    }

    // At normal pitch the sound skips Rubber Band entirely.
    private func shift(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard halfSteps != 0, let shifter else { return buffer }
        let channels = Int(buffer.format.channelCount)
        var done = 0
        while done < Int(buffer.frameLength) {
            let count = min(1024, Int(buffer.frameLength) - done)
            let inputs: [UnsafePointer<Float>?] = (0..<channels).map { UnsafePointer(buffer.floatChannelData![$0] + done) }
            rubberband_process(shifter, inputs, UInt32(count), 0)
            done += count
        }
        let available = Int(rubberband_available(shifter))
        guard available > 0, let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(available)) else { return nil }
        let outputs: [UnsafeMutablePointer<Float>?] = (0..<channels).map { output.floatChannelData![$0] }
        output.frameLength = rubberband_retrieve(shifter, outputs, UInt32(available))
        return output
    }

    func play(_ buffer: AVAudioPCMBuffer) {
        received += buffer.frameLength
        for ch in 0..<Int(buffer.format.channelCount) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(buffer.frameLength) { loudest = max(loudest, abs(data[i])) }
        }
        guard let shifted = shift(buffer) else { return }
        let frames = shifted.frameLength
        if queuedFrames + frames > maxFrames { skips += 1; return }  // falling behind: skip a bit to catch up
        queuedFrames += frames
        node.scheduleBuffer(shifted) { [weak self] in
            audioQueue.async {
                guard let self else { return }
                self.queuedFrames -= frames
                if self.queuedFrames == 0 && self.playing { self.node.pause(); self.playing = false; self.dropouts += 1 }  // ran dry: refill cushion
            }
        }
        if !playing && queuedFrames >= startFrames { node.play(); playing = true }
    }

    var isPlaying: Bool { playing }

    // Where the delay comes from, in milliseconds: the cushion, Rubber Band, and the speakers or headphones.
    var timing: (cushion: Double, shifter: Double, device: Double) {
        let rate = format.sampleRate
        let shifterFrames = halfSteps != 0 && shifter != nil ? Double(rubberband_get_start_delay(shifter!)) : 0
        return (Double(queuedFrames) / rate * 1000, shifterFrames / rate * 1000, outputLatency(device) * 1000)
    }
}

// How long the speakers or headphones take to play sound we hand them (as macOS reports it; Bluetooth adds more).
func outputLatency(_ device: AudioDeviceID) -> Double {
    let scope = kAudioDevicePropertyScopeOutput
    let rate = nominalRate(device)
    guard rate > 0 else { return 0 }
    var frames = Double(getValue(device, kAudioDevicePropertyLatency, scope, default: UInt32(0)))
    frames += Double(getValue(device, kAudioDevicePropertySafetyOffset, scope, default: UInt32(0)))
    frames += Double(getValue(device, kAudioDevicePropertyBufferFrameSize, scope, default: UInt32(0)))
    if let stream = getArray(device, kAudioDevicePropertyStreams, scope, of: AudioStreamID.self).first {
        frames += Double(getValue(stream, kAudioStreamPropertyLatency, default: UInt32(0)))
    }
    return frames / rate
}

enum HearSource: Equatable {
    case all
    case app(String)  // bundle ID

    init(saved: String?) {
        switch saved {
        case nil, "", "music": self = .app("com.apple.Music")  // "music" was the setting in version 1
        case "all": self = .all
        case let bundleID?: self = .app(bundleID)
        }
    }

    var saved: String {
        if case .app(let bundleID) = self { return bundleID }
        return "all"
    }
}

enum HearState: Equatable {
    case off
    case waiting           // the chosen app isn't running or hasn't made sound yet
    case playing(String)   // name of the speakers or headphones
    case problem(String)
}

// Keeps a Capture and a Player going, and rebuilds them when the app opens or quits or the speakers change.
final class HearShifter {
    var halfSteps: Float {
        didSet { let value = halfSteps; audioQueue.async { self.player?.setHalfSteps(value) } }
    }
    var source: HearSource {
        didSet { if oldValue != source { restartCapture() } }
    }
    var onChange: () -> Void = {}
    var testPID: pid_t?
    private(set) var state: HearState = .off
    private var capture: Capture?
    private var capturedProcesses: [AudioObjectID] = []
    private var player: Player?  // only touched on audioQueue
    private var playerObserver: NSObjectProtocol?
    private var listeners: [Listener] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private let outputDebounce = Debouncer(0.3)
    private let processDebounce = Debouncer(0.2)
    private var running = false
    private var rebuilds: [Date] = []

    init(halfSteps: Float, source: HearSource) {
        self.halfSteps = halfSteps
        self.source = source
    }

    var isOn: Bool { running }

    func start() {
        guard !running else { return }
        running = true
        // Version 1 sent all sound to BlackHole. If it didn't close cleanly, put the sound back.
        if deviceName(defaultOutput()) == "BlackHole 2ch",
           let last = UserDefaults.standard.string(forKey: "lastSpeakers"),
           let speakers = allDevices().first(where: { deviceName($0) == last }) {
            setDefaultOutput(speakers)
        }
        listeners = [
            Listener(system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.outputChanged() },
            Listener(system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
                self?.processDebounce.call { self?.refreshCapture() }
            },
        ]
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.processDebounce.call { self?.refreshCapture() } }
        }
        restartCapture()
    }

    func stop() {
        guard running else { return }
        running = false
        listeners = []
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        stopCapture()
        setState(.off)
    }

    var report: String {
        audioQueue.sync {
            guard let player else { return "state=\(state), no player" }
            return "state=\(state), out=\(deviceName(player.device)) running=\(player.engine.isRunning), rate=\(Int(player.format.sampleRate)), " +
                "frames=\(player.received), loudest=\(player.loudest), playing=\(player.isPlaying), processes=\(capturedProcesses)"
        }
    }

    var timing: String {
        audioQueue.sync {
            guard let player else { return "no player" }
            let t = player.timing
            // Rubber Band's real delay is about 110 ms at 48 kHz (its "start delay" alone undercounts it).
            let shifter = player.timing.shifter > 0 ? 110.0 : 0
            return String(format: "cushion %.0f ms + shifter %.0f ms + %@ %.0f ms = %.0f ms  (dropouts %d, skips %d)", t.cushion, shifter, deviceName(player.device), t.device, t.cushion + shifter + t.device, player.dropouts, player.skips)
        }
    }

    private func setState(_ new: HearState) {
        guard new != state else { return }
        state = new
        onChange()
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
        capturedProcesses = []
        if let playerObserver { NotificationCenter.default.removeObserver(playerObserver) }
        playerObserver = nil
        audioQueue.sync { player?.stop(); player = nil }
    }

    private func restartCapture() {
        stopCapture()
        refreshCapture()
    }

    // Start grabbing sound when the chosen app is around, follow its helper processes, and stop when it quits.
    private func refreshCapture() {
        guard running else { return }
        let processes: [AudioObjectID]
        let everythingElse: Bool
        if let testPID {
            processes = audioProcess(for: testPID).map { [$0] } ?? []
            everythingElse = false
        } else {
            switch source {
            case .all:
                // Everything except this app's own sound (so our output isn't grabbed again).
                guard let me = audioProcess(for: getpid()) else { setState(.waiting); return }
                processes = [me]
                everythingElse = true
            case .app(let bundleID):
                processes = (Apps.scan().first { $0.bundleID == bundleID }?.processes ?? []).sorted()
                everythingElse = false
            }
        }
        if processes.isEmpty {
            stopCapture()
            setState(.waiting)
            return
        }
        if capture != nil {
            if processes == capturedProcesses { return }
            if !everythingElse, capture!.update(processes: processes) {
                capturedProcesses = processes
                return
            }
            stopCapture()
        }
        let description = everythingElse
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
            : CATapDescription(stereoMixdownOfProcesses: processes)
        do {
            capture = try Capture(description) { [weak self] buffer in
                audioQueue.async { self?.player?.play(buffer) }
            }
            capturedProcesses = processes
            rebuildPlayer()
        } catch {
            capture = nil
            setState(.problem((error as? Problem)?.message ?? "\(error)"))
        }
    }

    // The speakers or headphones changed (picked in the Sound menu, plugged in, connected, or disconnected).
    private func outputChanged() {
        guard running, capture != nil else { return }
        let device = defaultOutput()
        let needed = audioQueue.sync { player == nil || player!.device != device || !player!.engine.isRunning }
        guard needed else { return }
        // If something keeps changing, slow down instead of rebuilding over and over.
        rebuilds = rebuilds.filter { $0.timeIntervalSinceNow > -10 } + [Date()]
        if rebuilds.count > 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.rebuildPlayer() }
        } else {
            outputDebounce.call { [weak self] in self?.rebuildPlayer() }
        }
    }

    private func rebuildPlayer() {
        guard running, let format = capture?.format else { return }
        let device = defaultOutput()
        let steps = halfSteps
        if let playerObserver { NotificationCenter.default.removeObserver(playerObserver) }
        playerObserver = nil
        let result: Result<Player, Error> = audioQueue.sync {
            player?.stop()
            player = nil
            let made = Result { try Player(device: device, format: format, halfSteps: steps) }
            if case .success(let p) = made { player = p }
            return made
        }
        switch result {
        case .success(let player):
            playerObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: player.engine, queue: .main) { [weak self] _ in
                self?.outputChanged()
            }
            setState(.playing(deviceName(device)))
        case .failure:
            setState(.problem("Could not play to \(deviceName(device))."))
        }
    }
}
