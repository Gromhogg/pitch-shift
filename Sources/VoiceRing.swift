// The voice's shifted sound on its way out. Rubber Band hands sound back in uneven pieces, so some of it has to wait
// here before it goes out; this keeps that wait as short as it safely can. Used only on the sound thread (and by
// the offline check). No memory is made after it's set up.
//
// - At the start it fills up to one callback + 20 ms (safe at every amount and callback size), then sends.
// - It watches the least sound left over after each callback. Once that has been steady for 2 s, any extra beyond a
//   small margin (2 ms to start with) is dropped, with a short crossfade (never a hard jump, so no click).
// - If the sound left over gets very low (the amount changed, or Rubber Band slowly falls behind), it steps back
//   and replays a few milliseconds, again with a crossfade, and keeps a bigger margin from then on (not when it
//   happens just after an amount change: Rubber Band's pace wobbles for a moment then, that's expected).
// - If it ever runs dry, it fades out, fills up again and fades back in, and keeps a bigger margin.
final class VoiceRing {
    private let size: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var read = 0
    private(set) var count = 0
    private(set) var waiting = true    // filling up before sound goes out
    private var fresh = true           // just started: the first fill may overshoot, so trim it
    private var played = 0             // samples sent since the start (how far back a replay may reach)
    let startCushion: Int              // sound kept beyond one callback when sending starts
    private(set) var margin: Int       // sound kept beyond one callback at the lowest point
    private let marginStep: Int
    private let marginMax: Int
    private let slack: Int             // how far above the margin the lowest point may sit before the extra is dropped
    private let checkEvery: Int
    private var sinceCheck = 0
    private var lowest = Int.max       // least sound left over after a callback, since the last check
    private var recent: [Int]          // the last few checks' lowest points (2 s)
    private var recentCount = 0
    private var settling = 0           // samples left in the unsteady moment after an amount change
    private let fade: Int              // length of fades and crossfades
    private var fadeIn = 0
    private var crossfade = 0          // samples of crossfade left
    private var crossfadeLength = 0
    private var crossfadeFrom = 0      // where the sound being faded out continues
    // What it did (for --test-voice --watch).
    private(set) var dryOuts = 0
    private(set) var trims = 0, trimmed = 0
    private(set) var replays = 0, replayed = 0

    init(rate: Double) {
        size = Int(rate) + 8192  // about a second: holds what's waiting plus what was just sent
        buffer = .allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
        startCushion = Int(rate * 0.02)
        margin = Int(rate * 0.002)
        marginStep = Int(rate * 0.002)
        marginMax = Int(rate * 0.02)
        slack = Int(rate * 0.002)
        checkEvery = Int(rate * 0.5)
        recent = [Int](repeating: 0, count: 4)
        fade = Int(rate * 0.005)
    }

    deinit { buffer.deallocate() }

    // Start over (the shifter started fresh): drop everything and fill up again.
    func reset() {
        read = 0
        count = 0
        played = 0
        waiting = true
        fresh = true
        crossfade = 0
        fadeIn = 0
        settling = 0
        restartWatch()
    }

    func write(_ samples: UnsafePointer<Float>, _ n: Int) {
        for j in 0..<n where count < size {
            buffer[(read + count) % size] = samples[j]
            count += 1
        }
    }

    // Call after writing a callback's worth of shifted sound, before reading `frames` samples.
    func settle(_ frames: Int) {
        if waiting {
            guard count >= startCushion + frames else { return }
            waiting = false
            if fresh { drop(count - startCushion - frames) }  // the first piece can overshoot: don't keep that as delay
            fresh = false
            fadeIn = fade
            restartWatch()
            return
        }
        let spare = count - frames  // what will be left after this callback
        lowest = min(lowest, spare)
        settling = max(0, settling - frames)
        // Getting very low: replay a little now, before it runs dry.
        if spare >= 0 && spare < margin / 2 && crossfade == 0 && replay(margin - spare) {
            if settling == 0 { growMargin() }  // right after an amount change the dip is expected; not a reason
            restartWatch()
            return
        }
        sinceCheck += frames
        guard sinceCheck >= checkEvery else { return }
        // Every half second: once the lowest point has been steady for 2 s, drop what's beyond the margin.
        recent[recentCount % recent.count] = lowest
        recentCount += 1
        lowest = .max
        sinceCheck = 0
        guard recentCount >= recent.count, crossfade == 0 else { return }
        let least = recent.min()!
        if least > margin + slack {
            trim(least - margin)
            for i in recent.indices { recent[i] -= least - margin }
        }
    }

    // The amount changed: Rubber Band hands sound back at a new pace for a moment, so watch the lowest point anew.
    func amountChanged() {
        settling = checkEvery * 4
        restartWatch()
    }

    // Fills `frames` samples (silence while filling up).
    func read(into out: UnsafeMutablePointer<Float>, _ frames: Int) {
        guard !waiting else {
            for i in 0..<frames { out[i] = 0 }
            return
        }
        let available = min(frames, count)
        for i in 0..<available {
            var value = buffer[read]
            if crossfade > 0 {
                let w = Float(crossfadeLength - crossfade + 1) / Float(crossfadeLength + 1)
                value = value * w + buffer[crossfadeFrom] * (1 - w)
                crossfadeFrom = (crossfadeFrom + 1) % size
                crossfade -= 1
            }
            if fadeIn > 0 {
                value *= Float(fade - fadeIn + 1) / Float(fade + 1)
                fadeIn -= 1
            }
            let left = available - i  // ran dry this time: fade out the last of it
            if available < frames && left <= fade { value *= Float(left) / Float(min(fade, available) + 1) }
            out[i] = value
            read = (read + 1) % size
        }
        count -= available
        played = min(played + available, size)
        if available < frames {
            for i in available..<frames { out[i] = 0 }
            dryOuts += 1
            waiting = true
            crossfade = 0
            if settling == 0 { growMargin() }
        }
    }

    private func growMargin() {
        margin = min(marginMax, margin + marginStep)
    }

    private func restartWatch() {
        lowest = .max
        sinceCheck = 0
        recentCount = 0
    }

    private func drop(_ n: Int) {
        let n = max(0, min(n, count))
        read = (read + n) % size
        count -= n
    }

    // Drops `n` waiting samples, crossfading from where the sound was going to where it now continues.
    private func trim(_ n: Int) {
        let n = max(0, min(n, count))
        guard n > 0 else { return }
        startCrossfade(from: read, length: min(fade, count))
        drop(n)
        trims += 1
        trimmed += n
    }

    // Steps back `n` samples that were already sent (they go out again), crossfading into them.
    private func replay(_ n: Int) -> Bool {
        let n = max(0, min(n, played, size / 2 - count))
        guard n > 0 else { return false }
        startCrossfade(from: read, length: min(fade, count))
        read = (read - n + size) % size
        count += n
        played -= n
        replays += 1
        replayed += n
        return true
    }

    private func startCrossfade(from position: Int, length: Int) {
        guard length > 0 else { return }
        crossfadeFrom = position
        crossfadeLength = length
        crossfade = length
    }
}
