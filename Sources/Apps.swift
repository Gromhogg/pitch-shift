// Finds which apps are using sound, grouping helper processes (Chrome Helper, Safari's sound process, ...) under
// the app they belong to, so "Google Chrome" in the list means all of Chrome's sound.
import AppKit
import CoreAudio

struct SoundApp {
    let bundleID: String
    let name: String
    let icon: NSImage?
    var processes: [AudioObjectID]  // Core Audio ids of every process that belongs to this app
    var isPlaying: Bool
}

enum Apps {
    private static var ownerCache: [pid_t: String] = [:]  // helper pid -> owning app's bundle ID ("" = none)

    // Every app (other than this one) that has used sound, with all its processes.
    static func scan() -> [SoundApp] {
        let me = getpid()
        var apps: [String: SoundApp] = [:]
        let processes = getArray(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        let livePIDs = Set(processes.map { getValue($0, kAudioProcessPropertyPID, default: pid_t(-1)) })
        ownerCache = ownerCache.filter { livePIDs.contains($0.key) }
        for process in processes {
            let pid = getValue(process, kAudioProcessPropertyPID, default: pid_t(-1))
            guard pid > 0, pid != me, let owner = ownerApp(of: pid), owner.processIdentifier != me,
                  let bundleID = owner.bundleIdentifier else { continue }
            let playing = getValue(process, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            if apps[bundleID] == nil {
                apps[bundleID] = SoundApp(bundleID: bundleID, name: owner.localizedName ?? bundleID, icon: owner.icon, processes: [], isPlaying: false)
            }
            apps[bundleID]!.processes.append(process)
            apps[bundleID]!.isPlaying = apps[bundleID]!.isPlaying || playing
        }
        return apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // The regular app a process belongs to: the app macOS says is responsible for it, else the outermost
    // ".app" in its file path, else the nearest parent process that is an app.
    static func ownerApp(of pid: pid_t) -> NSRunningApplication? {
        if let cached = ownerCache[pid] {
            return cached.isEmpty ? nil : NSRunningApplication.runningApplications(withBundleIdentifier: cached).first
        }
        let owner = findOwner(of: pid)
        ownerCache[pid] = owner?.bundleIdentifier ?? ""
        return owner
    }

    private static func findOwner(of pid: pid_t) -> NSRunningApplication? {
        func regular(_ pid: pid_t) -> NSRunningApplication? {
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  app.bundleIdentifier != nil else { return nil }
            return app
        }
        let responsible = responsibility_get_pid_responsible_for_pid(pid)
        if responsible > 0, let app = regular(responsible) { return app }

        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            if let range = path.range(of: ".app/") {
                let bundlePath = String(path[..<range.lowerBound]) + ".app"
                if let bundleID = Bundle(path: bundlePath)?.bundleIdentifier,
                   let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0.activationPolicy == .regular }) {
                    return app
                }
            }
        }

        var current = pid
        for _ in 0..<10 {
            if let app = regular(current) { return app }
            var info = proc_bsdinfo()
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { break }
            let parent = pid_t(info.pbi_ppid)
            if parent <= 1 || parent == current { break }
            current = parent
        }
        return nil
    }

    // Name and icon for an app that may not be running (for the saved choice in the list).
    static func info(for bundleID: String) -> (name: String, icon: NSImage?) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return (app.localizedName ?? bundleID, app.icon)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return (name, NSWorkspace.shared.icon(forFile: url.path))
        }
        return (bundleID, nil)
    }
}
