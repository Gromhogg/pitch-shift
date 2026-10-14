// Pitch Shift: plays an app's sound (or all sound) and/or your voice at a higher or lower pitch, live.
// Checks from Terminal (inside "Pitch Shift.app/Contents/MacOS/PitchShift"):
//   --list                                     sound devices, Pitch Shift Mic, and which app each sound process belongs to
//   --test [--pid N | --app BUNDLE_ID | --all] [--steps 2.5] [--seconds S]     "What you hear" for a few seconds
//   --test-voice [--mic NAME] [--tone 440 | --file F] [--steps 3] [--cartoon] [--seconds S] [--out F.caf]
//                                              sends a tone or file through the voice chain and records Pitch Shift Mic
//   --test-button [--volume 0.03]              presses Test with a quiet tone as the voice (record 5 s, play back)
import AppKit
import AVFoundation
import CoreAudio

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
// --preview STATES [--size 800x400]: show the window in a state for screenshots, without touching any sound
// (states: hear-on, voice-on, waiting, typing, recording, playing, listening, hover, menu, roll, resize, no-driver,
// light).
let preview = arg("--preview")

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

func fourCC(_ value: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }, encoding: .ascii) ?? "\(value)"
}

// The watchdog: a second copy of the app that gives the real mic back if the app ends without doing it.
if let pid = arg("--watchdog").flatMap({ pid_t($0) }) { DefaultMic.watch(pid) }

// Makes Pitch Shift Mic the default mic and then waits, so a test can force-quit it and check the watchdog.
if args.contains("--test-default-mic") {
    DefaultMic.takeOver()
    print("default mic now: \(deviceName(defaultInput()))")
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
    dispatchMain()
}

if args.contains("--list") {
    let out = defaultOutput(), inp = defaultInput()
    print("Devices:")
    for id in allDevices() {
        let flags = (id == out ? " [default output]" : "") + (id == inp ? " [default input]" : "")
        print("  \(id) \(deviceName(id)) | \(deviceUID(id)) | \(Int(nominalRate(id))) Hz | \(fourCC(transportType(id))) | in \(streamCount(id, kAudioDevicePropertyScopeInput)) out \(streamCount(id, kAudioDevicePropertyScopeOutput))\(flags)")
    }
    if let mic = Mics.virtualMic, let feed = Mics.virtualFeed {
        print("Pitch Shift Mic: \(mic) (\(Int(nominalRate(mic))) Hz, in use: \(isRunningSomewhere(mic))), hidden feed: \(feed) (hidden: \(getValue(feed, kAudioDevicePropertyIsHidden, default: UInt32(0)) != 0))")
    } else {
        print("Pitch Shift Mic: not installed")
    }
    print("Microphones to choose from: \(Mics.list().map(\.name))")
    print("Sound processes:")
    for process in getArray(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self) {
        let pid = getValue(process, kAudioProcessPropertyPID, default: pid_t(-1))
        let bundleID = getString(process, kAudioProcessPropertyBundleID)
        let owner = Apps.ownerApp(of: pid)
        let playing = getValue(process, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
        print("  pid \(pid) \(bundleID.isEmpty ? "(no bundle id)" : bundleID) -> \(owner?.bundleIdentifier ?? "none") (\(owner?.localizedName ?? "-"))\(playing ? " PLAYING" : "")")
    }
    print("Apps in the list: \(Apps.scan().map { "\($0.name)\($0.isPlaying ? " (playing)" : "")" })")
    exit(0)
}

if args.contains("--test") {
    let source: HearSource = args.contains("--all") ? .all : HearSource(saved: arg("--app") ?? "com.apple.Music")
    let shifter = HearShifter(halfSteps: arg("--steps").flatMap(Float.init) ?? 2, source: source)
    shifter.testPID = arg("--pid").flatMap { pid_t($0) }
    let seconds = arg("--seconds").flatMap(Double.init) ?? 3
    onQuitSignals { shifter.stop(); exit(0) }
    shifter.start()
    if args.contains("--watch") {  // print the delay every half second
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            print(String(format: "%5.1fs  ", Date().timeIntervalSince(started)) + shifter.timing)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            print("test: \(shifter.report)")
            shifter.stop()
            exit(0)
        }
        RunLoop.main.run()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        print("test: \(shifter.report)")
        shifter.stop()
        exit(0)
    }
    dispatchMain()
}

if args.contains("--test-voice") {
    let steps = arg("--steps").flatMap(Float.init) ?? 3
    let micUID = arg("--mic").flatMap { name in Mics.list().first { $0.name == name }?.uid }
    let voice = VoiceShifter(halfSteps: steps, natural: !args.contains("--cartoon"), micUID: micUID)
    guard let mic = voice.currentMic, let virtualMic = Mics.virtualMic else { print("No mic or Pitch Shift Mic not installed"); exit(1) }
    let rate = nominalRate(mic)
    let seconds = arg("--seconds").flatMap(Double.init) ?? 3
    let tone = arg("--tone").flatMap(Double.init)
    var sourceSamples: [Float] = []
    if let path = arg("--file") {
        // Load a sound file as one channel at the mic's rate, to play into the chain in a loop.
        let file = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try! file.read(into: input)
        let target = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * rate / file.processingFormat.sampleRate) + 1024)!
        var given = false
        _ = converter.convert(to: converted, error: nil) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        sourceSamples = Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
    }
    var phase = 0.0, position = 0
    let toneStart = Int(rate)  // the tone starts 1 s in, once recording runs, so its delay can be measured
    voice.testSource = { buffer, frames in
        for i in 0..<frames {
            if let tone {
                buffer[i] = position < toneStart ? 0 : Float(0.3 * sin(phase))
                if position >= toneStart { phase += 2 * .pi * tone / rate }
                position += 1
            } else if !sourceSamples.isEmpty {
                buffer[i] = sourceSamples[position % sourceSamples.count]
                position += 1
            } else {
                buffer[i] = 0
            }
        }
    }
    onQuitSignals { voice.stop(); exit(0) }
    voice.start()
    guard let chain = voice.chain else { print("voice did not start: \(voice.state)"); exit(1) }
    let recorder = try! Recorder(device: virtualMic, seconds: seconds)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.2) {
        let recorded = recorder.finish()
        voice.stop()
        let peak = recorded.reduce(Float(0)) { max($0, abs($1)) }
        let firstSound = recorded.firstIndex { abs($0) > 0.02 }.map { Double($0) / recorder.sampleRate * 1000 }
        var line = "voice test: mic=\(chain.micName) rate=\(Int(chain.sampleRate)) cushion=\(Int(Double(chain.cushion) / chain.sampleRate * 1000))ms "
        line += "recorded=\(recorded.count) peak=\(peak) firstSound=\(firstSound.map { "\(Int($0))ms" } ?? "none")"
        if tone != nil, let heard = recorded.firstIndex(where: { abs($0) > 0.02 }), chain.firstInputTime > 0, recorder.firstInputTime > 0 {
            // From the tone starting at the mic to it coming out of Pitch Shift Mic.
            let toneAt = Double(AudioConvertHostTimeToNanos(chain.firstInputTime)) / 1e9 + Double(toneStart) / rate
            let heardAt = Double(AudioConvertHostTimeToNanos(recorder.firstInputTime)) / 1e9 + Double(heard) / recorder.sampleRate
            line += String(format: " delay=%.0fms", (heardAt - toneAt) * 1000)
        }
        if let tone, recorded.count > Int(recorder.sampleRate) {
            let tail = Array(recorded.suffix(Int(recorder.sampleRate)))
            let sr = recorder.sampleRate
            func level(_ f: Double) -> Double {
                var re = 0.0, im = 0.0
                for (i, x) in tail.enumerated() { re += Double(x) * cos(2 * .pi * f * Double(i) / sr); im += Double(x) * sin(2 * .pi * f * Double(i) / sr) }
                return 2 * sqrt(re * re + im * im) / Double(tail.count)
            }
            let expected = tone * pow(2, Double(steps) / 12)
            let best = stride(from: min(tone, expected) * 0.5, through: max(tone, expected) * 2, by: 0.5).max { level($0) < level($1) }!
            line += String(format: " | expected %.1f Hz, measured %.1f Hz, level %.3f, original left %.4f", expected, best, level(best), level(tone))
        }
        print(line)
        if let path = arg("--out"), let format = AVAudioFormat(standardFormatWithSampleRate: recorder.sampleRate, channels: 1),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(recorded.count)) {
            buffer.frameLength = AVAudioFrameCount(recorded.count)
            recorded.withUnsafeBufferPointer { memcpy(buffer.floatChannelData![0], $0.baseAddress!, recorded.count * MemoryLayout<Float>.size) }
            let file = try! AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
            try! file.write(from: buffer)
            print("wrote \(path)")
        }
        exit(0)
    }
    dispatchMain()
}

// Presses the Test button with a quiet tone as the "voice": records 5 s from Pitch Shift Mic, then plays it back.
if args.contains("--test-button") {
    let voice = VoiceShifter(halfSteps: 3, natural: true, micUID: nil)
    let rate = voice.currentMic.map(nominalRate) ?? 48000
    let volume = arg("--volume").flatMap(Double.init) ?? 0.03
    var phase = 0.0
    voice.testSource = { buffer, frames in
        for i in 0..<frames { buffer[i] = Float(volume * sin(phase)); phase += 2 * .pi * 440 / rate }
    }
    let test = VoiceTest(voice: voice)
    let started = Date()
    test.onChange = {
        let silent = voice.params.withLock { $0.silent }
        print(String(format: "%.1fs: %@ (voice %@, sending silence: %@)", Date().timeIntervalSince(started), "\(test.phase)", "\(voice.state)", "\(silent)"))
        if test.phase == .idle { voice.stop(); exit(0) }
    }
    voice.start()
    test.click()
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { print("timed out"); exit(1) }
    dispatchMain()
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
onQuitSignals {
    delegate.hear.stop()
    delegate.voice.stop()
    DefaultMic.giveBack()
    exit(0)
}
app.run()
