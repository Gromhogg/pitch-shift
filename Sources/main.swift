// Pitch Shift: plays an app's sound (or all sound) and/or your voice at a higher or lower pitch, live.
// Checks from Terminal (inside "Pitch Shift.app/Contents/MacOS/PitchShift"):
//   --list                                     sound devices (and which are in use), Pitch Shift Mic, and which app each
//                                              sound process belongs to
// The device tests (--test, --test-voice, --test-button, --test-default-mic) refuse to start while Pitch Shift Mic,
// the built-in mic or a Bluetooth mic is in use by another app (for example a call), or the Pitch Shift app is open.
//   --test [--pid N | --app BUNDLE_ID | --all] [--steps 2.5] [--seconds S]     "What you hear" for a few seconds
//   --test-voice [--mic NAME] [--tone 440 | --file F] [--steps 3] [--cartoon | --cartoon-amount 0.5] [--seconds S]
//                [--out F.caf] [--watch] [--buffer N]
//                                              sends a tone or file through the voice chain and records Pitch Shift Mic
//                                              (voice style from 0 = Natural, the default, to 1 = Cartoon; --cartoon = 1).
//                                              --watch: the tone plays for half of every second; once a second it prints
//                                              the sound waiting to go out, the dry-outs/trims/replays and the delay from
//                                              the mic to Pitch Shift Mic (the delay parts are printed at the start).
//                                              --buffer N: callback size to ask for (default 128, or 256 above 48 kHz)
//   --render-voice IN OUT [--steps 3] [--cartoon | --cartoon-amount 0.5] [--cartoon-at "1:1,2:0"]
//                                              shifts a sound file with the voice's own settings (offline, no devices;
//                                              --cartoon-at "1:1,2:0" moves the style to 1 at 1 s and back to 0 at 2 s)
//   --test-button [--mic NAME] [--volume 0.03] presses Test with a quiet tone as the voice (record 5 s, play back)
//   --test ... --advanced [--record-out F.wav] [--steps-at "3:8,6:-5"]
//                                              "What you hear" with Advanced processing on (--watch prints the delay;
//                                              --record-out saves what it played; --steps-at changes the amount live)
//   --render-file IN OUT [--steps 5] [--advanced] [--steps-at "4:8,8:-5"]
//                                              shifts a sound file with the app's own code (normal or advanced)
import AppKit
import AVFoundation
import CoreAudio

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
// --preview STATES [--size 800x400] [--cartoon-amount 0.5]: show the window in a state for screenshots, without
// touching any sound or settings, and without switching apps (states: hear-on, voice-on, waiting, typing, recording,
// playing, listening, hover, menu, roll, resize, no-driver, advanced-alert, light; --cartoon-amount sets the voice
// style slider).
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

// Voice style from the command line: --cartoon = 1 (Cartoon), --cartoon-amount X (0 = Natural ... 1 = Cartoon).
// In --preview it sets where the slider is.
let cartoonArg: Float? = args.contains("--cartoon") ? 1 : arg("--cartoon-amount").flatMap(Float.init).map { max(0, min(1, $0)) }

// The watchdog: a second copy of the app that gives the real mic back if the app ends without doing it.
if let pid = arg("--watchdog").flatMap({ pid_t($0) }) { DefaultMic.watch(pid) }

// Device tests share the Mac's microphones and Pitch Shift Mic with whatever the owner is doing. They only start
// when Pitch Shift Mic, the built-in mic and every Bluetooth mic are idle (not used by any app, for example a call
// in FaceTime, Discord or a browser), and the Pitch Shift app itself isn't open: with "Your voice" on, a test
// reading Pitch Shift Mic would wake the app's voice on the real mic, and the Test playback would send that to the
// owner's headphones. Otherwise they stop right away, before touching any device.
func refuseIfMicsBusy() {
    let me = ProcessInfo.processInfo.processIdentifier
    if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.pitch-shift")
        .contains(where: { $0.processIdentifier != me }) {
        print("Not starting: the Pitch Shift app is open (its voice or sound would mix into the test). Nothing was changed; try again later.")
        exit(2)
    }
    let busy = allDevices().filter { id in
        guard streamCount(id, kAudioDevicePropertyScopeInput) > 0, isRunningSomewhere(id) else { return false }
        let transport = transportType(id)
        return deviceUID(id) == virtualMicUID || transport == kAudioDeviceTransportTypeBuiltIn
            || transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    guard busy.isEmpty else {
        print("Not starting: \(busy.map(deviceName).joined(separator: ", ")) in use by another app right now (maybe a call). Nothing was changed; try again later.")
        exit(2)
    }
}
if ["--test", "--test-voice", "--test-button", "--test-default-mic"].contains(where: { args.contains($0) }) { refuseIfMicsBusy() }

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
        let flags = (id == out ? " [default output]" : "") + (id == inp ? " [default input]" : "") + (isRunningSomewhere(id) ? " [in use]" : "")
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

if let input = arg("--render-file") {
    let i = args.firstIndex(of: "--render-file")!
    guard i + 2 < args.count else { print("usage: --render-file IN OUT [--steps N] [--advanced]"); exit(1) }
    // "4:8,8:-5" = at 4 s go to +8, at 8 s go to -5
    let changes: [(Double, Float)] = (arg("--steps-at") ?? "").split(separator: ",").compactMap { item in
        let parts = item.split(separator: ":")
        guard parts.count == 2, let t = Double(parts[0]), let n = Float(parts[1]) else { return nil }
        return (t, n)
    }
    let started = Date()
    do {
        try renderFile(input: input, output: args[i + 2], halfSteps: arg("--steps").flatMap(Float.init) ?? 2,
                       advanced: args.contains("--advanced"), changes: changes)
        print(String(format: "wrote %@ (%.1f s)", args[i + 2], Date().timeIntervalSince(started)))
        exit(0)
    } catch {
        print("render failed: \((error as? Problem)?.message ?? "\(error)")")
        exit(1)
    }
}

if let input = arg("--render-voice") {
    let i = args.firstIndex(of: "--render-voice")!
    guard i + 2 < args.count else { print("usage: --render-voice IN OUT [--steps N] [--cartoon-amount X]"); exit(1) }
    // "1:1,2:0" = at 1 s go to Cartoon, at 2 s back to Natural
    let changes: [(Double, Float)] = (arg("--cartoon-at") ?? "").split(separator: ",").compactMap { item in
        let parts = item.split(separator: ":")
        guard parts.count == 2, let t = Double(parts[0]), let n = Float(parts[1]) else { return nil }
        return (t, n)
    }
    do {
        try renderVoiceFile(input: input, output: args[i + 2], halfSteps: arg("--steps").flatMap(Float.init) ?? 3,
                            cartoon: cartoonArg ?? 0, changes: changes)
        print("wrote \(args[i + 2])")
        exit(0)
    } catch {
        print("render failed: \((error as? Problem)?.message ?? "\(error)")")
        exit(1)
    }
}

if args.contains("--test") {
    let source: HearSource = args.contains("--all") ? .all : HearSource(saved: arg("--app") ?? "com.apple.Music")
    let shifter = HearShifter(halfSteps: arg("--steps").flatMap(Float.init) ?? 2, source: source, advanced: args.contains("--advanced"))
    shifter.testPID = arg("--pid").flatMap { pid_t($0) }
    let seconds = arg("--seconds").flatMap(Double.init) ?? 3
    // --record-out F (Advanced processing only): saves what it played. --steps-at "2:8,4:-5": change the amount live.
    let recordPath = arg("--record-out")
    if recordPath != nil { shifter.testRecordSeconds = seconds + 1 }
    for item in (arg("--steps-at") ?? "").split(separator: ",") {
        let parts = item.split(separator: ":")
        guard parts.count == 2, let t = Double(parts[0]), let n = Float(parts[1]) else { continue }
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { shifter.halfSteps = n }
    }
    func finish() {
        print("test: \(shifter.report)")
        if let recordPath { shifter.saveTestRecording(to: recordPath); print("wrote \(recordPath)") }
        shifter.stop()
        exit(0)
    }
    onQuitSignals { shifter.stop(); exit(0) }
    shifter.start()
    if args.contains("--watch") {  // print the delay every half second
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            print(String(format: "%5.1fs  ", Date().timeIntervalSince(started)) + shifter.timing)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish() }
        RunLoop.main.run()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish() }
    dispatchMain()
}

if args.contains("--test-voice") {
    let steps = arg("--steps").flatMap(Float.init) ?? 3
    let micUID = arg("--mic").flatMap { name in Mics.list().first { $0.name == name }?.uid }
    let voice = VoiceShifter(halfSteps: steps, cartoon: cartoonArg ?? 0, micUID: micUID)
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
    // --watch: the tone plays for half of every second, so the delay can be measured again each second.
    let watch = args.contains("--watch")
    let toneStarts = UnsafeMutablePointer<Double>.allocate(capacity: Int(seconds) + 2)  // host time of each tone start (s)
    var toneCount = 0
    voice.testBufferFrames = arg("--buffer").flatMap(UInt32.init)
    voice.testSource = { buffer, frames in
        for i in 0..<frames {
            if let tone {
                let t = position - toneStart
                let on = t >= 0 && (!watch || t % Int(rate) < Int(rate) / 2)
                if watch && t >= 0 && t % Int(rate) == 0 && toneCount < Int(seconds) + 2, let chain = voice.chain {
                    phase = 0
                    toneStarts[toneCount] = Double(AudioConvertHostTimeToNanos(chain.blockInputTime)) / 1e9 + Double(i) / rate
                    toneCount += 1
                }
                buffer[i] = on ? Float(0.3 * sin(phase)) : 0
                if on { phase += 2 * .pi * tone / rate }
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
    var delays: [Double] = []  // --watch: mic to Pitch Shift Mic, once per tone start (ms)
    if watch {
        print(chain.delayParts)
        let started = Date()
        var scanned = 0, quiet = 0, matched = 0
        func ms(_ frames: Int) -> Double { Double(frames) / chain.sampleRate * 1000 }
        func look() {
            // New tone starts heard in Pitch Shift Mic: loud after at least 0.15 s of quiet.
            let heard = recorder.recorded(from: scanned)
            let base = Double(AudioConvertHostTimeToNanos(recorder.firstInputTime)) / 1e9
            for (k, x) in heard.enumerated() {
                if abs(x) > 0.02 {
                    if quiet >= Int(0.15 * recorder.sampleRate), recorder.firstInputTime > 0 {
                        let at = base + Double(scanned + k) / recorder.sampleRate
                        // Count only the first sound within 0.4 s of a tone start (a tone fades in and out a little).
                        if let index = (0..<toneCount).last(where: { toneStarts[$0] <= at }), index >= matched, at - toneStarts[index] < 0.4 {
                            delays.append((at - toneStarts[index]) * 1000)
                            matched = index + 1
                        }
                    }
                    quiet = 0
                } else {
                    quiet += 1
                }
            }
            scanned += heard.count
            let s = chain.stats.withLock { s -> VoiceStats in
                let copy = s
                s.lowest = .max
                return copy
            }
            var line = String(format: "%3.0fs  ring %5d (%5.1f ms, lowest %@) | Rubber Band + ring %5.1f ms | callback %d",
                              Date().timeIntervalSince(started), s.ring, ms(s.ring), s.lowest == .max ? "  -  " : String(format: "%5.1f ms", ms(s.lowest)),
                              ms(s.delay), s.frames)
            line += String(format: " | margin %.1f ms | dry-outs %d, trims %d (%.0f ms), replays %d (%.0f ms), overloads %d",
                           ms(s.margin), s.dryOuts, s.trims, ms(s.trimmed), s.replays, ms(s.replayed), s.overloads)
            if tone != nil { line += delays.last.map { String(format: " | mic to Pitch Shift Mic %.0f ms", $0) } ?? " | mic to Pitch Shift Mic -" }
            print(line)
            if Date().timeIntervalSince(started) < seconds - 0.5 { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { look() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { look() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.2) {
        let recorded = recorder.finish()
        voice.stop()
        let peak = recorded.reduce(Float(0)) { max($0, abs($1)) }
        let firstSound = recorded.firstIndex { abs($0) > 0.02 }.map { Double($0) / recorder.sampleRate * 1000 }
        let s = chain.stats.withLock { $0 }
        var line = "voice test: mic=\(chain.micName) rate=\(Int(chain.sampleRate)) style=\(voice.cartoon) callback=\(s.frames) "
        line += String(format: "shifter+wait=%.0fms dry-outs=%d overloads=%d ", Double(s.delay) / chain.sampleRate * 1000, s.dryOuts, s.overloads)
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
        if !delays.isEmpty {
            print(String(format: "watch: mic to Pitch Shift Mic %.0f..%.0f ms over %d tone starts (first %.0f, last %.0f)",
                         delays.min()!, delays.max()!, delays.count, delays.first!, delays.last!))
        }
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
    let micUID = arg("--mic").flatMap { name in Mics.list().first { $0.name == name }?.uid }  // e.g. not a Bluetooth headset's
    let voice = VoiceShifter(halfSteps: 3, cartoon: 0, micUID: micUID)
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
app.setActivationPolicy(preview == nil ? .regular : .accessory)  // pictures: no Dock icon, no switching apps
let delegate = AppDelegate()
app.delegate = delegate
onQuitSignals {
    delegate.hear.stop()
    delegate.voice.stop()
    DefaultMic.giveBack()
    exit(0)
}
app.run()
