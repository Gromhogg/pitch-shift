// While "Your voice" is on, Pitch Shift Mic becomes the Mac's default microphone, so apps set to the default mic
// (Discord's "Default", Zoom's "Same as System", ...) get the shifted voice. The real mic is put back when the
// voice is switched off or the app quits, and by a small watchdog process if the app ever crashes.
import CoreAudio
import Foundation

enum DefaultMic {
    private static let savedKey = "realDefaultMic"  // the real default mic from before we switched
    private static var watchdog: Process?

    // The real mic that was the default before Pitch Shift Mic took over (nil when we haven't taken over).
    static var realMic: AudioDeviceID? {
        guard let virtual = Mics.virtualMic, defaultInput() == virtual else { return nil }
        return UserDefaults.standard.string(forKey: savedKey).flatMap { device(uid: $0) } ?? builtInMic()
    }

    static func takeOver() {
        guard let virtual = Mics.virtualMic else { return }
        let current = defaultInput()
        if current != virtual { UserDefaults.standard.set(deviceUID(current), forKey: savedKey) }
        setDefaultInput(virtual)
        startWatchdog()
    }

    static func giveBack() {
        guard let virtual = Mics.virtualMic, defaultInput() == virtual else { return }
        if let real = UserDefaults.standard.string(forKey: savedKey).flatMap({ device(uid: $0) }) ?? builtInMic() {
            setDefaultInput(real)
        }
    }

    private static func builtInMic() -> AudioDeviceID? {
        allDevices().first { transportType($0) == kAudioDeviceTransportTypeBuiltIn && streamCount($0, kAudioDevicePropertyScopeInput) > 0 }
    }

    // A second copy of this program that waits for the app to end and gives the real mic back if needed.
    private static func startWatchdog() {
        guard watchdog == nil, let path = Bundle.main.executablePath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--watchdog", String(getpid())]
        try? process.run()
        watchdog = process
    }

    // Runs in the watchdog process.
    static func watch(_ pid: pid_t) -> Never {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            giveBack()
            exit(0)
        }
        source.resume()
        if kill(pid, 0) != 0 { giveBack(); exit(0) }  // already gone
        dispatchMain()
    }
}
