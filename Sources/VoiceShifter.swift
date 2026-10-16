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
// `changer` points into VoiceLibrary's table, which lives as long as the app (so the sound thread may keep reading it).
struct VoiceParams: @unchecked Sendable {
    var halfSteps: Float
    var cartoon: Float      // voice style: 0 = Natural, 1 = Cartoon, in between = a blend
    var slowDeeper = false  // "Deeper when slow": talking slowly makes the voice lower
    var silent: Bool        // during Test playback, so the replay isn't sent into a live call
    var changer: UnsafePointer<VoiceChangerVoice>? = nil  // the voice changer's voice (nil = off)
    var strength: Float = 1                               // the voice changer's strength, 0 ... 1
}

// The voice changer card's settings: on/off, which voice (VoiceLibrary id), how strong, and Realistic (AI) or not.
struct ChangerSettings: Equatable {
    var on = false
    var voiceID = "woman"
    var strength: Float = 1
    var realistic = false
}

// What the voice changer is doing, for the window.
enum ChangerState: Equatable {
    case off
    case natural                 // Natural mode is playing
    case loading                 // Realistic mode is loading its models (Natural plays meanwhile)
    case realistic               // the AI voice is playing
    case fallback(misses: Int)   // Realistic, but some pieces came late and Natural filled in
    case unavailable(String)     // Realistic can't run here (for example "needs Apple silicon"); Natural plays
}

// What --render-voice and --test-voice ask of the voice changer.
struct ChangerOptions {
    var voice: UnsafePointer<VoiceChangerVoice>
    var strength: Float = 1
    var tune: [(String, Float)] = []  // --changer-tune "key=value,..."
    var stats = false                 // --changer-stats: print what it does once a second
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
struct SoundMix {
    private(set) var take: Int
    private let rate: Double
    private let fadeStep: Float  // 10 ms from full to nothing
    private let volumeGlide: Float  // the part of the way to a new volume taken each sample (20 ms smoothing)
    private var sound: UnsafePointer<Float>?  // the one playing
    private var count = 0
    private var at = 0
    private var gain: Float = 1    // its volume now
    private var volume: Float = 1  // its volume as set (`gain` glides there)
    private var fading: UnsafePointer<Float>?  // one that was stopped or replaced
    private var fadingCount = 0
    private var fadingAt = 0
    private var fadingGain: Float = 0
    private var fadingVolume: Float = 1

    // `take`: the SoundPlay's take now (a sound already playing isn't picked up).
    init(rate: Double, take: Int) {
        self.rate = rate
        self.take = take
        fadeStep = Float(1 / (0.01 * rate))
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
            fadingGain = 1
            fadingVolume = gain
        }
        sound = nil
        guard let samples = play.samples, play.count > 0, play.rate == rate else { return cut }
        sound = samples
        count = play.count
        at = 0
        gain = play.volume
        volume = play.volume
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
            at += 1
            if at >= count {
                sound = nil
                ended = true
            }
        }
        if let old = fading {
            fadingGain -= fadeStep
            if fadingGain > 0 && fadingAt < fadingCount {
                value += old[fadingAt] * fadingGain * fadingVolume
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

// The level fix (voiceLevelGain) for any pitch and voice shape: `shapeMove` is how many half-steps the voice's shape
// is moved back down against the pitch (pitch minus shape move). Used while the voice changer is on.
func voiceLevelGain(shapeMove: Float) -> Float {
    shapeMove > 0 ? pow(10, -0.25 * shapeMove / 20) : 1
}

// The voice's Rubber Band shifter (used by the live chain and by the offline check --render-voice).
// A new style glides there over a short moment, so moving the slider never clicks. "Deeper when slow" adds an extra
// shift on top of the set amount, which glides too.
// While the voice changer is on, its pitch and voice shape (set every callback from voicechanger_analyse) replace
// the set amount and style; turning it on or off blends from one to the other over 0.15 s. With the changer off
// nothing here changes (the same Rubber Band calls as before).
// The voice changer's Natural mode, and the plain shift from 6 half-steps up or down, use the pulse shifter
// (Sources/Voice/PulseShifter.h) instead of Rubber Band: Rubber Band smears the voice's pulses into a steady buzz at
// big moves (the changer moves 8 to 10 half-steps), the pulse shifter keeps them whole, with less delay. It takes
// over (and hands back) at once, starting fresh like a shift leaving 0, when the changer is turned on or off or the
// set amount crosses 6 ("Deeper when slow" doesn't count, so it never switches in the middle of a word). Below 6
// with the changer off nothing changes (the same Rubber Band calls as before). `--changer-tune naturalEngine=0`
// keeps Rubber Band for everything.
final class VoiceStretcher {
    let state: RubberBandState
    private let pulse: OpaquePointer?  // the pulse shifter (nil: Rubber Band only)
    private(set) var pulseOn = false   // the pulse shifter is in use now
    private let pulsePlainFrom: Float  // the plain shift uses it from this many half-steps (set amount, up or down)
    // The changer's voice shape move is made this much bigger (in log terms) for the pulse shifter: moving whole
    // pulses keeps more of the speaker's own voice than Rubber Band, so the same shape scale sounded less changed
    // (VCTK men -> Woman: judged a woman 88 % at 1.21 vs Rubber Band's 95 %; at 1.21^1.4 100 %).
    private let pulseShapePower: Double
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
    // The voice changer.
    private(set) var changerOn = false
    private var blend: Float = 0          // 0 = the set amount and style, 1 = the voice changer's pitch and shape
    private let blendStep: Float          // per sample: the whole way in 0.15 s
    private var changerPitch: Double = 1  // the changer's pitch scale (from voicechanger_analyse)
    private var changerShape: Double = 1  // ... and voice shape (formant) scale, before dividing by the pitch

    // `changer`: start with the voice changer fully on (offline renders; a new chain has nothing to blend from).
    // `tune`: --changer-tune settings; naturalEngine (1 = pulse shifter, the default; 0 = Rubber Band), pulseShapePow
    // and the pulse shifter's own keys (pulseLatencyMs, ...) are used here.
    init?(rate: Double, halfSteps: Float, cartoon: Float, slowDeeper: Bool = false, levelFix: Bool = true, changer: Bool = false,
          tune: [(String, Float)] = []) {
        guard let made = rubberband_new(UInt32(rate), 1, voiceShifterOptions, 1, pow(2, Double(halfSteps) / 12)) else { return nil }
        state = made
        if (tune.last { $0.0 == "naturalEngine" }?.1 ?? 1) != 0, let shifter = pulseshifter_new(rate) {
            for (key, value) in tune { _ = pulseshifter_tune(shifter, key, value) }
            pulse = shifter
        } else {
            pulse = nil
        }
        pulseShapePower = Double(tune.last { $0.0 == "pulseShapePow" }?.1 ?? 1.4)
        pulsePlainFrom = levelFix ? 6 : .infinity  // `--voice-preset old` renders as before: Rubber Band only
        self.halfSteps = halfSteps
        self.cartoon = max(0, min(1, cartoon))
        cartoonNow = self.cartoon
        glideStep = Float(1 / (0.15 * rate))  // all the way from Natural to Cartoon in 0.15 s
        self.slowDeeper = slowDeeper
        extraGlide = Float(0.3 * rate)
        self.levelFix = levelFix
        gainSmoothing = Float(1 - exp(-1 / (0.03 * rate)))
        blendStep = Float(1 / (0.15 * rate))
        rubberband_set_max_process_size(state, 4096)
        rubberband_set_formant_scale(state, voiceFormantScale(halfSteps: halfSteps, cartoon: self.cartoon))
        if changer {
            changerOn = true
            pulseOn = pulse != nil
            blend = 1
            applyChanger()
        } else if plainWantsPulse {
            pulseOn = true
            applyPlain(repitch: true)
        } else {
            aimGain()
        }
        gain = gainTarget
    }

    deinit {
        rubberband_delete(state)
        if let pulse { pulseshifter_delete(pulse) }
    }

    // The pitch in use: the set amount plus the extra shift.
    var pitch: Float { halfSteps + extra }

    // The voice changer is on, or still blending out.
    var changerActive: Bool { changerOn || blend > 0 }

    // False when the voice goes through untouched (at 0, unless "Deeper when slow" or the voice changer is on).
    var running: Bool { halfSteps != 0 || slowDeeper || changerActive }

    // The plain shift's set amount is big enough for the pulse shifter.
    private var plainWantsPulse: Bool { pulse != nil && abs(halfSteps) >= pulsePlainFrom }

    // Gives the set amount and style to the shifter in use (not while the changer sets them). For Rubber Band these
    // are the same calls as before the pulse shifter; it gets the pitch only when `repitch`.
    private func applyPlain(repitch: Bool) {
        if pulseOn, let pulse {  // the pulse shifter keeps the loudness itself
            let scale = pow(2, Double(pitch) / 12)
            pulseshifter_set(pulse, scale, pow(scale, Double(min(max(cartoonNow, 0), 1))))  // the shape moves pitch^style
            gainTarget = 1
            return
        }
        if repitch { rubberband_set_pitch_scale(state, pow(2, Double(pitch) / 12)) }
        rubberband_set_formant_scale(state, voiceFormantScale(halfSteps: pitch, cartoon: cartoonNow))
        aimGain()
    }

    // Returns true when the shifter started fresh (coming back from normal pitch), so old sound should be dropped.
    func set(halfSteps new: Float) -> Bool {
        guard new != halfSteps else { return false }
        let fresh = !running && new != 0
        if fresh { rubberband_reset(state) }
        halfSteps = new
        if changerActive {  // the changer sets Rubber Band (the amount only counts while blending)
            applyChanger()
            return fresh
        }
        if let pulse, plainWantsPulse != pulseOn {  // the amount crossed 6: the other shifter takes over, fresh
            pulseOn = !pulseOn
            if pulseOn { pulseshifter_reset(pulse) } else { rubberband_reset(state) }
            applyPlain(repitch: true)
            gain = gainTarget
            return true
        }
        if pulseOn {
            applyPlain(repitch: true)
            return fresh
        }
        if running { rubberband_set_pitch_scale(state, pow(2, Double(pitch) / 12)) }
        rubberband_set_formant_scale(state, voiceFormantScale(halfSteps: pitch, cartoon: cartoonNow))
        aimGain()
        if fresh { gain = gainTarget }  // nothing old is left to glide from
        return fresh
    }

    // Turns the voice changer on or off (it blends in or out over 0.15 s). Returns true when the shifter started
    // fresh (it wasn't in use at 0), so old sound should be dropped.
    func set(changer on: Bool) -> Bool {
        guard on != changerOn else { return false }
        if let pulse {  // the pulse shifter takes over, or hands back to the plain shift, at once
            changerOn = on
            blend = on ? 1 : 0
            pulseOn = on || plainWantsPulse
            if pulseOn { pulseshifter_reset(pulse) } else { rubberband_reset(state) }
            if on { applyChanger() } else { applyPlain(repitch: true) }
            gain = gainTarget
            return true
        }
        let fresh = on && !running
        if fresh { rubberband_reset(state) }
        changerOn = on
        if fresh {
            blend = 1  // nothing old to blend from
            applyChanger()
            gain = gainTarget
        }
        return fresh
    }

    // The voice changer's pitch scale and Rubber Band formant scale for this callback (from voicechanger_analyse).
    func set(changerPitch pitchScale: Double, formantScale: Double) {
        changerPitch = pitchScale > 0 ? pitchScale : 1
        changerShape = formantScale > 0 ? formantScale * changerPitch : 1
        if changerActive { applyChanger() }
    }

    // Sets Rubber Band from the blend of the set amount/style and the voice changer: half-steps and the log of the
    // voice shape are blended, then the shape is divided by the pitch (Rubber Band counts it on top of the pitch).
    private func applyChanger() {
        let plainSteps = Double(pitch)
        let plainShapeLog = log(2) * plainSteps / 12 * Double(min(max(cartoonNow, 0), 1))  // the shape moves pitch^cartoon
        let b = Double(blend)
        let steps = (1 - b) * plainSteps + b * 12 * log2(changerPitch)
        let shapeLog = (1 - b) * plainShapeLog + b * log(changerShape)
        let scale = pow(2, steps / 12)
        if pulseOn, let pulse {  // keeps the loudness itself
            pulseshifter_set(pulse, scale, exp(shapeLog * pulseShapePower))
            gainTarget = 1
            return
        }
        rubberband_set_pitch_scale(state, scale)
        rubberband_set_formant_scale(state, exp(shapeLog) / scale)
        gainTarget = levelFix ? voiceLevelGain(shapeMove: Float(steps - 12 * shapeLog / log(2))) : 1
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
        if changerActive {  // the changer sets Rubber Band (it gets the extra shift from the chain)
            applyChanger()
            return fresh
        }
        applyPlain(repitch: true)
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
    // While the voice changer is on (or blending), this only moves the values: set(changerPitch:formantScale:),
    // called right after for the same callback, sets Rubber Band.
    func glide(_ frames: Int) {
        if changerActive {
            let step = Float(frames)
            cartoonNow = abs(cartoon - cartoonNow) <= glideStep * step ? cartoon : cartoonNow + (cartoon > cartoonNow ? glideStep : -glideStep) * step
            extra = abs(extraTarget - extra) <= extraStep * step ? extraTarget : extra + (extraTarget > extra ? extraStep : -extraStep) * step
            let goal: Float = changerOn ? 1 : 0
            blend = abs(goal - blend) <= blendStep * step ? goal : blend + (goal > blend ? blendStep : -blendStep) * step
            if !changerActive { applyPlain(repitch: true) }  // fully blended out: back to the set amount and style
            return
        }
        let restyle = cartoonNow != cartoon, repitch = extra != extraTarget
        guard restyle || repitch else { return }
        if restyle {
            let step = glideStep * Float(frames)
            cartoonNow = abs(cartoon - cartoonNow) <= step ? cartoon : cartoonNow + (cartoon > cartoonNow ? step : -step)
        }
        if repitch {
            let step = extraStep * Float(frames)
            extra = abs(extraTarget - extra) <= step ? extraTarget : extra + (extraTarget > extra ? step : -step)
        }
        applyPlain(repitch: repitch)
    }

    private func aimGain() {
        guard !changerActive else { return }  // the changer's level is set in applyChanger
        if pulseOn {  // the pulse shifter keeps the loudness itself
            gainTarget = 1
            return
        }
        gainTarget = levelFix ? voiceLevelGain(halfSteps: pitch, cartoon: cartoonNow) : 1
    }

    // Takes up to `count` shifted samples from Rubber Band into `buffer`, at the level voiceLevelGain says
    // (gliding there), and returns how many it took.
    func retrieve(_ buffer: UnsafeMutablePointer<Float>, _ count: Int) -> Int {
        if pulseOn, let pulse { return Int(pulseshifter_retrieve(pulse, buffer, Int32(count))) }
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

    // Gives `count` mic samples to the shifter in use.
    func process(_ samples: UnsafePointer<Float>, _ count: Int) {
        if pulseOn, let pulse {
            pulseshifter_process(pulse, samples, Int32(count))
            return
        }
        var input: UnsafePointer<Float>? = samples
        rubberband_process(state, &input, UInt32(count), 0)
    }

    // How many shifted samples are ready.
    var available: Int { pulseOn ? Int(pulseshifter_available(pulse)) : Int(rubberband_available(state)) }

    // Samples to drop from the start so the output lines up with the input (Rubber Band's start delay; the pulse
    // shifter's output is lined up already).
    var startSkip: Int { pulseOn ? 0 : Int(rubberband_get_start_delay(state)) }

    // The part of the delay the shifter adds besides what it holds (Rubber Band's start delay minus its start pad).
    var heldBack: Int { pulseOn ? 0 : Int(rubberband_get_start_delay(state)) - Int(rubberband_get_preferred_start_pad(state)) }

    // For --test-voice --watch.
    var delayNote: String {
        if pulseOn { return "pulse shifter, fixed delay \(pulseshifter_latency(pulse)) samples" }
        return "Rubber Band: start delay \(rubberband_get_start_delay(state)) samples, start pad \(rubberband_get_preferred_start_pad(state)) samples"
    }
}

// --changer-tune keys used by the voice's shifter (VoiceStretcher), for the command line's key check.
func isVoiceShifterTuneKey(_ key: String) -> Bool {
    if key == "naturalEngine" || key == "pulseShapePow" { return true }
    guard let probe = pulseshifter_new(48000) else { return false }
    defer { pulseshifter_delete(probe) }
    return pulseshifter_tune(probe, key, 1) != 0
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
    // The voice changer (Natural mode): made with the chain, used only while a voice is on.
    private let changer: OpaquePointer
    private let changerPitch: UnsafeMutablePointer<VoiceChangerPitch>
    private let changerStats: UnsafeMutablePointer<VoiceChangerStats>
    // Realistic mode (AI voice, Apple silicon): the stream that turns the mic into the AI voice at a fixed delay
    // (Sources/Voice/VoiceModel.h). Made with the chain when Realistic is on; its models may come later (attach).
    private var ai: OpaquePointer?
    let realisticID: String?  // the voice the AI stream is for (nil = no AI stream)
    // Sound effects (Soundboard): mixed in after the voice, never through the mic or the pitch change.
    private let sounds: OSAllocatedUnfairLock<SoundPlay>
    private var mix: SoundMix
    private var muteMic = false   // the playing sound is on the Mac's speakers
    private var muteLeft = 0      // samples the mic stays muted after a sound on the speakers ends
    private var micGain: Float = 1
    private let fadeStep: Float   // 10 ms from full to nothing
    private let muteAfter: Int    // 150 ms
    // For the command-line test: replaces the mic with a made-up sound.
    var testSource: ((UnsafeMutablePointer<Float>, Int) -> Void)?
    private(set) var firstInputTime: UInt64 = 0  // host time of the first mic sample (for the delay test)
    private(set) var blockInputTime: UInt64 = 0  // host time of the current callback's first mic sample (for the delay test)
    let slowReading = OSAllocatedUnfairLock(initialState: SlowReading())  // for the test (written without waiting)
    // Counts for --test-voice --watch, copied out after each callback without ever waiting on the sound thread.
    let stats = OSAllocatedUnfairLock(initialState: VoiceStats())
    private var counts = VoiceStats()
    private var overloadListener: Listener?

    // `changerTune`: --changer-tune settings for the voice changer (command line only).
    init(mic: AudioDeviceID, feed: AudioDeviceID, params: OSAllocatedUnfairLock<VoiceParams>, sounds: OSAllocatedUnfairLock<SoundPlay>,
         bufferFrames: UInt32? = nil, testSource: ((UnsafeMutablePointer<Float>, Int) -> Void)? = nil,
         changerTune: [(String, Float)] = [], realistic: (id: String, model: OpaquePointer?)? = nil) throws {
        realisticID = realistic?.id
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
        guard let made = VoiceStretcher(rate: rate, halfSteps: start.halfSteps, cartoon: start.cartoon, slowDeeper: start.slowDeeper,
                                        changer: start.changer != nil, tune: changerTune),
              let madeChanger = voicechanger_new(rate, 8192) else {
            throw Problem(message: "Can't use \(micName).")
        }
        stretcher = made
        changer = madeChanger
        for (key, value) in changerTune { _ = voicechanger_tune(changer, key, value) }
        voicechanger_set(changer, start.changer, start.strength)
        voicechanger_reset(changer)
        changerPitch = .allocate(capacity: 1)
        changerPitch.initialize(to: VoiceChangerPitch())
        changerStats = .allocate(capacity: 1)
        changerStats.initialize(to: VoiceChangerStats())
        speaking = SpeakingRate(sampleRate: rate)
        self.sounds = sounds
        mix = SoundMix(rate: rate, take: sounds.withLock { $0.take })  // a sound already playing when the chain starts isn't sent
        fadeStep = Float(1 / (0.01 * rate))
        muteAfter = Int(rate * 0.15)
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
        if let realistic {  // the AI voice: its delay includes one callback, so it is made once the size is known
            let callback = getValue(aggregate, kAudioDevicePropertyBufferFrameSize, default: frames)
            ai = voicestream_new(realistic.model, rate, Int32(max(callback, 1)), 0, nil)
            if let ai { for (key, value) in changerTune { _ = voicestream_tune(ai, key, value) } }
        }
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
        return """
            combined device: in \(io(aggregate, kAudioDevicePropertyScopeInput)) | out \(io(aggregate, kAudioDevicePropertyScopeOutput))
              mic \(micName): \(io(devices[0], kAudioDevicePropertyScopeInput))
              hidden feed: \(io(devices[2], kAudioDevicePropertyScopeOutput)); Pitch Shift Mic: \(io(devices[1], kAudioDevicePropertyScopeInput))
              \(stretcher.delayNote) (\(Int(rate)) Hz), pieces up to \(maxPiece)
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

        // A sound playing on the Mac's speakers: the mic would hear it and send it into the call a second time, so
        // the mic fades out (10 ms) while it plays and for 150 ms after. Headphones: nothing is muted.
        if let play = sounds.withLockIfAvailable({ $0 }) {
            if play.take != mix.take { startSound(play) }
            mix.follow(volume: play.volume)
        }
        let muted = (mix.playing && muteMic) || muteLeft > 0
        if muted || micGain < 1 {
            for i in 0..<frames {
                micGain = muted ? max(0, micGain - fadeStep) : min(1, micGain + fadeStep)
                source[i] *= micGain
            }
        }
        muteLeft = max(0, muteLeft - frames)

        if applied.slowDeeper {
            speaking.listen(source, frames)
            stretcher.set(extra: speaking.extra)
            let reading = SlowReading(rate: speaking.rate, extra: stretcher.extra)
            slowReading.withLockIfAvailable { $0 = reading }
        }

        // The voice changer listens to the mic and sets Rubber Band's pitch and voice shape for this callback
        // ("Deeper when slow" moves only the pitch, on top).
        let changing = stretcher.changerActive
        if changing {
            voicechanger_analyse(changer, source, Int32(frames), stretcher.extra, changerPitch)
            stretcher.set(changerPitch: Double(changerPitch.pointee.pitchScale), formantScale: Double(changerPitch.pointee.formantScale))
        }
        if let ai {  // Realistic: the mic (before Rubber Band) and its pitch frames go to the AI voice
            if !changing { changerPitch.pointee.newFrames = 0 }
            voicestreamPush(ai, source, frames, changerPitch)
        }

        // At normal pitch the mic goes straight out; otherwise the shifted sound replaces it in the same buffer.
        let shifting = stretcher.running
        if shifting {
            shift(source, frames)
            ring.read(into: source, frames)
            if changing {  // sibilance, tone EQ, presence and breath, lined up with the mic sound it came from
                voicechanger_post(changer, source, Int32(frames), Int32(clamping: soundDelay))
            }
            // Realistic: the AI voice at its fixed delay; when it isn't ready (loading, a late piece) Natural's sound,
            // delayed to the same point, fills in (crossfaded). Never silence, never the raw mic.
            if let ai { voicestream_pull(ai, source, Int32(clamping: soundDelay), source, Int32(frames)) }
        } else if let ai {
            voicestream_pull(ai, nil, 0, source, Int32(frames))  // (not reached while a voice is on: it always shifts)
        }
        for i in 0..<frames {
            var value = applied.silent ? 0 : source[i]
            if mix.active {
                var ended = false
                value = softLimit(value + mix.next(&ended))
                if ended && muteMic { muteLeft = muteAfter }  // played to the end
            } else if shifting {
                // The shifted voice can peak a few dB above the mic: ease its loudest moments instead of cutting
                // them off at full scale (a hard cut sounds harsh and buzzy).
                value = softLimit(value)
            } else {
                value = max(-1, min(1, value))
            }
            for b in micOutputStreams..<outs.count {
                guard let d = outs[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let ch = Int(outs[b].mNumberChannels)
                for c in 0..<ch { d[i * ch + c] = value }
            }
        }
        publish(frames, shifting: shifting)
    }

    // From a mic sample to it going out: Rubber Band + the waiting sound (samples).
    private var soundDelay: Int {
        counts.given - counts.returned + ring.count + stretcher.heldBack
    }

    // Copies the counts out for --watch (never waits: if the main thread is reading, this callback is left out).
    private func publish(_ frames: Int, shifting: Bool) {
        counts.frames = frames
        counts.ring = ring.count
        counts.sending = shifting && !ring.waiting
        counts.delay = counts.sending ? soundDelay : 0
        counts.changing = stretcher.changerActive
        if counts.changing {
            voicechanger_get_stats(changer, changerStats)
            counts.changer = changerStats.pointee
        }
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

    // A new sound, or Stop: the one playing fades out (SoundMix). Cutting one on the speakers starts the 150 ms hold.
    private func startSound(_ play: SoundPlay) {
        if mix.start(play) && muteMic { muteLeft = muteAfter }
        if mix.playing { muteMic = play.muteMic }
    }

    // Gives one callback's sound to Rubber Band and moves everything it has ready into the ring.
    private func shift(_ source: UnsafeMutablePointer<Float>, _ frames: Int) {
        var done = 0
        while done < frames {
            let count = min(maxPiece, frames - done)
            stretcher.process(source + done, count)
            done += count
        }
        counts.given += frames
        while true {
            let ready = min(stretcher.available, maxPiece)
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
        // The voice changer: a new voice or strength glides there; turning it on or off blends over 0.15 s.
        if latest.changer != applied.changer || latest.strength != applied.strength {
            voicechanger_set(changer, latest.changer, latest.strength)
        }
        let changerWasActive = stretcher.changerActive
        let changerToggled = (latest.changer != nil) != stretcher.changerOn
        let changerFresh = stretcher.set(changer: latest.changer != nil)
        if stretcher.changerActive && !changerWasActive { voicechanger_reset(changer) }  // starts listening afresh
        let amountMoved = latest.halfSteps != stretcher.halfSteps && !stretcher.changerOn  // ignored while a voice is on
        let changed = amountMoved || latest.slowDeeper != stretcher.slowDeeper || changerToggled
        let restarted = stretcher.set(slowDeeper: latest.slowDeeper)
        if stretcher.set(halfSteps: latest.halfSteps) || restarted || changerFresh {  // coming back from normal pitch: start fresh
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

    // Realistic: gives the AI stream its models once they are loaded (main thread). False if they don't fit it.
    func attach(model: OpaquePointer) -> Bool {
        guard let ai else { return false }
        return voicestream_set_model(ai, model) != 0
    }

    // Realistic: what the AI voice is doing, and its fixed delay in ms (nil without an AI stream).
    var aiStats: (stats: VoiceStreamStats, latencyMs: Double)? {
        guard let ai else { return nil }
        var s = VoiceStreamStats()
        voicestream_get_stats(ai, &s)
        return (s, Double(voicestream_latency_frames(ai)) / sampleRate * 1000)
    }

    private func cleanUp() {
        piece.deallocate()
        scratch.deallocate()
        if let ai { voicestream_delete(ai) }  // the sound has stopped, so nothing uses it any more
        ai = nil
        voicechanger_delete(changer)
        changerPitch.deallocate()
        changerStats.deallocate()
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
    var changing = false     // the voice changer is on
    var changer = VoiceChangerStats()  // what it is doing
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
    // The voice changer card. Used only while "Your voice" is on (never in the Soundboard-only pass-through).
    var changer = ChangerSettings() { didSet { if changer != oldValue { pushParams() } } }
    private(set) var changerState: ChangerState = .off
    var changerTune: [(String, Float)] = []  // --changer-tune (command line only; used when the chain is made)
    // Realistic (AI) mode: the models load in the background (VoiceModelStore) while Natural plays; the chain is
    // remade once when Realistic or the voice changes (the AI stream's fixed delay starts right away, Natural fills
    // in until the models are ready); they are freed when Realistic goes off.
    private let models = VoiceModelStore.shared
    private var aiPolling = false
    private var lastMisses: Int64 = 0, missesAt = Date.distantPast
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
        models.onChange = { [weak self] in self?.modelsChanged() }
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

    // With the voice off (only the Soundboard running) the voice goes through unchanged, and the voice changer only
    // runs while "Your voice" is on.
    private func pushParams() {
        let steps = voiceSwitch ? halfSteps : 0, cartoon = cartoon, slowDeeper = voiceSwitch && slowDeeper
        let voice = voiceSwitch && changer.on ? VoiceLibrary.shared.voice(changer.voiceID)?.natural : nil
        let new = VoiceParams(halfSteps: steps, cartoon: cartoon, slowDeeper: slowDeeper, silent: false, changer: voice,
                              strength: max(0, min(1, changer.strength)))
        params.withLock {
            $0.halfSteps = new.halfSteps; $0.cartoon = new.cartoon; $0.slowDeeper = new.slowDeeper
            $0.changer = new.changer; $0.strength = new.strength
        }
        updateChangerState(voiceFound: voice != nil)
    }

    // Natural mode plays whenever the changer is on. Realistic (AI): loading (Natural plays), realistic, fallback
    // (some pieces came late in the last 10 s; Natural filled in), or unavailable (why; Natural plays).
    private func updateChangerState(voiceFound: Bool) {
        var new: ChangerState = .off
        if changer.on && voiceSwitch {
            if !voiceFound {
                new = .unavailable("no voice \"\(changer.voiceID)\"")
            } else if changer.realistic {
                #if arch(arm64)
                new = realisticState()
                #else
                new = .unavailable("needs Apple silicon")
                #endif
            } else {
                new = .natural
            }
        }
        updateRealistic()
        guard new != changerState else { return }
        changerState = new
        onChange()
    }

    // The voice the AI is wanted for now (nil = Realistic is off, or this Mac can't run it).
    private var realisticWanted: VoiceEntry? {
        #if arch(arm64)
        guard voiceSwitch && changer.on && changer.realistic, let entry = VoiceLibrary.shared.voice(changer.voiceID),
              entry.manifest.realistic != nil else { return nil }
        return entry
        #else
        return nil
        #endif
    }

    private func realisticState() -> ChangerState {
        guard let entry = VoiceLibrary.shared.voice(changer.voiceID) else { return .unavailable("no voice") }
        guard entry.manifest.realistic != nil else { return .unavailable("\(entry.name) has no AI voice") }
        switch models.status {
        case .failed(let id, let why) where id == entry.id: return .unavailable(why)
        case .ready(let id) where id == entry.id:
            guard let ai = chain?.aiStats else { return .realistic }  // nobody listening yet: ready to go
            if ai.stats.loaded == 0 { return .loading }               // fading in
            if ai.stats.misses > lastMisses { lastMisses = ai.stats.misses; missesAt = Date() }
            return Date().timeIntervalSince(missesAt) < 10 ? .fallback(misses: Int(ai.stats.misses)) : .realistic
        default: return .loading
        }
    }

    // Starts loading the AI voice, remakes the chain when its AI stream is for another voice (or none), and frees the
    // models once nothing uses them.
    private func updateRealistic() {
        let want = realisticWanted
        if let want { models.want(want) }
        if running, let chain, chain.realisticID != want?.id {
            DispatchQueue.main.async { [weak self] in  // not from inside pushParams
                guard let self, let current = self.chain, current.realisticID != self.realisticWanted?.id else { return }
                self.closeChain()
                self.update()
            }
        }
        if want == nil && models.status != .none && chain?.realisticID == nil { models.free() }
        if want != nil && !aiPolling { pollRealistic() }
    }

    // Once a second while Realistic is on: loading -> realistic, and late pieces -> fallback.
    private func pollRealistic() {
        aiPolling = realisticWanted != nil
        guard aiPolling else { return }
        updateChangerState(voiceFound: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.pollRealistic() }
    }

    // The models finished loading (or failed): hand them to the running chain's AI stream.
    private func modelsChanged() {
        if case .ready(let id) = models.status, let chain, chain.realisticID == id, let model = models.model {
            if !chain.attach(model: model) {  // made for other piece sizes (can't happen with one model set): remake
                closeChain()
                update()
            }
        }
        updateChangerState(voiceFound: VoiceLibrary.shared.voice(changer.voiceID) != nil)
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
                    let ai = realisticWanted.map { (id: $0.id, model: models.model(for: $0.id)) }
                    let made = try VoiceChain(mic: mic, feed: feed, params: params, sounds: sounds,
                                              bufferFrames: testBufferFrames, testSource: testSource, changerTune: changerTune,
                                              realistic: ai)
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
        models.freeRetired()  // an AI voice switched away from: its chain is gone now
        if realisticWanted == nil && models.status != .none { models.free() }  // nothing uses the AI voice now
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
// (`--voice-preset old`, see voiceLevelGain), so old and new can be compared. `changer`: the voice changer
// (--voice), with the same classes and order as the live chain (analyse before Rubber Band, post after); with
// `stats` it prints what the changer is doing once per second of sound.
func renderVoiceFile(input: String, output: String, halfSteps: Float, cartoon: Float, changes: [(Double, Float)],
                     slowDeeper: Bool = false, levelFix: Bool = true, changer: ChangerOptions? = nil) throws {
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
    if halfSteps != 0 || slowDeeper || changer != nil {
        guard let stretcher = VoiceStretcher(rate: rate, halfSteps: halfSteps, cartoon: cartoon, slowDeeper: slowDeeper,
                                             levelFix: levelFix, changer: changer != nil, tune: changer?.tune ?? []) else {
            throw Problem(message: "Could not start Rubber Band.")
        }
        // The voice changer, made and set up like the live chain's.
        var voiceChanger: OpaquePointer?
        if let changer {
            guard let made = voicechanger_new(rate, 4096) else { throw Problem(message: "Could not start the voice changer.") }
            voiceChanger = made
            for (key, value) in changer.tune { _ = voicechanger_tune(made, key, value) }
            voicechanger_set(made, changer.voice, changer.strength)
            voicechanger_reset(made)
        }
        defer { if let voiceChanger { voicechanger_delete(voiceChanger) } }
        var analysis = VoiceChangerPitch()
        var nextStats = 1
        let speaking = SpeakingRate(sampleRate: rate)
        var nextReport = 1
        let block = 512
        var skip = stretcher.startSkip  // so the output lines up with the input
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
            if let voiceChanger {
                chunk.withUnsafeBufferPointer { voicechanger_analyse(voiceChanger, $0.baseAddress!, Int32(block), stretcher.extra, &analysis) }
                stretcher.set(changerPitch: Double(analysis.pitchScale), formantScale: Double(analysis.formantScale))
            }
            chunk.withUnsafeBufferPointer { stretcher.process($0.baseAddress!, block) }
            position += block
            while stretcher.available > 0 {
                let want = min(stretcher.available, piece.count)
                let got = piece.withUnsafeMutableBufferPointer { stretcher.retrieve($0.baseAddress!, want) }
                if got <= 0 { break }
                let drop = min(skip, got)
                skip -= drop
                if let voiceChanger, got > drop {  // lined up exactly: output sample n came from input sample n
                    let delay = position - (result.count + got - drop)
                    piece.withUnsafeMutableBufferPointer {
                        voicechanger_post(voiceChanger, $0.baseAddress! + drop, Int32(got - drop), Int32(delay))
                    }
                }
                result.append(contentsOf: piece[drop..<got])
            }
            if let voiceChanger, changer?.stats == true, position >= nextStats * Int(rate), position <= length {
                var s = VoiceChangerStats()
                voicechanger_get_stats(voiceChanger, &s)
                print(changerStatsLine(s, seconds: Double(nextStats)))
                nextStats += 1
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

// One line about what the voice changer is doing (--changer-stats, --test-voice --watch).
func changerStatsLine(_ s: VoiceChangerStats, seconds: Double) -> String {
    let eq = withUnsafeBytes(of: s.eqDb) { Array($0.bindMemory(to: Float.self)) }.map { String(format: "%+.1f", $0) }.joined(separator: " ")
    return String(format: "%4.0fs  changer: strength %.2f, speaker median %.0f Hz, shift %+.2f half-steps, shape x%.3f, voiced %.0f%%, creak %.1f%%, EQ [%@] dB, cost %.3f ms per 10 ms (worst %.3f)",
                  seconds, s.strength, s.medianHz, s.semitones, s.formant, 100 * s.voicedShare, 100 * s.creakShare, eq, s.analyseMs, s.worstMs)
}

// Offline copy of the live chain's timing (--render-voice ... --live-sim [--buffer 128]): the file goes through the
// same steps as VoiceChain.render, in callback-sized pieces (Rubber Band, the waiting sound in a VoiceRing, the voice
// changer's analyse and post), and the result is written as the chain would send it (late by the chain's delay).
// Prints the Rubber Band + waiting-sound delay (the part of the mic-to-Pitch-Shift-Mic delay this code adds) and
// the ring's dry-outs, trims and replays. No devices are used.
func simulateVoiceChain(input: String, output: String, halfSteps: Float, cartoon: Float, slowDeeper: Bool,
                        changer: ChangerOptions?, blockFrames: Int) throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: input))
    let rate = file.processingFormat.sampleRate
    let length = Int(file.length)
    guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(length)) else {
        throw Problem(message: "Could not read \(input).")
    }
    try file.read(into: source)
    let channels = Int(file.processingFormat.channelCount), used = channels <= 2 ? channels : 1
    var mono = [Float](repeating: 0, count: length)
    for c in 0..<used { for i in 0..<length { mono[i] += source.floatChannelData![c][i] / Float(used) } }
    guard let stretcher = VoiceStretcher(rate: rate, halfSteps: halfSteps, cartoon: cartoon, slowDeeper: slowDeeper,
                                         changer: changer != nil, tune: changer?.tune ?? []), stretcher.running,
          let voiceChanger = voicechanger_new(rate, Int32(max(4096, blockFrames))) else {
        throw Problem(message: "Nothing to shift (0 half-steps and no voice), or Rubber Band didn't start.")
    }
    defer { voicechanger_delete(voiceChanger) }
    if let changer {
        for (key, value) in changer.tune { _ = voicechanger_tune(voiceChanger, key, value) }
        voicechanger_set(voiceChanger, changer.voice, changer.strength)
        voicechanger_reset(voiceChanger)
    }
    let ring = VoiceRing(rate: rate)
    let speaking = SpeakingRate(sampleRate: rate)
    var block = [Float](repeating: 0, count: blockFrames)
    var piece = [Float](repeating: 0, count: 4096)
    var analysis = VoiceChangerPitch()
    var given = 0, returned = 0
    var delays: [Double] = []  // ms, once per callback while sending
    var result: [Float] = []
    result.reserveCapacity(length + Int(rate))
    var position = 0
    while position < length + Int(rate / 2) {
        let pitchBefore = stretcher.pitch
        stretcher.glide(blockFrames)
        if stretcher.pitch != pitchBefore { ring.amountChanged() }
        for i in 0..<blockFrames { block[i] = position + i < length ? mono[position + i] : 0 }
        position += blockFrames
        if slowDeeper {
            block.withUnsafeBufferPointer { speaking.listen($0.baseAddress!, blockFrames) }
            stretcher.set(extra: speaking.extra)
        }
        if stretcher.changerActive {
            block.withUnsafeBufferPointer { voicechanger_analyse(voiceChanger, $0.baseAddress!, Int32(blockFrames), stretcher.extra, &analysis) }
            stretcher.set(changerPitch: Double(analysis.pitchScale), formantScale: Double(analysis.formantScale))
        }
        block.withUnsafeBufferPointer { stretcher.process($0.baseAddress!, blockFrames) }
        given += blockFrames
        while true {
            let ready = min(stretcher.available, piece.count)
            if ready <= 0 { break }
            let got = piece.withUnsafeMutableBufferPointer { stretcher.retrieve($0.baseAddress!, ready) }
            if got <= 0 { break }
            returned += got
            piece.withUnsafeBufferPointer { ring.write($0.baseAddress!, got) }
        }
        ring.settle(blockFrames)
        block.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, blockFrames) }
        let delay = given - returned + ring.count + stretcher.heldBack  // as the live chain counts it
        if stretcher.changerActive {
            block.withUnsafeMutableBufferPointer { voicechanger_post(voiceChanger, $0.baseAddress!, Int32(blockFrames), Int32(delay)) }
        }
        if !ring.waiting { delays.append(Double(delay) / rate * 1000) }
        for i in 0..<blockFrames { result.append(softLimit(block[i])) }
    }
    let steady = Array(delays.suffix(delays.count * 4 / 5)).sorted()  // after the first fifth (start-up trims)
    if !steady.isEmpty {
        print(String(format: "live-sim: callback %d, Rubber Band + waiting sound %.1f ms median (%.1f ... %.1f) over the last 80%%; dry-outs %d, trims %d (%.0f ms), replays %d (%.0f ms), margin %.1f ms",
                     blockFrames, steady[steady.count / 2], steady.first!, steady.last!, ring.dryOuts, ring.trims,
                     Double(ring.trimmed) / rate * 1000, ring.replays, Double(ring.replayed) / rate * 1000, Double(ring.margin) / rate * 1000))
    }
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, result.count))) else {
        throw Problem(message: "Could not write \(output).")
    }
    buffer.frameLength = AVAudioFrameCount(result.count)
    _ = result.withUnsafeBufferPointer { memcpy(buffer.floatChannelData![0], $0.baseAddress!, result.count * MemoryLayout<Float>.size) }
    try AVAudioFile(forWriting: URL(fileURLWithPath: output), settings: format.settings).write(from: buffer)
}
