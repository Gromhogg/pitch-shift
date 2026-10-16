// Pitch Shift: plays an app's sound (or all sound) and/or your voice at a higher or lower pitch, live.
// Checks from Terminal (inside "Pitch Shift.app/Contents/MacOS/PitchShift"):
//   --list                                     sound devices (with model UIDs; and which are in use), Pitch Shift Mic,
//                                              the saved Bass ↔ Treble and Auto EQ per output, the voice's mic, and
//                                              which app each sound process belongs to
//   --watch-output [--seconds 10]              once a second: the output's sample rate (Bluetooth call mode shows
//                                              8000-24000 Hz), its own mic, and which apps record from which devices
// The device tests (--test, --test-voice, --test-button, --test-sounds, --test-default-mic) refuse to start while Pitch
// Shift Mic, the built-in mic or a Bluetooth mic is in use by another app (for example a call), or the Pitch Shift app
// is open.
//   --test [--pid N | --app BUNDLE_ID | --all] [--steps 2.5] [--seconds S]     "What you hear" for a few seconds
//   --test-voice [--mic NAME] [--tone 440 | --file F] [--steps 3] [--cartoon | --cartoon-amount 0.5] [--seconds S]
//                [--slow-deeper] [--out F.caf] [--watch] [--buffer N]
//                                              sends a tone or file through the voice chain and records Pitch Shift Mic
//                                              (voice style from 0 = Natural, the default, to 1 = Cartoon; --cartoon = 1;
//                                              --slow-deeper turns on "Deeper when slow" and prints the speaking rate
//                                              and the extra shift once a second).
//                                              --watch: the tone plays for half of every second; once a second it prints
//                                              the sound waiting to go out, the dry-outs/trims/replays and the delay from
//                                              the mic to Pitch Shift Mic (the delay parts are printed at the start).
//                                              --buffer N: callback size to ask for (default 128, or 256 above 48 kHz)
//   --render-voice IN OUT [--steps 3] [--cartoon | --cartoon-amount 0.5] [--cartoon-at "1:1,2:0"] [--slow-deeper]
//                [--voice-preset old]          shifts a sound file with the voice's own settings (offline, no devices;
//                                              --cartoon-at "1:1,2:0" moves the style to 1 at 1 s and back to 0 at 2 s;
//                                              --voice-preset old: as before the Natural level fix, for comparing)
//   --test-button [--mic NAME] [--volume 0.03] presses Test with a quiet tone as the voice (record 5 s, play back)
//   --test-sounds FILE [--speakers] [--seconds S] [--out F.caf] [--mic NAME] [--steps 3] [--volume 0.05] [--hear 0.02]
//                [--sound-volume 0.5] [--voice-off]
//                                              Soundboard: plays FILE into Pitch Shift Mic 1 s in, with a quiet tone as
//                                              the voice, records Pitch Shift Mic and checks it (one copy of the sound,
//                                              its level; --speakers: as if on the Mac's speakers, so the voice must
//                                              stop while it plays). --hear: also play it here at that volume.
//                                              --recording F.caf: check a recording saved with --out (no devices).
//                                              --stop-after S: press Stop S seconds after the sound starts.
//                                              --hear-out F.caf: save the owner's copy (with --hear).
//                                              --sound-volume V: the sound's own volume (0 ... 1.5, Volume… on its
//                                              button), so its level in Pitch Shift Mic should be V x the file.
//                                              --voice-off: as with "Your voice" off and the Soundboard open: the
//                                              tone must come through at its own pitch (440 Hz), no shift.
//   --test ... --advanced [--record-out F.wav] [--steps-at "3:8,6:-5"] [--tone-amount 0.5] [--tone-at "2:1,4:-1"]
//              [--as-device UID] [--tone-db 6,-6] [--auto-eq] [--eq-offsets 0,0,0,0,0]
//                                              "What you hear" with Advanced processing on (--watch prints the delay;
//                                              --record-out saves what it played; --steps-at changes the amount live;
//                                              --tone-amount sets the Bass ↔ Treble slider, −1 … 1, for the output;
//                                              --tone-at moves it live; --as-device uses that device's saved Bass ↔
//                                              Treble and Auto EQ as if it were playing; --tone-db sets bass and
//                                              treble in dB; --auto-eq turns on Auto EQ, --eq-offsets gives its five
//                                              manual offsets in dB, Sub, Bass, Mids, Highs, Air, instead of the saved
//                                              Auto EQ; --watch also prints its gains and levels while it's in use)
//   --render-file IN OUT [--steps 5] [--advanced] [--steps-at "4:8,8:-5"] [--tone-amount 0.5] [--tone-at "2:1,4:-1"]
//                [--tone-db 6,-6] [--auto-eq] [--eq-offsets 0,0,0,0,0]
//                                              shifts a sound file with the app's own code (normal or advanced)
import AppKit
import AVFoundation
import CoreAudio

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
// --preview STATES [--size 800x400] [--cartoon-amount 0.5] [--tone-amount -0.4] [--eq-offsets 3,-2,0,1,-1]: show
// the window in a state for screenshots, without touching any sound or settings, and without switching apps (states:
// hear-on, voice-on, waiting, typing, recording, playing, listening, hover, menu, roll, resize, no-driver,
// advanced-alert, sounds, rename, volume, drop, light, tone, slow, eq; --cartoon-amount sets the voice style slider;
// sounds opens the Soundboard with example names, rename shows the first name being changed, volume the first
// sound's volume slider and drop files being dragged over it; "tone" shows Advanced processing on, and --tone-amount
// sets the Bass ↔ Treble slider; slow turns on "Deeper when slow"; eq turns on Auto EQ, and --eq-offsets sets its
// five sliders, which show only the offsets since no sound plays; without eq, Auto EQ shows off).
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

// --tone-db "B,T": Advanced processing's bass and treble in dB (not --tone, which is a frequency in --test-voice).
let toneDbArg: (bass: Double, treble: Double)? = {
    let parts = (arg("--tone-db") ?? "").split(separator: ",").compactMap { Double($0) }
    return parts.count == 2 ? (parts[0], parts[1]) : nil
}()
// --tone-amount T: the Bass ↔ Treble slider, −1 (more bass) … 0 (middle) … 1 (more treble). In --preview it sets
// where the slider is. --tone-at "2:1,4:-1": moves it to 1 at 2 s, then to −1 at 4 s.
func parseTilt(_ text: Substring) -> Float? { Float(text).flatMap { $0.isFinite ? max(-1, min(1, $0)) : nil } }
let toneArg: Float? = arg("--tone-amount").flatMap { parseTilt(Substring($0)) }
let toneChanges: [(Double, Float)] = (arg("--tone-at") ?? "").split(separator: ",").compactMap { item in
    let parts = item.split(separator: ":")
    guard parts.count == 2, let t = Double(parts[0]), let value = parseTilt(parts[1]) else { return nil }
    return (t, value)
}

// --auto-eq: Advanced processing's Auto EQ on. --eq-offsets "a,b,c,d,e": its manual offsets in dB (Sub, Bass, Mids,
// Highs, Air; −12 … 12; missing ones are 0).
let autoEQArg: (on: Bool, offsets: [Double]) = {
    let given = (arg("--eq-offsets") ?? "").split(separator: ",").compactMap { Double($0) }.filter(\.isFinite).map { max(-12, min(12, $0)) }
    return (args.contains("--auto-eq"), Array((given + AdvancedProcessor.noOffsets).prefix(5)))
}()

func fourCC(_ value: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }, encoding: .ascii) ?? "\(value)"
}

// Voice style from the command line: --cartoon = 1 (Cartoon), --cartoon-amount X (0 = Natural ... 1 = Cartoon).
// In --preview it sets where the slider is.
let cartoonArg: Float? = args.contains("--cartoon") ? 1 : arg("--cartoon-amount").flatMap(Float.init).map { max(0, min(1, $0)) }
// "Deeper when slow" on, for --test-voice and --render-voice.
let slowDeeperArg = args.contains("--slow-deeper")

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
if ["--test", "--test-voice", "--test-button", "--test-default-mic"].contains(where: { args.contains($0) })
    || (args.contains("--test-sounds") && !args.contains("--recording")) { refuseIfMicsBusy() }

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
        let model = modelUID(id)
        print("  \(id) \(deviceName(id)) | \(deviceUID(id)) | model \(model.isEmpty ? "-" : model) | \(Int(nominalRate(id))) Hz | \(fourCC(transportType(id))) | in \(streamCount(id, kAudioDevicePropertyScopeInput)) out \(streamCount(id, kAudioDevicePropertyScopeOutput))\(flags)")
    }
    // The Bass ↔ Treble slider (Advanced processing), as saved for each speakers or headphones (read only).
    let tones = AppDelegate.savedTones(UserDefaults.standard)
    print("Bass ↔ Treble saved per output (-1 bass … 1 treble):\(tones.isEmpty ? " none" : "")")
    for (uid, tilt) in tones.sorted(by: { $0.key < $1.key }) {
        let id = device(uid: uid)
        let name = id.map { deviceName($0) } ?? "not connected"
        print(String(format: "  %@ (%@): %.2f", uid, name, tilt) + (id == out ? " [default output]" : ""))
    }
    // Auto EQ (Advanced processing), as saved for each speakers or headphones (read only).
    let eqs = AppDelegate.savedAutoEQs(UserDefaults.standard)
    print("Auto EQ saved per output (offsets in dB: Sub, Bass, Mids, Highs, Air):\(eqs.isEmpty ? " none" : "")")
    for (uid, eq) in eqs.sorted(by: { $0.key < $1.key }) {
        let id = device(uid: uid)
        let name = id.map { deviceName($0) } ?? "not connected"
        print("  \(uid) (\(name)): \(eq.on ? "on" : "off"), " + eq.offsets.map { String(format: "%+.1f", $0) }.joined(separator: " ")
            + (id == out ? " [default output]" : ""))
    }
    if let mic = Mics.virtualMic, let feed = Mics.virtualFeed {
        print("Pitch Shift Mic: \(mic) (\(Int(nominalRate(mic))) Hz, in use: \(isRunningSomewhere(mic))), hidden feed: \(feed) (hidden: \(getValue(feed, kAudioDevicePropertyIsHidden, default: UInt32(0)) != 0))")
    } else {
        print("Pitch Shift Mic: not installed")
    }
    print("Microphones to choose from: \(Mics.list().map(\.name))")
    let picked = Mics.choose(nil)
    let why = picked.skipped.map { " (skipped headset mic of the current output: \(deviceName($0)))" } ?? ""
    print("Voice mic (default): \(picked.mic.map(deviceName) ?? "none")\(why)")
    if let saved = UserDefaults.standard.string(forKey: Keys.voiceMic) {
        print("Voice mic (picked in the app): \(Mics.resolve(saved).map(deviceName) ?? "none") (saved: \(saved))")
    }
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

// Read only: once a second, the sound output's sample rate and streams, its own mic (Bluetooth headphones), and
// every app that is recording and from which devices. Headphones in call mode show 8000-24000 Hz.
if args.contains("--watch-output") {
    let seconds = arg("--seconds").flatMap(Double.init) ?? 10
    let started = Date()
    func show() {
        let out = defaultOutput()
        var line = String(format: "%4.1fs  ", Date().timeIntervalSince(started))
        line += "output \(deviceName(out)): \(Int(nominalRate(out))) Hz, in \(streamCount(out, kAudioDevicePropertyScopeInput)) out \(streamCount(out, kAudioDevicePropertyScopeOutput))"
        if let mic = Mics.headsetMic(of: out) { line += " | its mic: \(Int(nominalRate(mic))) Hz, open: \(isRunningSomewhere(mic))" }
        for process in getArray(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        where getValue(process, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0 {
            let pid = getValue(process, kAudioProcessPropertyPID, default: pid_t(-1))
            let devices = getArray(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput, of: AudioObjectID.self)
            let bundleID = getString(process, kAudioProcessPropertyBundleID)
            let name = bundleID.isEmpty ? Apps.ownerApp(of: pid)?.localizedName ?? "?" : bundleID
            line += " | recording: \(name) (pid \(pid)) from \(devices.map { "\($0) \(deviceName($0))" })"
        }
        print(line)
        if Date().timeIntervalSince(started) + 0.5 >= seconds { exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { show() }
    }
    show()
    dispatchMain()
}

if let input = arg("--render-file") {
    let i = args.firstIndex(of: "--render-file")!
    guard i + 2 < args.count else { print("usage: --render-file IN OUT [--steps N] [--advanced] [--auto-eq] [--eq-offsets a,b,c,d,e]"); exit(1) }
    // "4:8,8:-5" = at 4 s go to +8, at 8 s go to -5
    let changes: [(Double, Float)] = (arg("--steps-at") ?? "").split(separator: ",").compactMap { item in
        let parts = item.split(separator: ":")
        guard parts.count == 2, let t = Double(parts[0]), let n = Float(parts[1]) else { return nil }
        return (t, n)
    }
    let started = Date()
    do {
        try renderFile(input: input, output: args[i + 2], halfSteps: arg("--steps").flatMap(Float.init) ?? 2,
                       advanced: args.contains("--advanced"), changes: changes,
                       tone: toneDbArg ?? AdvancedProcessor.toneDb(tilt: toneArg ?? 0), toneChanges: toneChanges,
                       autoEQ: autoEQArg)
        print(String(format: "wrote %@ (%.1f s)", args[i + 2], Date().timeIntervalSince(started)))
        exit(0)
    } catch {
        print("render failed: \((error as? Problem)?.message ?? "\(error)")")
        exit(1)
    }
}

if let input = arg("--render-voice") {
    let i = args.firstIndex(of: "--render-voice")!
    guard i + 2 < args.count else {
        print("usage: --render-voice IN OUT [--steps N] [--cartoon-amount X] [--slow-deeper] [--voice-preset old]"); exit(1)
    }
    let preset = arg("--voice-preset") ?? "current"
    guard preset == "current" || preset == "old" else { print("--voice-preset: old or current"); exit(1) }
    // "1:1,2:0" = at 1 s go to Cartoon, at 2 s back to Natural
    let changes: [(Double, Float)] = (arg("--cartoon-at") ?? "").split(separator: ",").compactMap { item in
        let parts = item.split(separator: ":")
        guard parts.count == 2, let t = Double(parts[0]), let n = Float(parts[1]) else { return nil }
        return (t, n)
    }
    do {
        try renderVoiceFile(input: input, output: args[i + 2], halfSteps: arg("--steps").flatMap(Float.init) ?? 3,
                            cartoon: cartoonArg ?? 0, changes: changes, slowDeeper: slowDeeperArg, levelFix: preset != "old")
        print("wrote \(args[i + 2])")
        exit(0)
    } catch {
        print("render failed: \((error as? Problem)?.message ?? "\(error)")")
        exit(1)
    }
}

if args.contains("--test") {
    let source: HearSource = args.contains("--all") ? .all : HearSource(saved: arg("--app") ?? "com.apple.Music")
    // Uses the saved Bass ↔ Treble and Auto EQ for the output, like the app (only read; --tone-amount changes the tone
    // for this test, --auto-eq / --eq-offsets replace the Auto EQ).
    let shifter = HearShifter(halfSteps: arg("--steps").flatMap(Float.init) ?? 2, source: source, advanced: args.contains("--advanced"),
                              tones: AppDelegate.savedTones(UserDefaults.standard), autoEQs: AppDelegate.savedAutoEQs(UserDefaults.standard))
    shifter.testPID = arg("--pid").flatMap { pid_t($0) }
    shifter.testOutputKey = arg("--as-device")
    shifter.fixedToneDb = toneDbArg
    if let toneArg { shifter.setTone(toneArg, for: shifter.outputKey) }
    if args.contains("--auto-eq") || arg("--eq-offsets") != nil { shifter.fixedAutoEQ = autoEQArg }
    let usedEQ = shifter.fixedAutoEQ ?? shifter.autoEQ(for: shifter.outputKey).engine
    let showAutoEQ = usedEQ.on || usedEQ.offsets.contains { $0 != 0 }
    for (t, value) in toneChanges {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { shifter.setTone(value, for: shifter.outputKey) }
    }
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
            var line = String(format: "%5.1fs  ", Date().timeIntervalSince(started)) + shifter.timing
            if showAutoEQ, let eq = shifter.autoEQReadout {
                line += "  auto EQ dB" + eq.auto.map { String(format: " %+.1f", $0) }.joined() +
                    "  levels" + eq.level.map { String(format: " %.0f", $0) }.joined()
            }
            print(line)
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
    let voice = VoiceShifter(halfSteps: steps, cartoon: cartoonArg ?? 0, slowDeeper: slowDeeperArg, micUID: micUID)
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
    voice.hold(true)  // runs the chain like the Test button does (no app is listening yet)
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
    if slowDeeperArg {  // once a second: the speaking rate and the extra shift in use
        let started = Date()
        func report() {
            let reading = chain.slowReading.withLock { $0 }
            print(String(format: "%4.1fs  rate %.1f syllables/s  extra %+.1f half-steps", Date().timeIntervalSince(started), reading.rate, reading.extra))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { report() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { report() }
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
        print(String(format: "%.1fs: %@ (voice %@, sending silence: %@, real mic open: %@)", Date().timeIntervalSince(started), "\(test.phase)",
                     "\(voice.state)", "\(silent)", "\(voice.chain != nil)"))
        if test.phase == .idle { voice.stop(); exit(0) }
    }
    voice.start()
    print("mic: \(voice.currentMic.map(deviceName) ?? "none")")
    test.click()
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { print("timed out"); exit(1) }
    dispatchMain()
}

// Soundboard check: a quiet tone is the voice, FILE plays into Pitch Shift Mic 1 s in, Pitch Shift Mic is recorded.
// --voice-off: as with "Your voice" off and the Soundboard open (the voice goes through unchanged).
if let path = arg("--test-sounds") {
    let voiceOff = args.contains("--voice-off")
    let steps = voiceOff ? 0 : arg("--steps").flatMap(Float.init) ?? 3
    let toneHz = 440.0
    // --recording F.caf: checks a recording saved earlier with --out (no devices are used).
    if let saved = arg("--recording") {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: saved)),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let reference = try? SoundClip(url: URL(fileURLWithPath: path), rate: file.processingFormat.sampleRate) else {
            print("Can't read \(saved) or \(path)")
            exit(1)
        }
        let recorded = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let samples = Array(UnsafeBufferPointer(start: reference.samples, count: reference.count))
        soundTestReport(recorded: recorded, reference: samples, rate: reference.rate,
                        toneHz: toneHz * pow(2, Double(steps) / 12)).forEach { print($0) }
        exit(0)
    }
    let micUID = arg("--mic").flatMap { name in Mics.list().first { $0.name == name }?.uid }
    let voice = VoiceShifter(halfSteps: steps, cartoon: 0, micUID: micUID)
    guard let mic = voice.currentMic, let virtualMic = Mics.virtualMic else { print("No mic or Pitch Shift Mic not installed"); exit(1) }
    let rate = nominalRate(mic)
    let volume = arg("--volume").flatMap(Double.init) ?? 0.05
    var phase = 0.0
    voice.testSource = { buffer, frames in
        for i in 0..<frames { buffer[i] = Float(volume * sin(phase)); phase += 2 * .pi * toneHz / rate }
    }
    let board = Soundboard(voice: voice, sounds: [], saves: false)
    board.speakers = args.contains("--speakers")
    board.hearVolume = arg("--hear").flatMap(Float.init) ?? 0
    // --hear-out: the owner's copy, as its player makes it (collected on the main thread).
    var heard: [Float] = []
    var heardRate = 0.0
    if arg("--hear-out") != nil {
        board.hearTap = { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let piece = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            let rate = buffer.format.sampleRate
            DispatchQueue.main.async { heard += piece; heardRate = rate }
        }
    }
    board.ready = board.hearVolume > 0  // like the open Soundboard: the owner's player is already running
    let url = URL(fileURLWithPath: path)
    let clip: SoundClip
    do { clip = try SoundClip(url: url, rate: rate) } catch { print("Can't read \(path)"); exit(1) }
    let seconds = arg("--seconds").flatMap(Double.init) ?? (1 + clip.seconds + 2)
    let soundVolume = arg("--sound-volume").flatMap(Float.init).map { max(0, min(SoundEntry.loudest, $0)) } ?? 1
    let started = Date()
    board.onChange = {
        print(String(format: "%.2fs: %@", Date().timeIntervalSince(started), board.playing.map { "playing \($0)" } ?? "stopped"))
    }
    onQuitSignals { voice.stopAll(); exit(0) }
    if voiceOff { voice.keepForSounds(true) } else { voice.start() }
    voice.hold(true)  // runs the chain like the Test button does (no app is listening yet)
    guard let chain = voice.chain else { print("voice did not start: \(voice.state)"); exit(1) }
    let recorder = try! Recorder(device: virtualMic, seconds: seconds)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        let asked = Date()
        board.play(clip, as: url.lastPathComponent, volume: soundVolume)
        if board.hearVolume > 0 { print(String(format: "the owner's copy took %.0f ms to start", Date().timeIntervalSince(asked) * 1000)) }
    }
    if let stopAfter = arg("--stop-after").flatMap(Double.init) {  // presses Stop part way through
        DispatchQueue.main.asyncAfter(deadline: .now() + 1 + stopAfter) { board.stop() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.2) {
        let recorded = recorder.finish()
        voice.stopAll()
        print(String(format: "sound test: file=%@ (%.2f s) mic=%@ rate=%d voice=%@ steps=%g speakers=%@ tone=%g sound volume=%g",
                     url.lastPathComponent, clip.seconds, chain.micName, Int(chain.sampleRate), voiceOff ? "off" : "on", steps,
                     board.speakers == true ? "yes" : "no", volume, soundVolume))
        // The file as the chain plays it, at the recording's rate.
        let reference = recorder.sampleRate == clip.rate ? clip : (try? SoundClip(url: url, rate: recorder.sampleRate))
        if let reference {
            let samples = Array(UnsafeBufferPointer(start: reference.samples, count: reference.count))
            let shifted = toneHz * pow(2, Double(steps) / 12)
            soundTestReport(recorded: recorded, reference: samples, rate: recorder.sampleRate, toneHz: shifted).forEach { print($0) }
        }
        if let out = arg("--out"), let format = AVAudioFormat(standardFormatWithSampleRate: recorder.sampleRate, channels: 1),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(recorded.count)) {
            buffer.frameLength = AVAudioFrameCount(recorded.count)
            for (i, x) in recorded.enumerated() { buffer.floatChannelData![0][i] = x }
            if (try? AVAudioFile(forWriting: URL(fileURLWithPath: out), settings: format.settings).write(from: buffer)) != nil {
                print("wrote \(out)")
            }
        }
        if let out = arg("--hear-out"), heardRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: heardRate, channels: 1),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, heard.count))) {
            buffer.frameLength = AVAudioFrameCount(heard.count)
            for (i, x) in heard.enumerated() { buffer.floatChannelData![0][i] = x }
            if (try? AVAudioFile(forWriting: URL(fileURLWithPath: out), settings: format.settings).write(from: buffer)) != nil {
                print("wrote \(out) (the owner's copy)")
            }
        }
        exit(0)
    }
    dispatchMain()
}

let app = NSApplication.shared
app.setActivationPolicy(preview == nil ? .regular : .accessory)  // pictures: no Dock icon, no switching apps
let delegate = AppDelegate()
app.delegate = delegate
onQuitSignals {
    delegate.hear.stop()
    delegate.voice.stopAll()
    DefaultMic.giveBack()
    exit(0)
}
app.run()
