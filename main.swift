// Pitch Shift: plays the Music app (or all Mac sound) at a higher or lower pitch, live.
// It grabs the sound straight from the app with a macOS "audio tap" (which also mutes the original),
// changes the pitch with Rubber Band, and plays it to whatever speakers or headphones are picked in the Sound menu.
// It never changes the Mac's sound settings, so the volume keys, headphone switching and calls work like normal.
// Check it from Terminal: "Pitch Shift.app/Contents/MacOS/PitchShift --test [--pid N] [--all] [--steps 2.5]" runs for a few
// seconds and prints what happened.
import AppKit
import AVFoundation
import CoreAudio

let system = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func allDevices() -> [AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids)
    return ids
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = address(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let name else { return "" }
    return name.takeRetainedValue() as String
}

func defaultOutput() -> AudioDeviceID {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
    return id
}

func setDefaultOutput(_ id: AudioDeviceID) {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var id = id
    AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
}

func useDevice(_ unit: AudioUnit, _ id: AudioDeviceID) -> Bool {
    var id = id
    return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
}

// The Core Audio id for a running app's sound, or nil if the app hasn't used sound yet.
func audioProcess(for pid: pid_t) -> AudioObjectID? {
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pid = pid
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &id)
    return err == noErr && id != kAudioObjectUnknown ? id : nil
}

// Runs `handler` on the main queue whenever a Core Audio setting changes.
func watch(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
    var addr = address(selector)
    AudioObjectAddPropertyListenerBlock(object, &addr, .main) { _, _ in handler() }
}

struct Problem: Error { let message: String }

// All sound handling after the grab happens on this one queue.
let audioQueue = DispatchQueue(label: "pitch-shift")

// Grabs the sound of one app (or of every app but this one) and mutes the original.
final class Capture {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private(set) var format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    init(_ description: CATapDescription, onSound: @escaping (AVAudioPCMBuffer) -> Void) throws {
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
        var streamFormat = AudioStreamBasicDescription()
        var addr = address(kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeInput)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streamFormat)
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

    init(device: AudioDeviceID, format: AVAudioFormat, halfSteps: Float) throws {
        self.device = device
        self.format = format
        self.halfSteps = halfSteps
        startFrames = AVAudioFrameCount(format.sampleRate * 0.15)
        maxFrames = AVAudioFrameCount(format.sampleRate * 0.5)
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
        if queuedFrames + frames > maxFrames { return }  // falling behind: skip a bit to catch up
        queuedFrames += frames
        node.scheduleBuffer(shifted) { [weak self] in
            audioQueue.async {
                guard let self else { return }
                self.queuedFrames -= frames
                if self.queuedFrames == 0 && self.playing { self.node.pause(); self.playing = false }  // ran dry: refill cushion
            }
        }
        if !playing && queuedFrames >= startFrames { node.play(); playing = true }
    }

    var isPlaying: Bool { playing }
}

enum Source: String { case music, all }

let halfStepsKey = "halfSteps"
let sourceKey = "source"
let lastSpeakersKey = "lastSpeakers"

// Keeps a Capture and a Player going, and rebuilds them when Music opens or quits or the speakers change.
final class Shifter {
    var halfSteps: Float {
        didSet { let value = halfSteps; audioQueue.async { self.player?.setHalfSteps(value) } }
    }
    var source: Source {
        didSet { if oldValue != source { restartCapture() } }
    }
    var onChange: () -> Void = {}
    var testPID: pid_t?
    private(set) var status = "Starting..."
    private var capture: Capture?
    private var capturedPID: pid_t?
    private var player: Player?  // only touched on audioQueue
    private var running = false
    private var rebuildPending = false
    private var rebuilds: [Date] = []

    init(halfSteps: Float, source: Source) {
        self.halfSteps = halfSteps
        self.source = source
    }

    func start() {
        running = true
        // The first version of this app sent all sound to BlackHole. If it didn't close cleanly, put the sound back.
        if deviceName(defaultOutput()) == "BlackHole 2ch",
           let last = UserDefaults.standard.string(forKey: lastSpeakersKey),
           let speakers = allDevices().first(where: { deviceName($0) == last }) {
            setDefaultOutput(speakers)
        }
        watch(system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.outputChanged() }
        watch(system, kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.refreshCapture() }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            self?.outputChanged()
        }
        restartCapture()
    }

    func stop() {
        running = false
        capture?.stop()
        capture = nil
        audioQueue.sync { player?.stop(); player = nil }
    }

    var report: String {
        audioQueue.sync {
            guard let player else { return "status=\(status), no player" }
            return "status=\(status), out=\(deviceName(player.device)) running=\(player.engine.isRunning), rate=\(Int(player.format.sampleRate)), " +
                "frames=\(player.received), loudest=\(player.loudest), playing=\(player.isPlaying)"
        }
    }

    private func setStatus(_ text: String) {
        status = text
        onChange()
    }

    private func restartCapture() {
        capture?.stop()
        capture = nil
        capturedPID = nil
        refreshCapture()
    }

    // Start grabbing sound when the app to shift is making sound, and stop when it quits.
    private func refreshCapture() {
        guard running else { return }
        let pid: pid_t?
        switch source {
        case .music: pid = testPID ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first?.processIdentifier
        case .all: pid = getpid()  // everything except this app's own sound
        }
        guard let pid else {
            capture?.stop()
            capture = nil
            capturedPID = nil
            setStatus("Waiting for the Music app to open.")
            return
        }
        if capture != nil && pid == capturedPID { return }
        guard let process = audioProcess(for: pid) else {
            setStatus("Waiting for Music to play.")
            return
        }
        let description = source == .music
            ? CATapDescription(stereoMixdownOfProcesses: [process])
            : CATapDescription(stereoGlobalTapButExcludeProcesses: [process])
        do {
            capture?.stop()
            capture = try Capture(description) { [weak self] buffer in
                audioQueue.async { self?.player?.play(buffer) }
            }
            capturedPID = pid
            rebuildPlayer()
        } catch {
            capture = nil
            setStatus((error as? Problem)?.message ?? "\(error)")
        }
    }

    // The speakers or headphones changed (picked in the Sound menu, plugged in, connected, or disconnected).
    private func outputChanged() {
        guard running, !rebuildPending else { return }
        let device = defaultOutput()
        let needed = audioQueue.sync { player == nil || player!.device != device || !player!.engine.isRunning }
        guard needed else { return }
        rebuildPending = true
        // Wait a moment: devices often send several changes in a row while connecting.
        rebuilds = rebuilds.filter { $0.timeIntervalSinceNow > -10 } + [Date()]
        let delay = rebuilds.count > 5 ? 3.0 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.rebuildPending = false
            self?.rebuildPlayer()
        }
    }

    private func rebuildPlayer() {
        guard running, let format = capture?.format else { return }
        let device = defaultOutput()
        let steps = halfSteps
        let result: Result<Void, Error> = audioQueue.sync {
            player?.stop()
            player = nil
            return Result { player = try Player(device: device, format: format, halfSteps: steps) }
        }
        let what = source == .music ? "Music" : "all sound"
        switch result {
        case .success: setStatus("Shifting \(what), playing to \(deviceName(device)).")
        case .failure: setStatus("Could not play to \(deviceName(device)).")
        }
    }
}

// MARK: - Window

final class AppDelegate: NSObject, NSApplicationDelegate {
    let shifter = Shifter(
        halfSteps: UserDefaults.standard.object(forKey: halfStepsKey) as? Float ?? 2,
        source: Source(rawValue: UserDefaults.standard.string(forKey: sourceKey) ?? "") ?? .music)
    var window: NSWindow!
    let stepsLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let amountField = NSTextField(string: "")
    let sourcePicker = NSSegmentedControl(labels: ["Music only", "All sound"], trackingMode: .selectOne, target: nil, action: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        shifter.onChange = { [weak self] in self?.refresh() }
        refresh()
        showWindow()
        // Show the window first: the first time, macOS asks for permission to grab sound and waits for an answer.
        DispatchQueue.main.async { self.shifter.start() }
    }

    // Clicking the app on the Desktop or in the Dock while it's running brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { shifter.stop() }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Pitch Shift", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Pitch Shift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    func buildWindow() {
        stepsLabel.font = .monospacedDigitSystemFont(ofSize: 56, weight: .bold)
        stepsLabel.alignment = .center
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center

        let lower = NSButton(title: "Lower", target: self, action: #selector(lower))
        let normal = NSButton(title: "Normal", target: self, action: #selector(normal))
        let higher = NSButton(title: "Higher", target: self, action: #selector(higher))
        let buttons = NSStackView(views: [lower, normal, higher])
        buttons.spacing = 8

        // Type an exact amount, like 2.5 or -1.25, and press Return.
        amountField.placeholderString = "like 2.5"
        amountField.alignment = .center
        amountField.target = self
        amountField.action = #selector(setAmount)
        amountField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let exact = NSStackView(views: [NSTextField(labelWithString: "Exact amount:"), amountField,
                                        NSButton(title: "Set", target: self, action: #selector(setAmount))])
        exact.spacing = 8

        sourcePicker.target = self
        sourcePicker.action = #selector(sourcePicked)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.preferredMaxLayoutWidth = 252

        let note = NSTextField(wrappingLabelWithString: "Closing this window keeps it running. Quit to stop.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .tertiaryLabelColor
        note.alignment = .center
        note.preferredMaxLayoutWidth = 252

        let quit = NSButton(title: "Quit Pitch Shift", target: NSApp, action: #selector(NSApplication.terminate(_:)))

        // Fixed width so long device names wrap instead of getting cut off.
        for label in [statusLabel, note] { label.widthAnchor.constraint(equalToConstant: 252).isActive = true }
        statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true

        let stack = NSStackView(views: [stepsLabel, detailLabel, buttons, exact, sourcePicker, statusLabel, note, quit])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(2, after: stepsLabel)
        stack.setCustomSpacing(16, after: detailLabel)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 340), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Pitch Shift"
        window.isReleasedWhenClosed = false
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
    }

    // 2.5 -> "2.5", 3.0 -> "3", -1.25 -> "1.25" (the sign is added separately).
    func amountText(_ value: Float) -> String {
        var text = String(format: "%.2f", abs(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    func refresh() {
        let steps = shifter.halfSteps
        let amount = amountText(steps)
        stepsLabel.stringValue = steps == 0 ? "0" : (steps > 0 ? "+" : "−") + amount
        detailLabel.stringValue = steps == 0 ? "Normal pitch" : "\(amount) half-step\(amount == "1" ? "" : "s") \(steps > 0 ? "higher" : "lower")"
        sourcePicker.selectedSegment = shifter.source == .music ? 0 : 1
        statusLabel.stringValue = shifter.status
    }

    func change(to steps: Float) {
        shifter.halfSteps = (min(24, max(-24, steps)) * 100).rounded() / 100
        UserDefaults.standard.set(shifter.halfSteps, forKey: halfStepsKey)
        refresh()
    }

    @objc func higher() { change(to: shifter.halfSteps + 1) }
    @objc func lower() { change(to: shifter.halfSteps - 1) }
    @objc func normal() { change(to: 0) }

    @objc func setAmount() {
        let text = amountField.stringValue.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")
        guard let value = Float(text), abs(value) <= 24 else {
            NSSound.beep()
            amountField.stringValue = ""
            amountField.placeholderString = "-24 to 24"
            return
        }
        change(to: value)
        amountField.stringValue = ""
        amountField.placeholderString = "like 2.5"
    }

    @objc func sourcePicked() {
        shifter.source = sourcePicker.selectedSegment == 0 ? .music : .all
        UserDefaults.standard.set(shifter.source.rawValue, forKey: sourceKey)
        refresh()
    }
}

// MARK: - Start

var signalSources: [DispatchSourceSignal] = []
func onQuitSignals(_ handler: @escaping () -> Void) {
    signalSources = [SIGINT, SIGTERM, SIGHUP].map { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }
}

let args = CommandLine.arguments
if args.contains("--test") {
    let steps = args.firstIndex(of: "--steps").flatMap { Float(args[$0 + 1]) } ?? 2
    let shifter = Shifter(halfSteps: steps, source: args.contains("--all") ? .all : .music)
    if let i = args.firstIndex(of: "--pid"), i + 1 < args.count { shifter.testPID = pid_t(args[i + 1]) }
    let seconds = args.firstIndex(of: "--seconds").flatMap { Double(args[$0 + 1]) } ?? 3
    onQuitSignals { shifter.stop(); exit(0) }
    shifter.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        print("test: \(shifter.report)")
        shifter.stop()
        exit(0)
    }
    dispatchMain()
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
onQuitSignals { delegate.shifter.stop(); exit(0) }
app.run()
