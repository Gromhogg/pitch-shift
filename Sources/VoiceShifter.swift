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
    var cartoon: Float      // voice style: 0 = Natural, 1 = Cartoon, in between = a blend
    var slowDeeper = false  // "Deeper when slow": talking slowly makes the voice lower
    var silent: Bool        // during Test playback, so the replay isn't sent into a live call
}

// The sound effect (Soundboard) to mix into Pitch Shift Mic. Set from the window, read by the sound thread without
// waiting. The samples belong to a SoundClip that the window side keeps alive while the sound thread may read them.
struct SoundPlay: @unchecked Sendable {
    var samples: UnsafePointer<Float>?  // nil = no sound
    var count = 0
    var rate: Double = 0  // the samples' rate: a chain running at another rate doesn't play them
    var take = 0          // goes up with every play and stop, so the sound thread sees each one
    var muteMic = false   // playing on the Mac's speakers: the real mic is muted while it plays and just after
    var volume: Float = 1 // the playing sound's own volume (0 ... 1.5); it may change while the sound plays
}

// Plays the Soundboard's sound one sample at a time on a sound thread, following SoundPlay. Used for both copies:
// the one sent into Pitch Shift Mic (VoiceChain) and the owner's own (Soundboard), so both stop and switch the same
// way. A sound that is stopped or replaced fades out over 10 ms (stopping at once would click); a new one starts
// from its beginning. A new volume for the playing sound glides there in about 20 ms (a jump would click too).
// A sound also fades in over its first 5 ms and out over its last 10 ms: many files start or end in the middle of a
// loud wave, which clicks (a jump of 50-80 dB within 1 ms) and makes call apps' noise and level controls jump too.
// (5 ms keeps the punch of a sound that starts with a hit.)
struct SoundMix {
    private(set) var take: Int
    private let rate: Double
    private let fadeStep: Float  // 10 ms from full to nothing
    private let fadeLength: Int  // 10 ms
    private let riseStep: Float  // 5 ms from nothing to full
    private let ends: Bool       // fade in and out at the sound's own start and end
    private let volumeGlide: Float  // the part of the way to a new volume taken each sample (20 ms smoothing)
    private var sound: UnsafePointer<Float>?  // the one playing
    private var count = 0
    private var at = 0
    private var gain: Float = 1    // its volume now
    private var volume: Float = 1  // its volume as set (`gain` glides there)
    private var rise: Float = 1    // its fade-in
    private var fading: UnsafePointer<Float>?  // one that was stopped or replaced
    private var fadingCount = 0
    private var fadingAt = 0
    private var fadingGain: Float = 0
    private var fadingVolume: Float = 1

    // `take`: the SoundPlay's take now (a sound already playing isn't picked up). `ends: false`: no fades at a
    // sound's own start and end, as in 2.0.2 (--render-sounds --sound-preset old).
    init(rate: Double, take: Int, ends: Bool = true) {
        self.rate = rate
        self.take = take
        self.ends = ends
        fadeStep = Float(1 / (0.01 * rate))
        fadeLength = max(1, Int(0.01 * rate))
        riseStep = Float(1 / (0.005 * rate))
        volumeGlide = Float(1 - exp(-1 / (0.02 * rate)))
    }

    var playing: Bool { sound != nil }
    var active: Bool { sound != nil || fading != nil }

    // A new sound, or Stop. Returns true if a sound was playing (it now fades out).
    mutating func start(_ play: SoundPlay) -> Bool {
        take = play.take
        let cut = sound != nil
        if let playing = sound {
            fading = playing
            fadingCount = count
            fadingAt = at
            fadingGain = rise  // from where its fade-in had got to
            fadingVolume = gain
        }
        sound = nil
        guard let samples = play.samples, play.count > 0, play.rate == rate else { return cut }
        sound = samples
        count = play.count
        at = 0
        gain = play.volume
        volume = play.volume
        rise = ends ? 0 : 1
        return cut
    }

    // The playing sound's volume as set now (read from SoundPlay on every pass).
    mutating func follow(volume new: Float) { volume = new }

    // The next sample of the sound(s). `ended` turns true when the sound plays to its end.
    @inline(__always) mutating func next(_ ended: inout Bool) -> Float {
        var value: Float = 0
        if let playing = sound {
            if gain != volume {
                gain += (volume - gain) * volumeGlide
                if abs(volume - gain) < 1e-4 { gain = volume }
            }
            value = playing[at] * gain
            if ends {
                if rise < 1 {
                    rise = min(1, rise + riseStep)
                    value *= rise
                }
                let left = count - at
                if left < fadeLength { value *= Float(left) / Float(fadeLength) }
            }
            at += 1
            if at >= count {
                sound = nil
                ended = true
            }
        }
        if let old = fading {
            fadingGain -= fadeStep
            if fadingGain > 0 && fadingAt < fadingCount {
                var faded = old[fadingAt] * fadingGain * fadingVolume
                let left = fadingCount - fadingAt
                if ends && left < fadeLength { faded *= Float(left) / Float(fadeLength) }
                value += faded
                fadingAt += 1
            } else {
                fading = nil
            }
        }
        return value
    }
}

// Keeps voice + sound under full scale: unchanged up to 0.7, then eased so it never passes 0.95 (the Mac's clock
// matching between the mic and Pitch Shift Mic can add about 1% on top).
@inline(__always) func softLimit(_ x: Float) -> Float {
    let knee: Float = 0.7, ceiling: Float = 0.95
    let size = abs(x)
    guard size > knee else { return x }
    let eased = knee + (ceiling - knee) * tanh((size - knee) / (ceiling - knee))
    return x < 0 ? -eased : eased
}

// What Pitch Shift Mic sends after the voice: the Soundboard's sound mixed in, and the mic muted while a sound plays
// on the Mac's own speakers. Used on the voice chain's sound thread (VoiceChain) and by the offline check
// (--render-sounds), so both do exactly the same. Makes no memory and never waits.
//
// While a sound plays, voice + sound go through a limiter that keeps them at or under -3 dBFS: turned down at once
// when they'd pass it, held 15 ms, then back up over about 150 ms (after the sound it only comes back up, which
// takes up to about a second, so the voice never jumps). Before, the sum was only eased sample by sample from 0.7
// up to 0.95 (just under full scale): a loud sound at 150% sat in that bend half the time, and its points between
// samples went past full scale (up to +3.4 dBFS), which the clock matching into Pitch Shift Mic and the call app
// turn into clipped samples. With no sound playing nothing changes.
struct CallMix {
    private(set) var mix: SoundMix
    private var muteMic = false   // the playing sound is on the Mac's speakers
    private var muteLeft = 0      // samples the mic stays muted after a sound on the speakers ends
    private var micGain: Float = 1
    private let fadeStep: Float   // 10 ms from full to nothing
    private let muteAfter: Int    // 150 ms
    private let limits: Bool      // the limiter is used (not as in 2.0.2)
    static let ceiling: Float = 0.707946  // -3 dBFS
    private var limitGain: Float = 1
    private var holdLeft = 0
    private let hold: Int         // 15 ms: longer than half a wave of the lowest bass, so the gain doesn't wobble with it
    private let release: Float    // the part of the way back up taken each sample (150 ms)

    // `take`: the SoundPlay's take now (a sound already playing isn't picked up). `limits: false` (and `ends: false`
    // for the sound's fades): as in 2.0.2, for --render-sounds --sound-preset old.
    init(rate: Double, take: Int, limits: Bool = true, ends: Bool = true) {
        mix = SoundMix(rate: rate, take: take, ends: ends)
        fadeStep = Float(1 / (0.01 * rate))
        muteAfter = Int(rate * 0.15)
        self.limits = limits
        hold = Int(rate * 0.015)
        release = Float(1 - exp(-1 / (0.15 * rate)))
    }

    // The Soundboard's latest state (read once per callback): a new sound, Stop, or a new volume.
    mutating func follow(_ play: SoundPlay) {
        if play.take != mix.take {
            // A new sound, or Stop: the one playing fades out (SoundMix). Cutting one on the speakers starts the
            // 150 ms hold.
            if mix.start(play) && muteMic { muteLeft = muteAfter }
            if mix.playing { muteMic = play.muteMic }
        }
        mix.follow(volume: play.volume)
    }

    // A sound playing on the Mac's speakers: the mic would hear it and send it into the call a second time, so the
    // mic fades out (10 ms) while it plays and for 150 ms after. Headphones: nothing is muted.
    mutating func muteIfNeeded(_ source: UnsafeMutablePointer<Float>, _ frames: Int) {
        let muted = (mix.playing && muteMic) || muteLeft > 0
        if muted || micGain < 1 {
            for i in 0..<frames {
                micGain = muted ? max(0, micGain - fadeStep) : min(1, micGain + fadeStep)
                source[i] *= micGain
            }
        }
        muteLeft = max(0, muteLeft - frames)
    }

    // One sample out: the voice (`shifting`: it went through the pitch change) with the sound mixed in.
    @inline(__always) mutating func out(_ voice: Float, shifting: Bool) -> Float {
        let playing = mix.active
        if playing || limitGain < 1 {
            var value = voice
            if playing {
                var ended = false
                value += mix.next(&ended)
                if ended && muteMic { muteLeft = muteAfter }  // played to the end
            }
            if limits {
                let size = abs(value)
                if playing && size * limitGain > Self.ceiling {  // after the sound it only lets go
                    limitGain = Self.ceiling / size
                    holdLeft = hold
                } else if holdLeft > 0 {
                    holdLeft -= 1
                } else if limitGain < 1 {
                    limitGain += (1 - limitGain) * release
                    if limitGain > 0.9999 { limitGain = 1 }
                }
                value *= limitGain
            }
            return softLimit(value)
        } else if shifting {
            // The shifted voice can peak a few dB above the mic: ease its loudest moments instead of cutting them
            // off at full scale (a hard cut sounds harsh and buzzy).
            return softLimit(voice)
        } else {
            return max(-1, min(1, voice))
        }
    }
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

// How much quieter the voice is made, for a pitch (half-steps, including "Deeper when slow") and a style.
// Rubber Band's short window (used for its low delay) makes the voice louder when it moves the voice's shape
// (formants) back down, which is what Natural does when going up: about 0.25 dB per half-step the shape is moved,
// measured on 4 recorded voices and 2 made-up ones against Rubber Band's own standard window, which keeps the level
// (for example +2.6 dB at +10, up to +6 dB on a high voice). Loud words could then go past full scale and sound harsh.
// So the output is turned down by that much: nothing in Cartoon (the shape isn't moved) or when going down.
// Off for `--render-voice --voice-preset old`.
func voiceLevelGain(halfSteps: Float, cartoon: Float) -> Float {
    let shapeMove = halfSteps * (1 - max(0, min(1, cartoon)))  // half-steps the shape is moved back down
    return shapeMove > 0 ? pow(10, -0.25 * shapeMove / 20) : 1
}

// The voice's Rubber Band shifter (used by the live chain and by the offline check --render-voice).
// A new style glides there over a short moment, so moving the slider never clicks. "Deeper when slow" adds an extra
// shift on top of the set amount, which glides too.
final class VoiceStretcher {
    let state: RubberBandState
    private(set) var halfSteps: Float  // the set amount
    private var cartoon: Float      // the style asked for
    private var cartoonNow: Float   // the style in use (glides toward `cartoon`)
    private let glideStep: Float    // how much the style may move per sample
    private(set) var slowDeeper: Bool
    private(set) var extra: Float = 0    // "Deeper when slow": half-steps added now (glides toward `extraTarget`)
    private var extraTarget: Float = 0
    private var extraStep: Float = 0     // how much `extra` moves per sample on its way
    private let extraGlide: Float        // each move of `extra` takes this many samples (0.3 s)
    private let levelFix: Bool           // turn the output down as voiceLevelGain says
    private var gain: Float = 1          // the output gain in use (follows `gainTarget` smoothly)
    private var gainTarget: Float = 1
    private let gainSmoothing: Float     // per sample, for a 30 ms glide

    init?(rate: Double, halfSteps: Float, cartoon: Float, slowDeeper: Bool = false, levelFix: Bool = true) {
        guard let made = rubberband_new(UInt32(rate), 1, voiceShifterOptions, 1, pow(2, Double(halfSteps) / 12)) else { return nil }
        state = made
        self.halfSteps = halfSteps
        self.cartoon = max(0, min(1, cartoon))
        cartoonNow = self.cartoon
        glideStep = Float(1 / (0.15 * rate))  // all the way from Natural to Cartoon in 0.15 s
        self.slowDeeper = slowDeeper
        extraGlide = Float(0.3 * rate)
        self.levelFix = levelFix
        gainSmoothing = Float(1 - exp(-1 / (0.03 * rate)))
        rubberband_set_max_process_size(state, 4096)
        rubberband_set_formant_scale(state, voiceFormantScale(halfSteps: halfSteps, cartoon: self.cartoon))
        aimGain()
        gain = gainTarget
    }

    deinit { rubberband_delete(state) }

    // The pitch in use: the set amount plus the extra shift.
    var pitch: Float { halfSteps + extra }

    // False when the voice goes through untouched (at 0, unless "Deeper when slow" is on).
    var running: Bool { halfSteps != 0 || slowDeeper }

    // Returns true when the shifter started fresh (coming back from normal pitch), so old sound should be dropped.
    func set(halfSteps new: Float) -> Bool {
        guard new != halfSteps else { return false }
        let fresh = !running && new != 0
        if fresh { rubberband_reset(state) }
        halfSteps = new
        if running { rubberband_set_pitch_scale(state, pow(2, Double(pitch) / 12)) }
        rubberband_set_formant_scale(state, voiceFormantScale(halfSteps: pitch, cartoon: cartoonNow))
        aimGain()
        if fresh { gain = gainTarget }  // nothing old is left to glide from
        return fresh
    }

    func set(cartoon new: Float) { cartoon = max(0, min(1, new)) }

    // Turns "Deeper when slow" on or off; either way the voice goes straight back to the set amount.
    // Returns true when the shifter started fresh (it wasn't in use at 0), so old sound should be dropped.
    func set(slowDeeper on: Bool) -> Bool {
        guard on != slowDeeper else { return false }
        let fresh = on && !running
        if fresh { rubberband_reset(state) }
        slowDeeper = on
        extra = 0
        extraTarget = 0
        guard running else { return fresh }
        rubberband_set_pitch_scale(state, pow(2, Double(pitch) / 12))
        rubberband_set_formant_scale(state, voiceFormantScale(halfSteps: pitch, cartoon: cartoonNow))
        aimGain()
        if fresh { gain = gainTarget }
        return fresh
    }

    // Where the extra shift should go (0 or lower). It glides there in 0.3 s.
    func set(extra target: Float) {
        guard slowDeeper, target != extraTarget else { return }
        extraTarget = target
        extraStep = abs(target - extra) / extraGlide
    }

    // Moves the style and the extra shift toward where they're heading; call once for each piece of `frames` samples.
    func glide(_ frames: Int) {
        let restyle = cartoonNow != cartoon, repitch = extra != extraTarget
        guard restyle || repitch else { return }
        if restyle {
            let step = glideStep * Float(frames)
            cartoonNow = abs(cartoon - cartoonNow) <= step ? cartoon : cartoonNow + (cartoon > cartoonNow ? step : -step)
        }
        if repitch {
            let step = extraStep * Float(frames)
            extra = abs(extraTarget - extra) <= step ? extraTarget : extra + (extraTarget > extra ? step : -step)
            rubberband_set_pitch_scale(state, pow(2, Double(pitch) / 12))
        }
        rubberband_set_formant_scale(state, voiceFormantScale(halfSteps: pitch, cartoon: cartoonNow))
        aimGain()
    }

    private func aimGain() {
        gainTarget = levelFix ? voiceLevelGain(halfSteps: pitch, cartoon: cartoonNow) : 1
    }

    // Takes up to `count` shifted samples from Rubber Band into `buffer`, at the level voiceLevelGain says
    // (gliding there), and returns how many it took.
    func retrieve(_ buffer: UnsafeMutablePointer<Float>, _ count: Int) -> Int {
        var output: UnsafeMutablePointer<Float>? = buffer
        let got = Int(rubberband_retrieve(state, &output, UInt32(count)))
        guard gain != 1 || gainTarget != 1 else { return got }  // Cartoon and going down: untouched
        for j in 0..<got {
            gain += (gainTarget - gain) * gainSmoothing
            buffer[j] *= gain
        }
        if abs(gain - gainTarget) < 1e-4 { gain = gainTarget }  // close enough (0.001 dB): stop gliding
        return got
    }
}

// "Deeper when slow": how fast someone is talking, and how much lower that makes the voice.
// Each syllable is a bump in loudness, so it counts bumps: the loudness of the voice's middle sounds (about
// 250-2500 Hz, where the vowels are), smoothed over 20 ms and looked at every 10 ms. A bump counts when it rises
// well above the quiet between words (the quietest moment of the last second), falls again, and comes at least
// 80 ms after the last one. The rate is the bumps in the last 1.2 seconds of talking. Pauses don't count as
// talking, so the rate stays where it was while it's quiet. The voice only moves once the rate has clearly changed
// (by more than one syllable in those 1.2 s, for more than a quarter of a second), so normal talking doesn't
// wobble. Going from normal to slow talking moves the voice all the way down in about 2 seconds.
// `listen` runs on the sound thread: it makes no memory and never waits.
final class SpeakingRate {
    static let depth: Float = 8         // half-steps lower when talking slowly
    static let slowRate: Float = 1.5    // syllables per second: this slow or slower gets all of `depth`
    static let normalRate: Float = 3    // this fast or faster: no change (in between: part of `depth`)

    private(set) var rate = SpeakingRate.normalRate  // syllables per second, as measured
    private(set) var used = SpeakingRate.normalRate  // the rate the voice follows (moves only after a clear change)
    var extra: Float {  // half-steps to add: 0 down to -depth
        -Self.depth * max(0, min(1, (Self.normalRate - used) / (Self.normalRate - Self.slowRate)))
    }

    // Everything below counts in steps of 10 ms.
    private let bumpRise: Float = 2       // dB a bump must rise and fall
    private let bumpAboveQuiet: Float = 9 // dB a bump's top must be above the quiet level
    private let talkAboveQuiet: Float = 6 // dB above the quiet level that counts as talking
    private let quietest: Float = -55     // dB: anything quieter is never talking
    private let bumpGap = 8               // at least 80 ms between bumps
    private let talkHold = 25             // a pause still counts as talking for its first 0.25 s
    private let windowSteps = 120         // the rate counts the last 1.2 s of talking
    private let firstSteps = 60           // ...once there has been 0.6 s of it
    private let moveAfter = 25            // the rate must stay clearly changed this long (0.25 s) to move the voice
    private let moveBy: Float = 0.9       // ...by more than this (syllables per second): one syllable in 1.2 s is 0.83
    private let stepLength: Int           // samples in 10 ms
    private let smoothing: Double         // for the 20 ms smoothing
    private let b0, a1, a2: Double        // the 250-2500 Hz band-pass filter
    private let quietPieces: UnsafeMutablePointer<Float>  // the quietest level in each 100 ms of the last second
    private let window: UnsafeMutablePointer<UInt8>       // bumps in each 10 ms of the last 1.2 s of talking

    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    private var energy = 0.0
    private var inStep = 0
    private var step = 0
    private var piece = 0, inPiece = 0, pieceQuietest = Float.infinity
    private var rising = true
    private var top = -Float.infinity, bottom = Float.infinity
    private var lastBump = -1_000_000, lastLoud = -1_000_000
    private var newBumps = 0
    private var windowAt = 0, windowFilled = 0, windowBumps = 0
    private var changedFor = 0

    init(sampleRate: Double) {
        stepLength = max(1, Int((sampleRate * 0.01).rounded()))
        smoothing = 1 - exp(-1 / (0.02 * sampleRate))
        // Band-pass around 790 Hz, about 3.3 octaves wide (Robert Bristow-Johnson's audio EQ cookbook).
        let w = 2 * Double.pi * min(790, sampleRate * 0.4) / sampleRate
        let alpha = sin(w) / (2 * 0.35)
        b0 = alpha / (1 + alpha)
        a1 = -2 * cos(w) / (1 + alpha)
        a2 = (1 - alpha) / (1 + alpha)
        quietPieces = .allocate(capacity: 10)
        window = .allocate(capacity: windowSteps)
        reset()
    }

    deinit {
        quietPieces.deallocate()
        window.deallocate()
    }

    // Starts over, as if nobody had talked yet.
    func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
        energy = 0
        inStep = 0
        step = 0
        quietPieces.update(repeating: .infinity, count: 10)
        piece = 0; inPiece = 0; pieceQuietest = .infinity
        rising = true; top = -.infinity; bottom = .infinity
        lastBump = -1_000_000; lastLoud = -1_000_000
        newBumps = 0
        window.update(repeating: 0, count: windowSteps)
        windowAt = 0; windowFilled = 0; windowBumps = 0
        changedFor = 0
        rate = Self.normalRate
        used = Self.normalRate
    }

    // Takes the next piece of the mic's sound.
    func listen(_ samples: UnsafePointer<Float>, _ count: Int) {
        for i in 0..<count {
            let x = Double(samples[i])
            let y = b0 * (x - x2) - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            energy += smoothing * (y * y - energy)
            inStep += 1
            if inStep == stepLength {
                inStep = 0
                nextStep()
            }
        }
    }

    private func nextStep() {
        step += 1
        // Tiny numbers are slow on Intel Macs: round them off (-120 dB is far below any mic).
        energy = max(energy, 1e-12)
        if abs(y1) < 1e-15 { y1 = 0 }
        if abs(y2) < 1e-15 { y2 = 0 }
        let level = Float(10 * log10(energy))

        // The quiet level: the quietest moment of the last second.
        pieceQuietest = min(pieceQuietest, level)
        inPiece += 1
        if inPiece == 10 {
            quietPieces[piece] = pieceQuietest
            piece = (piece + 1) % 10
            inPiece = 0
            pieceQuietest = .infinity
        }
        var quiet = pieceQuietest
        for p in 0..<10 { quiet = min(quiet, quietPieces[p]) }

        // Bumps: up by `bumpRise`, then down by `bumpRise`.
        if rising {
            top = max(top, level)
            if level < top - bumpRise {
                if top > quiet + bumpAboveQuiet && top > quietest && step - lastBump >= bumpGap {
                    newBumps += 1
                    lastBump = step
                }
                rising = false
                bottom = level
            }
        } else {
            bottom = min(bottom, level)
            if level > bottom + bumpRise {
                rising = true
                top = level
            }
        }

        if level > quiet + talkAboveQuiet && level > quietest { lastLoud = step }
        guard step - lastLoud <= talkHold else { return }  // quiet: everything stays as it is

        // Talking: these 10 ms join the window.
        let added = min(newBumps, 255)
        newBumps = 0
        windowBumps += added - Int(window[windowAt])
        window[windowAt] = UInt8(added)
        windowAt = (windowAt + 1) % windowSteps
        windowFilled = min(windowFilled + 1, windowSteps)
        if windowFilled >= firstSteps { rate = Float(windowBumps) / (Float(windowFilled) * 0.01) }
        if abs(rate - used) > moveBy {
            changedFor += 1
            if changedFor >= moveAfter {
                used = rate
                changedFor = 0
            }
        } else {
            changedFor = 0
        }
    }
}

// What "Deeper when slow" is doing, for the command-line test.
struct SlowReading {
    var rate: Float = SpeakingRate.normalRate
    var extra: Float = 0
}

// One running voice chain: a private combined device of [real mic + hidden side of Pitch Shift Mic] with one
// sound callback, so both run on the mic's clock (Core Audio corrects the tiny clock difference).
final class VoiceChain {
    let micName: String
    let micUID: String
    let devices: [AudioDeviceID]  // the mic and both sides of Pitch Shift Mic, as Core Audio numbered them
    let sampleRate: Double
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let stretcher: VoiceStretcher
    private var shifter: RubberBandState { stretcher.state }
    private let params: OSAllocatedUnfairLock<VoiceParams>
    private var applied: VoiceParams
    private let micOutputStreams: Int
    // Sound-thread buffers, made once up front (no memory is made on the sound thread).
    // Callbacks are small (128 samples), so Rubber Band gets them whole; pieces of up to 4096 only matter for a
    // device that insists on big callbacks, and the size of the pieces doesn't change the delay.
    private let maxPiece = 4096  // the most Rubber Band is given or asked for at once
    private let piece: UnsafeMutablePointer<Float>
    private let ring: VoiceRing  // shifted sound waiting to go out
    private let speaking: SpeakingRate  // "Deeper when slow"
    // Sound effects (Soundboard): mixed in after the voice, never through the mic or the pitch change.
    private let sounds: OSAllocatedUnfairLock<SoundPlay>
    private var callMix: CallMix
    // For the command-line test: replaces the mic with a made-up sound.
    var testSource: ((UnsafeMutablePointer<Float>, Int) -> Void)?
    private(set) var firstInputTime: UInt64 = 0  // host time of the first mic sample (for the delay test)
    private(set) var blockInputTime: UInt64 = 0  // host time of the current callback's first mic sample (for the delay test)
    let slowReading = OSAllocatedUnfairLock(initialState: SlowReading())  // for the test (written without waiting)
    // Counts for --test-voice --watch, copied out after each callback without ever waiting on the sound thread.
    let stats = OSAllocatedUnfairLock(initialState: VoiceStats())
    private var counts = VoiceStats()
    private var overloadListener: Listener?

    init(mic: AudioDeviceID, feed: AudioDeviceID, params: OSAllocatedUnfairLock<VoiceParams>, sounds: OSAllocatedUnfairLock<SoundPlay>,
         bufferFrames: UInt32? = nil, testSource: ((UnsafeMutablePointer<Float>, Int) -> Void)? = nil) throws {
        self.testSource = testSource  // set before the sound starts, so a test never sends the real mic
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
        guard let made = VoiceStretcher(rate: rate, halfSteps: start.halfSteps, cartoon: start.cartoon, slowDeeper: start.slowDeeper) else {
            throw Problem(message: "Can't use \(micName).")
        }
        stretcher = made
        speaking = SpeakingRate(sampleRate: rate)
        self.sounds = sounds
        callMix = CallMix(rate: rate, take: sounds.withLock { $0.take })  // a sound already playing when the chain starts isn't sent
        piece = .allocate(capacity: maxPiece)
        ring = VoiceRing(rate: rate)

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
            self.blockInputTime = inputTime.pointee.mHostTime
            self.render(input, output)
        }
        guard status == noErr, let proc else {
            throw Problem(message: "Can't use \(micName).")
        }
        turnOffMicOutputs(proc)
        // Small callbacks: the sound waits one callback on the way in and one on the way out, so 128 samples
        // (2.7 ms at 48 kHz) instead of the usual 512 (10.7 ms) cuts about 16 ms. Only this chain's own callbacks
        // change; other apps using the same mic keep theirs.
        var frames = bufferFrames ?? (rate > 48000 ? 256 : 128)
        let range = getValue(aggregate, kAudioDevicePropertyBufferFrameSizeRange, default: AudioValueRange(mMinimum: 0, mMaximum: 0))
        if range.mMaximum > 0 { frames = UInt32(min(max(Double(frames), range.mMinimum), range.mMaximum)) }
        var sizeAddress = address(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(aggregate, &sizeAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        overloadListener = Listener(aggregate, kAudioDeviceProcessorOverload) { [weak self] in
            self?.stats.withLock { $0.overloads += 1 }
        }
        guard AudioDeviceStart(aggregate, proc) == noErr else {
            throw Problem(message: "Can't use \(micName).")
        }
    }

    // Where the delay comes from (for --test-voice --watch), in milliseconds.
    var delayParts: String {
        let rate = sampleRate
        func ms(_ frames: UInt32) -> String { String(format: "%.1f", Double(frames) / rate * 1000) }
        func io(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String {
            let latency = getValue(id, kAudioDevicePropertyLatency, scope, default: UInt32(0))
            let safety = getValue(id, kAudioDevicePropertySafetyOffset, scope, default: UInt32(0))
            let buffer = getValue(id, kAudioDevicePropertyBufferFrameSize, scope, default: UInt32(0))
            let stream = getArray(id, kAudioDevicePropertyStreams, scope, of: AudioStreamID.self).first
                .map { getValue($0, kAudioStreamPropertyLatency, default: UInt32(0)) } ?? 0
            return "buffer \(buffer) (\(ms(buffer)) ms), latency \(ms(latency + stream)) ms, safety \(ms(safety)) ms"
        }
        let pad = rubberband_get_preferred_start_pad(shifter), start = rubberband_get_start_delay(shifter)
        return """
            combined device: in \(io(aggregate, kAudioDevicePropertyScopeInput)) | out \(io(aggregate, kAudioDevicePropertyScopeOutput))
              mic \(micName): \(io(devices[0], kAudioDevicePropertyScopeInput))
              hidden feed: \(io(devices[2], kAudioDevicePropertyScopeOutput)); Pitch Shift Mic: \(io(devices[1], kAudioDevicePropertyScopeInput))
              Rubber Band: start delay \(ms(start)) ms, start pad \(ms(pad)) ms, pieces up to \(maxPiece)
              waiting sound: starts at one callback + \(ms(UInt32(ring.startCushion))) ms, then kept \(ms(UInt32(ring.margin))) ms above the lowest point
            """
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
        let pitchBefore = stretcher.pitch
        stretcher.glide(frames)
        if stretcher.pitch != pitchBefore { ring.amountChanged() }  // "Deeper when slow" is moving the pitch
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

        // The Soundboard's sound; on the Mac's speakers the mic is muted while it plays (CallMix).
        if let play = sounds.withLockIfAvailable({ $0 }) { callMix.follow(play) }
        callMix.muteIfNeeded(source, frames)

        if applied.slowDeeper {
            speaking.listen(source, frames)
            stretcher.set(extra: speaking.extra)
            let reading = SlowReading(rate: speaking.rate, extra: stretcher.extra)
            slowReading.withLockIfAvailable { $0 = reading }
        }

        // At normal pitch the mic goes straight out; otherwise the shifted sound replaces it in the same buffer.
        let shifting = stretcher.running
        if shifting {
            shift(source, frames)
            ring.read(into: source, frames)
        }
        for i in 0..<frames {
            let value = callMix.out(applied.silent ? 0 : source[i], shifting: shifting)
            for b in micOutputStreams..<outs.count {
                guard let d = outs[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let ch = Int(outs[b].mNumberChannels)
                for c in 0..<ch { d[i * ch + c] = value }
            }
        }
        publish(frames, shifting: shifting)
    }

    // Copies the counts out for --watch (never waits: if the main thread is reading, this callback is left out).
    private func publish(_ frames: Int, shifting: Bool) {
        counts.frames = frames
        counts.ring = ring.count
        counts.sending = shifting && !ring.waiting
        counts.delay = counts.sending
            ? counts.given - counts.returned + ring.count + Int(rubberband_get_start_delay(shifter)) - Int(rubberband_get_preferred_start_pad(shifter))
            : 0
        counts.margin = ring.margin
        counts.dryOuts = ring.dryOuts
        counts.trims = ring.trims
        counts.trimmed = ring.trimmed
        counts.replays = ring.replays
        counts.replayed = ring.replayed
        let now = counts
        stats.withLockIfAvailable { s in
            let overloads = s.overloads, lowest = s.lowest
            s = now
            s.overloads = overloads
            s.lowest = now.sending ? min(lowest, now.ring) : lowest
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
        counts.given += frames
        while true {
            let ready = min(Int(rubberband_available(shifter)), maxPiece)
            if ready <= 0 { break }
            let got = stretcher.retrieve(piece, ready)
            if got <= 0 { break }
            counts.returned += got
            ring.write(piece, got)
        }
        ring.settle(frames)
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
        if latest.slowDeeper && !applied.slowDeeper { speaking.reset() }
        let changed = latest.halfSteps != stretcher.halfSteps || latest.slowDeeper != stretcher.slowDeeper
        let restarted = stretcher.set(slowDeeper: latest.slowDeeper)
        if stretcher.set(halfSteps: latest.halfSteps) || restarted {  // coming back from normal pitch: start fresh
            counts.given = 0
            counts.returned = 0
            ring.reset()
        } else if changed && stretcher.running {
            ring.amountChanged()
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

// What the voice chain is doing (for --test-voice --watch). Sizes are in samples.
struct VoiceStats {
    var frames = 0           // samples per callback
    var ring = 0             // shifted sound waiting to go out, after the last callback
    var lowest = Int.max     // the least waiting since the watch last looked (reset by the reader)
    var sending = false      // shifted sound is going out (not filling up, not at normal pitch)
    var delay = 0            // Rubber Band + the ring, from a mic sample to it going out
    var given = 0            // samples given to Rubber Band
    var returned = 0         // samples Rubber Band gave back
    var margin = 0           // sound kept above the lowest point
    var dryOuts = 0          // the ring ran dry (a short gap, faded out and back in)
    var trims = 0            // extra waiting sound dropped (crossfaded) to cut the delay
    var trimmed = 0
    var replays = 0          // a few ms sent again (crossfaded) because the ring got very low
    var replayed = 0
    var overloads = 0        // Core Audio said a callback came too late
}

enum VoiceState: Equatable {
    case off
    case noDriver   // Pitch Shift Mic isn't installed
    case noMic      // no microphone found
    case ready      // on, waiting for an app to listen
    case live       // running
    case problem(String)
}

// Decides when the voice chain runs, which mic it uses, and rebuilds it when devices change. It runs while "Your
// voice" is on, and also while the Soundboard is open with the voice off: then the mic goes into Pitch Shift Mic
// unchanged (no pitch change, so Rubber Band isn't used and there's almost no delay), with the sounds mixed in.
final class VoiceShifter {
    var halfSteps: Float { didSet { pushParams() } }
    var cartoon: Float { didSet { pushParams() } }  // voice style: 0 = Natural, 1 = Cartoon
    var slowDeeper: Bool { didSet { pushParams() } }  // "Deeper when slow"
    var micUID: String? { didSet { if oldValue != micUID { rebuild() } } }  // nil = the Mac's default mic
    var onChange: () -> Void = {}
    var testSource: ((UnsafeMutablePointer<Float>, Int) -> Void)?
    var testBufferFrames: UInt32?  // --test-voice --buffer N: the callback size to ask for
    private(set) var state: VoiceState = .off
    private(set) var listening = false  // some app is using Pitch Shift Mic right now
    private(set) var chain: VoiceChain?
    let params: OSAllocatedUnfairLock<VoiceParams>
    let sounds = OSAllocatedUnfairLock(uncheckedState: SoundPlay())  // the Soundboard's sound, for the chain
    private var running = false      // the chain may run (the voice is on, or the Soundboard is open)
    private var voiceSwitch = false  // "Your voice" is on
    private(set) var runsForSounds = false  // the Soundboard is open (with the voice off: no pitch change)
    private var holdCount = 0
    private var listeners: [Listener] = []
    private var micListeners: [Listener] = []
    private var stopLater: DispatchWorkItem?
    private let debounce = Debouncer(0.3)
    private var rebuilds: [Date] = []

    init(halfSteps: Float, cartoon: Float, slowDeeper: Bool = false, micUID: String?) {
        self.halfSteps = halfSteps
        self.cartoon = cartoon
        self.slowDeeper = slowDeeper
        self.micUID = micUID
        params = OSAllocatedUnfairLock(initialState: VoiceParams(halfSteps: halfSteps, cartoon: cartoon, slowDeeper: slowDeeper, silent: false))
    }

    var isOn: Bool { voiceSwitch }
    var currentMic: AudioDeviceID? { Mics.resolve(micUID) }

    // "Your voice" on.
    func start() {
        guard !voiceSwitch else { return }
        voiceSwitch = true
        begin()
    }

    // "Your voice" off. With the Soundboard open, the chain keeps going with no pitch change.
    func stop() {
        guard voiceSwitch else { return }
        voiceSwitch = false
        pushParams()
        if runsForSounds { onChange() } else { end() }
    }

    // The Soundboard opened or closed: while it's open the chain runs even with the voice off.
    func keepForSounds(_ on: Bool) {
        guard on != runsForSounds else { return }
        runsForSounds = on
        if on { begin() } else if !voiceSwitch { end() }
    }

    // Everything off (quitting).
    func stopAll() {
        runsForSounds = false
        stop()
        end()
    }

    private func begin() {
        pushParams()
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

    private func end() {
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

    // With the voice off (only the Soundboard running) the voice goes through unchanged.
    private func pushParams() {
        let steps = voiceSwitch ? halfSteps : 0, cartoon = cartoon, slowDeeper = voiceSwitch && slowDeeper
        params.withLock { $0.halfSteps = steps; $0.cartoon = cartoon; $0.slowDeeper = slowDeeper }
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
                    let made = try VoiceChain(mic: mic, feed: feed, params: params, sounds: sounds,
                                              bufferFrames: testBufferFrames, testSource: testSource)
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

    // What has been recorded so far, from `start` on (for --test-voice --watch; may lag a callback behind).
    func recorded(from start: Int) -> [Float] {
        let end = count
        return start < end ? Array(UnsafeBufferPointer(start: samples + start, count: end - start)) : []
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
// ((seconds, style) pairs), to check that it changes smoothly. With `slowDeeper` it prints the speaking rate and
// the extra shift once per second of sound. `levelFix: false` renders it as before the level fix
// (`--voice-preset old`, see voiceLevelGain), so old and new can be compared.
func renderVoiceFile(input: String, output: String, halfSteps: Float, cartoon: Float, changes: [(Double, Float)],
                     slowDeeper: Bool = false, levelFix: Bool = true) throws {
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
    if halfSteps != 0 || slowDeeper {
        guard let stretcher = VoiceStretcher(rate: rate, halfSteps: halfSteps, cartoon: cartoon, slowDeeper: slowDeeper,
                                             levelFix: levelFix) else {
            throw Problem(message: "Could not start Rubber Band.")
        }
        let speaking = SpeakingRate(sampleRate: rate)
        var nextReport = 1
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
            if slowDeeper {
                chunk.withUnsafeBufferPointer { speaking.listen($0.baseAddress!, block) }
                stretcher.set(extra: speaking.extra)
                if position + block >= nextReport * Int(rate) && position + block <= length {
                    print(String(format: "%3ds  rate %.1f syllables/s  extra %+.1f half-steps", nextReport, speaking.rate, stretcher.extra))
                    nextReport += 1
                }
            }
            chunk.withUnsafeBufferPointer { p in
                var pointer: UnsafePointer<Float>? = p.baseAddress
                rubberband_process(stretcher.state, &pointer, UInt32(block), 0)
            }
            position += block
            while rubberband_available(stretcher.state) > 0 {
                let want = min(Int(rubberband_available(stretcher.state)), piece.count)
                let got = piece.withUnsafeMutableBufferPointer { stretcher.retrieve($0.baseAddress!, want) }
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
