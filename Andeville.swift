import AppKit
import Accelerate
import AVFoundation
import CoreAudio
import CoreML
import CoreImage
import CryptoKit
import IOBluetooth
import IOKit.ps
import LocalAuthentication
import OpenDirectory
import Security
import ServiceManagement
import SwiftUI
import Vision

// MARK: - Notch island

enum IslandPhase { case scanning, success, failure, consent }

final class IslandModel: ObservableObject {
    @Published var expanded = false
    @Published var contentShown = false
    @Published var phase = IslandPhase.scanning
    @Published var message = ""
    @Published var shake = 0
}

extension NSWindow {
    /// The top fillets stay rounded the whole way down, so the window fades rather than letting them pop beside the hardware notch.
    func fade(in on: Bool) {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; animator().alphaValue = on ? 1 : 0 },
                                             completionHandler: { if !on { self.orderOut(nil) } })
    }
}

/// Always-on black fillets where the notch meets the top edge. Same shape as the collapsed island,
/// so they land on it and their fade-out shows nothing.
final class NotchBase {
    let model: NotchModel
    init(model: NotchModel) { self.model = model }
    /// Lives in the lock screen space, which also shows on the desktop but sits outside it, so the desktop's
    /// shrink-and-fade on lock and unlock never drags the shape away from the notch.
    private var panel: NSPanel?

    func update() {
        let screen = notchScreen().flatMap { $0.safeAreaInsets.top > 0 ? $0 : nil }
        guard let screen else {
            panel?.orderOut(nil)
            panel = nil
            return
        }
        let notch = notchSize(of: screen)
        let bar = max(notch.height, screen.frame.maxY - screen.visibleFrame.maxY) // Menu bar's bottom edge: the hover swell goes no lower.
        let size = CGSize(width: notch.width + (Store.notchEar + NotchLive.wing + NotchLive.swell) * 2, height: bar) // Room for the live wings and the hover swell.
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        guard panel?.frame != frame else { return } // Called on every defaults change; rebuilding would flicker.
        panel?.orderOut(nil)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.animationBehavior = .none // No system pop-in: it scales the window about its center, lifting the shape off the top edge for a few frames.
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1) // Under the island.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: NotchLive(model: model, notch: notch, bar: bar))
        host.sizingOptions = [] // A bare shape has no size of its own; let the panel set it.
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        p.setFrame(frame, display: false)
        p.canBecomeVisibleWithoutLogin = true
        p.orderFrontRegardless()
        LockScreenSpace.adopt(p)
        panel = p
    }

    private var generation = 0

    /// Locking shrinks the desktop away faster than the lock screen arrives, which left the shape standing alone.
    /// It can sit that out hidden and fade back in on the settled lock screen, but the vanish-and-return read as a
    /// glitch at the top fillets, so by default it stays put the whole way.
    /// ponytail: off by default; `defaults write com.ggear.faytai lockSettle -float <s>` hides it for that long.
    /// `hold` keeps it visible that long first, so the player's wings are seen folding in as the screen locks.
    func sitOutLock(hold: TimeInterval = 0) {
        let settle = UserDefaults.standard.double(forKey: "lockSettle")
        guard settle > hold, let p = panel else { return }
        generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { if current == self.generation { p.alphaValue = 0 } }
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            guard current == self.generation else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.35; p.animator().alphaValue = 1 }
        }
    }
}

/// What a volume or brightness key shows in the notch: its glyph and the new level, 0...1.
struct NotchHUD: Equatable {
    let symbol: String, value: Double
    /// Brightness shows its level on the left and its sun on the right, the side its scroll lives on; volume the other way.
    var flipped: Bool { symbol == "sun.max.fill" }

    static func volume(_ v: Double, muted: Bool) -> NotchHUD {
        let level = muted ? 0 : v
        return NotchHUD(symbol: level == 0 ? "speaker.slash.fill" : "speaker.wave.\(min(Int(level * 3) + 1, 3)).fill", value: level)
    }

    /// One key press: 16 steps across the range as macOS does, 64 with ⌥⇧ held.
    static func step(_ v: Double, up: Bool, fine: Bool = false) -> Double {
        let n: Double = fine ? 64 : 16
        return min(max(((v * n).rounded() + (up ? 1 : -1)) / n, 0), 1)
    }
}

/// The collapsed notch's live activity: while a song plays, the notch grows a wing each side, artwork left and a
/// waveform right; plugging in the power adapter shows the charge there for a moment. Otherwise the bare notch shape.
struct NotchLive: View {
    @ObservedObject var model: NotchModel
    let notch: CGSize
    /// The menu bar's height: hovered, the notch reaches down to its bottom edge and no further.
    var bar: CGFloat = 0
    @AppStorage("liveActivity") private var enabled = true
    @AppStorage("hoverSpeed") private var hoverSpeed = Store.hoverSpeedDefault
    @AppStorage("notchEar") private var ear = Store.notchEarDefault // Redraws live when the slider moves.
    static let wing: CGFloat = 44
    /// How far the notch widens under the cursor, each side.
    static let swell: CGFloat = 3

    var body: some View {
        let song = model.locked ? nil : model.nowPlaying.flatMap { $0.playing ? $0 : nil }
        let on = model.hud != nil || enabled && (model.charge != nil || song != nil)
        // Keyed by song, not by image: the stream hands over a fresh image object on every play/pause.
        let tint = song?.tint.map(Color.init) ?? .white // The artwork's color, also on the volume and brightness keys while a song plays.
        let artKey = song.map { "\($0.title)|\($0.artist)|\($0.artwork != nil)" } ?? ""
        let grow = model.hover ? NotchLive.swell : 0
        let height = model.hover ? max(bar, notch.height) : notch.height
        let pop: CGFloat = model.hover ? 1.12 : 1 // The wing icons grow with the notch.
        let shape = IslandShape(width: notch.width + (on ? NotchLive.wing * 2 : 0) + grow * 2, height: height, radius: Store.notchEar, ear: Store.notchEar)
        ZStack(alignment: .top) {
            shape.fill(.black)
            HStack(spacing: 0) {
                Group {
                    if let hud = model.hud {
                        hudPart(hud, icon: !hud.flipped, tint: tint)
                            .transition(.blurReplace) // Over the player too: the art blurs out, the key's glyph blurs in.
                    } else if model.charge != nil {
                        Image(systemName: "bolt.fill").font(.system(size: 13)).foregroundStyle(.green)
                            .transition(.blurReplace)
                    } else {
                        // A new song's picture blurs in over the old one blurring out.
                        ZStack {
                            if let art = song?.artwork {
                                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            } else {
                                Image(systemName: "music.note").font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .id(artKey)
                        .transition(.blurReplace)
                    }
                }
                .scaleEffect(pop)
                .frame(width: NotchLive.wing)
                .offset(x: -grow / 2) // Half the swell: stays centered in its widened wing, equal space either side.
                Spacer(minLength: 0)
                Group {
                    if let hud = model.hud {
                        hudPart(hud, icon: hud.flipped, tint: tint)
                            .transition(.blurReplace)
                    } else if let b = model.charge {
                        Text("\(b.level)%").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.green)
                            .transition(.blurReplace)
                    } else {
                        MusicBars(playing: song != nil, color: tint, spectrum: model.spectrum)
                            .transition(.blurReplace)
                    }
                }
                .scaleEffect(pop)
                .frame(width: NotchLive.wing)
                .offset(x: grow / 2)
            }
            .frame(width: notch.width + NotchLive.wing * 2, height: height) // Kept centered in the swollen height.
            .opacity(on ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(shape)
        .foregroundStyle(.white.opacity(0.9))
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: on) // Quick: a song shows the moment it starts.
        .animation(.spring(response: hoverSpeed, dampingFraction: 0.85), value: model.hover) // Settings › 노치 › 호버 반응 속도.
        .animation(.easeInOut(duration: 0.25), value: model.charge != nil)
        .animation(.easeInOut(duration: 0.3), value: model.hud != nil) // Inner, so it wins over the 0.15 below: the blur swap with the player has time to read.
        .animation(.easeInOut(duration: 0.15), value: model.hud?.symbol)
        .animation(.easeInOut(duration: 0.45), value: artKey)
        .accessibilityHidden(true)
    }

    /// One side of the key's indicator: its glyph, or its level bar.
    @ViewBuilder private func hudPart(_ hud: NotchHUD, icon: Bool, tint: Color) -> some View {
        if icon {
            Image(systemName: hud.symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(tint)
        } else {
            Capsule().fill(tint.opacity(0.25)).frame(width: 30, height: 4)
                .overlay(alignment: .leading) { Capsule().fill(tint).frame(width: 30 * hud.value) }
                .animation(.easeOut(duration: 0.12), value: hud.value)
        }
    }
}

/// The Dynamic Island's music bars, bass on the left to treble on the right, moving with what the Mac is playing
/// (`Spectrum`), tinted from the artwork; flat when stopped.
struct MusicBars: View {
    let playing: Bool, color: Color
    @ObservedObject var spectrum: Spectrum
    static let count = 6

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<MusicBars.count, id: \.self) { i in
                Capsule().fill(color).frame(width: 2.5, height: playing ? 3 + 11 * spectrum.levels[i] : 3)
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.12), value: spectrum.levels)
    }
}

/// The Mac's sound output in six bands, bass to treble, 0...1 each. Reads it through a Core Audio process tap (macOS 14.2+;
/// asks once for System Audio Recording), only while a song plays. Nothing is recorded or kept.
final class Spectrum: ObservableObject {
    @Published private(set) var levels = [CGFloat](repeating: 0, count: MusicBars.count)
    static let n = 1024
    /// Band edges in Hz: bass, low-mid, mid, upper-mid, presence, treble.
    static let edges: [Double] = [40, 150, 400, 1000, 2500, 6000, 16000]
    private var tap = AudioObjectID(kAudioObjectUnknown), aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "spectrum", qos: .userInteractive)
    // On `queue` only.
    private var samples: [Float] = []
    private var sampleRate = 48000.0
    private var ceiling: [Float] = [], floor: [Float] = [] // Empty until the first block sets them around it.
    private var smooth = [CGFloat](repeating: 0, count: MusicBars.count)
    private let fft = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Spectrum.n, isHalfWindow: false)

    var running: Bool { proc != nil }

    func start() {
        guard !running else { return }
        guard #available(macOS 14.2, *) else { return }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var t = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &t) == noErr else { log("spectrum: no tap (System Audio Recording not allowed?)"); return }
        tap = t
        var out = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &out)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        AudioObjectGetPropertyData(out, &addr, 0, nil, &size, &uid)
        let outUID = uid?.takeRetainedValue() as String? ?? ""
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Andeville Spectrum", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID, kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg) == noErr else { log("spectrum: no aggregate device"); stop(); return }
        aggregate = agg
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        addr.mSelector = kAudioTapPropertyFormat
        if AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            let rate = format.mSampleRate
            queue.async { self.sampleRate = rate }
        }
        var p: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&p, agg, queue) { [weak self] _, input, _, _, _ in self?.feed(input) }
        guard status == noErr, let p else { log("spectrum: no IO proc \(status)"); stop(); return }
        proc = p
        if AudioDeviceStart(agg, p) != noErr { log("spectrum: did not start"); stop() }
    }

    func stop() {
        guard running || tap != kAudioObjectUnknown || aggregate != kAudioObjectUnknown else { return }
        if let p = proc { AudioDeviceStop(aggregate, p); AudioDeviceDestroyIOProcID(aggregate, p) }
        proc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if tap != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
        queue.async { self.samples.removeAll(); self.ceiling = []; self.floor = []; self.smooth = self.smooth.map { _ in 0 } }
        levels = [CGFloat](repeating: 0, count: MusicBars.count)
    }

    private func feed(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let b = list.first, let data = b.mData else { return }
        let channels = max(Int(b.mNumberChannels), 1), frames = Int(b.mDataByteSize) / 4 / channels
        let f = data.assumingMemoryBound(to: Float.self)
        for i in 0..<frames { samples.append(f[i * channels] + (channels > 1 ? f[i * channels + 1] : 0)) }
        while samples.count >= Spectrum.n {
            let block = Array(samples.prefix(Spectrum.n))
            samples.removeFirst(Spectrum.n)
            let db = Spectrum.bands(power(block), sampleRate: sampleRate)
            if ceiling.isEmpty { ceiling = db.map { $0 + 6 }; floor = db.map { $0 - 6 } }
            var out = [CGFloat](repeating: 0, count: db.count)
            for i in db.indices {
                // Each band between its own recent quietest and loudest, which drift toward each other: a steady loud
                // band still moves with its beats, and bass and treble both use the full height. Silence stays flat.
                ceiling[i] = max(db[i], ceiling[i] - 0.5)
                floor[i] = min(db[i], floor[i] + 0.5)
                let range = max(ceiling[i] - floor[i], 18) // Wider floor-to-top: a small change moves the bar less.
                let target: CGFloat = db[i] < -90 ? 0 : CGFloat(min(max((db[i] - floor[i]) / range, 0), 1))
                // Eased toward it, rising quicker than falling, so bars glide instead of jumping block to block.
                // ponytail: 0.35 up / 0.12 down per ~21 ms block; lower both for calmer bars.
                smooth[i] += (target - smooth[i]) * (target > smooth[i] ? 0.35 : 0.12)
                out[i] = smooth[i]
            }
            DispatchQueue.main.async { self.levels = out }
        }
    }

    /// Power per FFT bin of one Hann-windowed block of `n` samples.
    private func power(_ block: [Float]) -> [Float] {
        let half = Spectrum.n / 2
        var windowed = [Float](repeating: 0, count: Spectrum.n)
        vDSP.multiply(block, window, result: &windowed)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half), mags = [Float](repeating: 0, count: half)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                }
                vDSP_fft_zrip(fft, &split, 1, 10, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        return mags
    }

    /// Mean power of each band in dB, from per-bin power of an `n`-point FFT.
    static func bands(_ power: [Float], sampleRate: Double) -> [Float] {
        (0..<edges.count - 1).map { i in
            let lo = max(Int(edges[i] * Double(n) / sampleRate), 1), hi = min(max(Int(edges[i + 1] * Double(n) / sampleRate), lo + 1), power.count)
            let mean = power[lo..<hi].reduce(0, +) / Float(hi - lo)
            return 10 * log10(mean + 1e-12)
        }
    }

    /// For the self-check: the band of a pure tone.
    static func loudestBand(ofTone hz: Double, sampleRate: Double = 48000) -> Int {
        let s = Spectrum()
        let tone = (0..<n).map { Float(sin(2 * .pi * hz * Double($0) / sampleRate)) }
        let db = bands(s.power(tone), sampleRate: sampleRate)
        return db.indices.max { db[$0] < db[$1] }!
    }
}

/// Animates as a drawn shape, not layout, so the content inside can never hold its size open.
struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    /// Concave fillets where the shape meets the top edge, drawn outside `width` like the notch's own corners.
    var ear: CGFloat = 0
    /// Not animated: the collapsed and open widths. With both set, the width eases to `maxWidth` over the first 90% of
    /// the spring and then holds, so a bouncing spring's overshoot and rebound never move the top fillets (past the
    /// window's edge, which is exactly this wide plus the fillets, they showed cut off). Height still bounces.
    /// ponytail: 90% clears the rebound of the bounciest setting (0.6, dips to ~94%); lower it if that range grows.
    var minWidth: CGFloat = 0
    var maxWidth: CGFloat = .infinity

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(radius, ear)) }
        set { (width, height, radius, ear) = (newValue.first.first, newValue.first.second, newValue.second.first, newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var width = min(width, maxWidth)
        if maxWidth.isFinite, maxWidth > minWidth, minWidth > 0 {
            let u = min(max((width - minWidth) / (maxWidth - minWidth) / 0.9, 0), 1)
            width = minWidth + (maxWidth - minWidth) * (1 - (1 - u) * (1 - u))
        }
        let x0 = rect.midX - width / 2, x1 = x0 + width, h = max(height, 0)
        let r = min(radius, width / 2, h), e = min(ear, max(h - r, 0))
        var p = Path()
        p.move(to: CGPoint(x: x0 - e, y: 0))
        p.addLine(to: CGPoint(x: x1 + e, y: 0))
        p.addArc(tangent1End: CGPoint(x: x1, y: 0), tangent2End: CGPoint(x: x1, y: h), radius: e)
        p.addArc(tangent1End: CGPoint(x: x1, y: h), tangent2End: CGPoint(x: x0, y: h), radius: r)
        p.addArc(tangent1End: CGPoint(x: x0, y: h), tangent2End: CGPoint(x: x0, y: 0), radius: r)
        p.addArc(tangent1End: CGPoint(x: x0, y: 0), tangent2End: CGPoint(x: x0 - e, y: 0), radius: e)
        p.closeSubpath()
        return p
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    let notch: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var symbol: String {
        switch model.phase {
        case .success: return "checkmark.circle.fill"
        case .consent: return "lock.fill"
        default: return "faceid"
        }
    }
    private var color: Color {
        switch model.phase {
        case .scanning: return .white
        case .success: return .green
        case .failure: return .red
        case .consent: return .blue
        }
    }

    var body: some View {
        let radius: CGFloat = model.expanded ? 38 : Store.notchEar
        ZStack(alignment: .top) {
            IslandShape(width: notch.width, height: model.expanded ? 190 : notch.height, radius: radius, ear: Store.notchEar).fill(.black) // Same width as the notch, so no square top edge shows beside it.
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: model.phase == .consent ? 74 : 66, weight: .light))
                    .foregroundStyle(color)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: model.phase == .scanning && model.expanded)
                    .keyframeAnimator(initialValue: CGFloat(0), trigger: model.shake) { view, x in
                        view.offset(x: x)
                    } keyframes: { _ in
                        KeyframeTrack {
                            for x: CGFloat in [-14, 12, -9, 6, 0] { CubicKeyframe(x, duration: 0.07) }
                        }
                    }
                Text(model.message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 12)
            }
            .padding(.top, notch.height + 16)
            .opacity(model.contentShown ? 1 : 0)
            .blur(radius: model.contentShown || reduceMotion ? 0 : 8)
            .scaleEffect(model.contentShown || reduceMotion ? 1 : 0.72, anchor: .top)
            .offset(y: model.contentShown || reduceMotion ? 0 : -14)
            .animation(model.contentShown ? .spring(response: 0.42, dampingFraction: 0.72) : .spring(response: 0.22, dampingFraction: 1), value: model.contentShown)
            .frame(width: notch.width)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Retract must not overshoot (shrinking past the notch exposes the panel's top edge), so it is critically damped: still a spring, so a re-open mid-retract keeps its momentum.
        .animation(reduceMotion ? .easeOut(duration: 0.15) : model.expanded ? .spring(response: 0.42, dampingFraction: 1 - Store.hubBounce) : .spring(response: 0.5, dampingFraction: 1), value: model.expanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.phase)
    }
}

func log(_ s: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Andeville.log")
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        _ = try? h.seekToEnd()
        h.write(Data(line.utf8))
        try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Private SkyLight API: the only known way to draw above the lock screen. Not App Store safe.
enum LockScreenSpace {
    private static let connection: (cid: Int32, space: Int32, addWindows: @convention(c) (Int32, Int32, CFArray, Int32) -> Int32)? = {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let main = dlsym(lib, "SLSMainConnectionID"), let create = dlsym(lib, "SLSSpaceCreate"),
              let level = dlsym(lib, "SLSSpaceSetAbsoluteLevel"), let show = dlsym(lib, "SLSShowSpaces"),
              let add = dlsym(lib, "SLSSpaceAddWindowsAndRemoveFromSpaces") else { log("SkyLight symbols missing"); return nil }
        let cid = unsafeBitCast(main, to: (@convention(c) () -> Int32).self)()
        let space = unsafeBitCast(create, to: (@convention(c) (Int32, Int32, Int32) -> Int32).self)(cid, 1, 0)
        _ = unsafeBitCast(level, to: (@convention(c) (Int32, Int32, Int32) -> Int32).self)(cid, space, 400)
        _ = unsafeBitCast(show, to: (@convention(c) (Int32, CFArray) -> Int32).self)(cid, [space] as CFArray)
        return (cid, space, unsafeBitCast(add, to: (@convention(c) (Int32, Int32, CFArray, Int32) -> Int32).self))
    }()

    static func adopt(_ window: NSWindow) {
        guard let c = connection else { return }
        _ = c.addWindows(c.cid, c.space, [window.windowNumber] as CFArray, 7)
    }
}

/// Turns the display into a soft white light for the camera in a dark room.
final class FillLight {
    private var panel: NSPanel?

    func on(overLockScreen: Bool) {
        guard panel == nil, let screen = notchScreen() else { return }
        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.backgroundColor = .white
        p.alphaValue = 0
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1) // Just under the island.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.setFrame(screen.frame, display: false)
        if overLockScreen { p.canBecomeVisibleWithoutLogin = true }
        p.orderFrontRegardless()
        if overLockScreen { LockScreenSpace.adopt(p) }
        panel = p
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 0.96 }
    }

    func off() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }
}

final class Island {
    private let model = IslandModel()
    private var panel: NSPanel?
    private var generation = 0

    func show(_ message: String, phase: IslandPhase = .scanning, overLockScreen: Bool = false) {
        generation += 1
        panel?.orderOut(nil)
        guard let screen = notchScreen() else { return }
        let notch = notchSize(of: screen)
        let size = CGSize(width: 320, height: 240)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.animationBehavior = .none
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        model.expanded = false
        model.contentShown = false
        model.phase = phase
        model.message = message
        let host = NSHostingView(rootView: IslandView(model: model, notch: notch))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        p.setFrame(frame, display: false)
        host.layoutSubtreeIfNeeded() // Settle the collapsed layout first, or the spring starts from the zero-size origin and runs diagonally.
        if overLockScreen { p.canBecomeVisibleWithoutLogin = true }
        p.alphaValue = 0
        p.orderFrontRegardless()
        if overLockScreen { LockScreenSpace.adopt(p) }
        p.fade(in: true)
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.model.expanded = true
            self.model.contentShown = true
        }
    }

    var isShowing: Bool { panel != nil }

    func update(_ message: String) { model.message = message }

    /// A large blue lock in place of the face: the current keychain terms are not signed yet.
    func askConsent(overLockScreen: Bool = false) {
        show("키체인에 대한 동의가 필요합니다", phase: .consent, overLockScreen: overLockScreen)
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            if current == self.generation { self.dismiss() }
        }
    }

    /// Shows the result, calls `then` as the island starts to retract, and removes the window afterwards.
    /// A success calls `then` right away (unlock typing must not wait on the checkmark); a failure calls it once the shake has been seen.
    func finish(_ ok: Bool, then: @escaping () -> Void = {}) {
        generation += 1
        let current = generation
        model.phase = ok ? .success : .failure
        model.message = ok ? "확인됨" : "인식하지 못했습니다"
        if !ok { model.shake += 1 }
        if ok { then() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            if !ok { then() }
            guard current == self.generation else { return }
            self.retract(current)
        }
    }

    /// Retracts with no result shown, for when the wait simply ends.
    func dismiss() {
        guard panel != nil else { return }
        generation += 1
        retract(generation)
    }

    private func retract(_ current: Int) {
        model.contentShown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard current == self.generation else { return }
            self.model.expanded = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { // Just past the 0.12 + 0.5s retract, so it never cuts the motion.
            guard current == self.generation, let p = self.panel else { return }
            self.panel = nil
            p.fade(in: false)
        }
    }
}

// MARK: - Notch live

/// What the collapsed notch shows beside itself.
final class NotchModel: ObservableObject {
    @Published var nowPlaying: NowPlaying?
    /// The volume or brightness key just pressed, shown in the collapsed notch in place of the system's HUD.
    @Published var hud: NotchHUD?
    /// Set for a few seconds after the power adapter goes in: the collapsed notch shows the charge.
    @Published var charge: Battery?
    /// The cursor is on the notch: it swells a little, so the dwell before opening is felt.
    @Published var hover = false
    /// The screen is locked: the song stays private, the notch shows no player.
    @Published var locked = false
    /// The playing sound in bands, for the music bars; it publishes on its own so the rest of the notch is not redrawn with it.
    let spectrum = Spectrum()
}

/// The song Control Center shows. MediaRemote answers only Apple's own processes since macOS 15.4, so the reader runs
/// inside Apple's /usr/bin/perl, which loads Resources/libnowplaying.dylib (NowPlaying.m) and prints one JSON line.
struct NowPlaying {
    let title: String, artist: String, playing: Bool, artwork: NSImage?
    /// The artwork's average color, lifted to stay bright on black: the Dynamic Island tints its music bars with it.
    let tint: NSColor?

    init(title: String, artist: String, playing: Bool, artwork: NSImage?) {
        (self.title, self.artist, self.playing, self.artwork) = (title, artist, playing, artwork)
        tint = artwork.flatMap(NowPlaying.average)
    }

    private static let context = CIContext(options: [.workingColorSpace: NSNull()])
    static func average(_ image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        guard let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
              let out = f.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let c = NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        return NSColor(hue: c.hueComponent, saturation: min(c.saturationComponent * 1.3, 1), brightness: max(c.brightnessComponent, 0.85), alpha: 1)
    }

    static func parse(_ data: Data) -> NowPlaying? {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = d["title"] as? String, !title.isEmpty else { return nil }
        return NowPlaying(title: title, artist: d["artist"] as? String ?? "", playing: d["playing"] as? Bool ?? false,
                          artwork: (d["artwork"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:)))
    }

    /// Apple's perl, set to call one of NowPlaying.m's subs, its output on the pipe.
    private static func perl(_ sub: String) -> (Process, Pipe)? {
        guard let lib = Bundle.main.url(forResource: "libnowplaying", withExtension: "dylib") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "use DynaLoader; my $l = DynaLoader::dl_load_file($ARGV[0], 0) or exit 1; my $s = DynaLoader::dl_find_symbol($l, '\(sub)') or exit 1; DynaLoader::dl_install_xsub('main::np', $s); np();", lib.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        return (p, out)
    }

    /// Whole lines out of a pipe's chunks; the last, unfinished one stays in `buffer`.
    static func lines(_ chunk: Data, into buffer: inout Data) -> [Data] {
        buffer.append(chunk)
        var out: [Data] = []
        while let nl = buffer.firstIndex(of: 10) {
            out.append(Data(buffer[buffer.startIndex..<nl]))
            buffer = Data(buffer[(nl + 1)...])
        }
        return out
    }

    /// Live: `change` runs on the main thread now and on every change of song, artwork, play/pause or player. The
    /// reader exits when its stdin closes, so it never outlives Andeville. Keep the returned process.
    static func stream(_ change: @escaping (NowPlaying?) -> Void) -> Process? {
        guard let (p, out) = perl("andeville_now_playing_stream") else { return nil }
        p.standardInput = Pipe()
        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { h.readabilityHandler = nil; return } // EOF
            for line in lines(chunk, into: &buffer) {
                let n = parse(line)
                DispatchQueue.main.async { change(n) }
            }
        }
        do { try p.run() } catch { log("now playing stream: \(error)"); return nil }
        return p
    }
}

struct Battery {
    let level: Int, charging: Bool
    /// On the power adapter, charging or already full.
    var plugged = false

    static func read() -> Battery? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Battery(level: now * 100 / max, charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                           plugged: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }

    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        return ["battery.0percent", "battery.25percent", "battery.50percent", "battery.75percent", "battery.100percent"][min(4, (level + 12) / 25)]
    }
}

/// What the notch moves itself: the volume and brightness keys, the media keys, Siri. Volume is public API; display
/// brightness has none, so it calls the private functions System Settings uses. Not App Store safe.
enum Controls {
    private static func symbol<T>(_ library: String, _ name: String, as _: T.Type) -> T? {
        guard let h = dlopen(library, RTLD_NOW), let f = dlsym(h, name) else { log("controls: \(name) missing"); return nil }
        return unsafeBitCast(f, to: T.self)
    }

    private static let displayServices = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static var display: CGDirectDisplayID {
        notchScreen()?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    }
    static var brightness: Double? {
        get {
            var v: Float = 0
            guard let f = symbol(displayServices, "DisplayServicesGetBrightness", as: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self),
                  f(display, &v) == 0 else { return nil }
            return Double(v)
        }
        set {
            guard let newValue else { return }
            _ = symbol(displayServices, "DisplayServicesSetBrightness", as: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)?(display, Float(newValue))
        }
    }

    /// The default output's main volume, the one the volume keys move.
    private static func volumeTarget() -> (AudioDeviceID, AudioObjectPropertyAddress) {
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var which = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &which, 0, nil, &size, &device)
        return (device, AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain))
    }
    static var volume: Double? {
        get {
            var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
            var (device, address) = volumeTarget()
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &v) == noErr ? Double(v) : nil
        }
        set {
            guard var v = newValue.map({ Float32($0) }) else { return }
            var (device, address) = volumeTarget()
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    static var muted: Bool {
        get {
            var m = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
            var (device, address) = volumeTarget()
            address.mSelector = kAudioDevicePropertyMute
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &m) == noErr && m != 0
        }
        set {
            var m: UInt32 = newValue ? 1 : 0
            var (device, address) = volumeTarget()
            address.mSelector = kAudioDevicePropertyMute
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }

    /// Siri's launcher; on macOS 27 Siri comes down top-center, right under the notch.
    static func openSiri() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Siri.app")) }

    /// A two-finger swipe across the notch, by its summed horizontal travel: left is the next song, right the previous.
    /// ponytail: 50 pt of travel, calibration knob `defaults write com.ggear.faytai swipeTravel -float <pt>`.
    static func swipeKey(_ dx: CGFloat, travel: CGFloat = 50) -> Int? {
        abs(dx) < travel ? nil : dx < 0 ? 17 : 18
    }

    /// One tick on the trackpad (felt only while fingers rest on it), unless turned off in Settings.
    static func haptic() {
        if Store.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    /// The keyboard's media keys (NX_KEYTYPE_PLAY 16, NEXT 17, PREVIOUS 18), so whichever app is playing answers.
    /// ponytail: no now-playing title or artwork; MediaRemote refuses apps without Apple's entitlement since macOS 15.4.
    static func mediaKey(_ key: Int) {
        for state in [0xa, 0xb] { // down, up
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (key << 16) | (state << 8), data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// macOS's own Control Center, opened from the notch and moved to sit under it. Its modules, its grid where anything
/// goes anywhere, and its Edit Controls gallery are all Apple's: Control Center's window takes an Accessibility move
/// like any other, so it is opened with its menu bar item and moved before its open animation has run.
/// ponytail: the panel appears at its own spot for ~1 frame before the move; a learned offset makes the move immediate.
/// macOS 27's Siri ("Siri AI", com.apple.campo): one clear window as wide as the screen whose panel (the orb) hangs
/// top-center, reached through Accessibility like Control Center.
enum RealSiri {
    /// Siri's panel while it is out. Siri AI has ordinary windows too (its settings); the panel's is a system dialog.
    static func window() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.campo").first else { return nil }
        let e = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(e, 0.2)
        return (RealControlCenter.attr(e, kAXWindowsAttribute) as? [AXUIElement])?.first { RealControlCenter.attr($0, kAXSubroleAttribute) as? String == "AXSystemDialog" }
    }

    /// Puts Siri away with its panel's own close button, which leaves Siri AI running. Without the button, a quit
    /// request does it; Siri AI comes back by itself. Synthetic Escape does nothing.
    static func dismiss(_ window: AXUIElement) {
        if let b = RealControlCenter.attr(window, kAXCloseButtonAttribute), AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) == .success { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.campo").first?.terminate()
    }

    static func resize(_ w: AXUIElement, to size: CGSize) {
        var size = size
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    }

    /// Where Siri's panel sits in its window, which is what moves it. The panel hangs a fixed way under the window's
    /// middle, so in a shorter window it is higher, by half of what the height loses; and macOS will not let the
    /// window itself go above the screen (it stops at `minY`). Measured at 1512x982 and 1800x1169.
    ///
    /// Two things follow. A window short enough has its panel above its own top edge, which is how the panel gets
    /// over the top of the screen, into the notch; but what is above the window's edge is not drawn, so such a
    /// window is only right while that edge is behind the notch (left short once the orb was out, its top half was
    /// cut off). And a window that reaches into another display cannot be resized at all, only moved (measured
    /// with a second display on the right), so the height cannot follow the orb step by step as it once did, which
    /// kept the orb to one way in and out. So there are two heights (see `SiriGrip.Fit`), changed between at one
    /// place, the notch's lip, and everything else is moving.
    struct Panel {
        let window: AXUIElement
        /// The highest macOS lets the window go, the display's height, the window's width, and the panel's top
        /// under the window's top and its middle from the window's left edge, in a window as tall as the display.
        let minY: CGFloat, screen: CGFloat, width: CGFloat, offset: CGFloat, aside: CGFloat

        /// Measures a window; nil until its panel reports a frame.
        init?(_ w: AXUIElement, screen: CGFloat) {
            let c = RealControlCenter.content(of: w), f = RealControlCenter.frame(w)
            guard !c.isNull else { return nil }
            (window, self.screen, width) = (w, screen, f.width)
            offset = c.minY - f.minY - (f.height - screen) / 2
            aside = c.midX - f.minX
            RealControlCenter.move(w, to: CGPoint(x: f.minX, y: -screen)) // Asked far too high: where it stops is the limit.
            minY = RealControlCenter.frame(w).minY
        }

        /// The same window measured again where it is now (Siri shifts its panel in the window between showings),
        /// without asking how high it goes; nil when its panel reports no frame.
        init?(_ w: AXUIElement, like p: Panel) {
            let c = RealControlCenter.content(of: w), f = RealControlCenter.frame(w)
            guard !c.isNull else { return nil }
            (window, minY, screen, width) = (w, p.minY, p.screen, p.width)
            offset = c.minY - f.minY - (f.height - screen) / 2
            aside = c.midX - f.minX
        }

    }
}

/// Siri's orb in hand: taken out of the notch, moved about, put back into it, from any side. In the notch the orb
/// sits with its bottom on the notch's lower edge, the rest of it behind the notch and over the top of the screen,
/// between the notch's walls. In hand it follows the cursor: out through the notch's lower edge and from there
/// anywhere, and back the same way. Let go it stays where it is, comes down to where it rests when part of it was
/// still in the notch, or goes into the notch when less than a third of it is out.
///
/// Siri is called when the grip starts, so its window is there a moment later: it is taken out of sight in one
/// call the moment it exists (Siri fades in from the first frame), measured, given the height for the notch, and
/// from then on moved about 200 times a second (see `RealSiri.Panel`). All of it off the main thread, which
/// Accessibility calls into a busy Siri would stall.
final class SiriGrip {
    /// Siri's orb, measured off a screenshot: how tall it is, and how far its top sits under its panel's top.
    static let orb: CGFloat = 102, inset: CGFloat = 1

    /// Siri out of the notch: its window, how its panel sits in it, whether this display lets the panel be lifted
    /// over its top, and the panel where it is now (Accessibility coordinates).
    struct Out {
        let window: AXUIElement, panel: RealSiri.Panel, liftable: Bool
        var content: CGRect
    }

    /// The two windows the orb is moved in. Inside the notch, a short one whose top edge is `above` under the
    /// panel's top: moved as high as it goes, the orb is all the way in, and what it does not draw of the orb stays
    /// behind the notch as long as the panel's top is no lower than `lip`. Outside, a tall one whose top edge is
    /// `below` over the panel's top, so the whole orb is drawn, down from `lip`. At `lip` (the orb's top a little
    /// over the top of the screen, behind the notch) both are right, and that is where one is changed for the other.
    struct Fit: Equatable {
        let short: CGFloat, tall: CGFloat, above: CGFloat, below: CGFloat, lip: CGFloat

        /// nil where the two do not meet: a notch too shallow for an orb this tall. `hidden` is the panel's top in
        /// the notch, `minY` the highest the window goes, `offset` the panel's top under the top of a window as tall
        /// as the display.
        init?(hidden: CGFloat, notch: CGFloat, minY: CGFloat, offset: CGFloat, screen: CGFloat) {
            let need = minY - hidden, slack = notch - need - minY // What the short window must hide, and the room both have at the lip.
            guard slack >= 1.5 else { return nil }
            (above, below) = (need + slack / 3, slack / 3)
            (short, tall) = (screen - 2 * (offset + above), screen - 2 * (offset - below))
            lip = (minY + below + notch - above) / 2
        }
    }

    /// The display the notch is on: the orb's top while it is in the notch (its bottom on the notch's lower edge),
    /// the display's size, how far left and right the window's left edge may be when it is resized (at the
    /// display's own edge on a side where another display begins, anywhere on a side where none does), and the
    /// notch's middle and half its width.
    struct Place {
        let hidden: CGFloat, width: CGFloat, height: CGFloat, sides: (CGFloat, CGFloat), mid: CGFloat, half: CGFloat
    }

    private let lock = NSLock()
    /// The orb's middle and top wanted now (Accessibility coordinates), and whether it has been let go.
    private var spot: CGPoint
    private var free = false
    /// Whether it stays out when that is not left to where it was let go: Siri called by a click comes all the way
    /// out, and a grip that is called off goes back in.
    private var out: Bool?

    /// Starts following the cursor: with Siri called first and taken out of the notch, or, `again`, with Siri that
    /// is out already taken in hand again. `done` gets Siri on the main thread when it stayed out, nil when it went
    /// into the notch or never came.
    init(at spot: CGPoint, again: Out? = nil, on place: Place, done: @escaping (Out?) -> Void) {
        self.spot = spot
        if again == nil { Controls.openSiri() }
        DispatchQueue.global(qos: .userInteractive).async {
            let out = self.run(again, on: place)
            DispatchQueue.main.async { done(out) }
        }
    }

    func move(to spot: CGPoint) { lock.lock(); self.spot = spot; lock.unlock() }
    /// Lets the orb go. It goes into the notch when less than a third of it is out of it, and stays out otherwise,
    /// unless `out` says.
    func release(out: Bool? = nil) { lock.lock(); if !free { (free, self.out) = (true, out) }; lock.unlock() }
    private var now: (spot: CGPoint, free: Bool, out: Bool?) { lock.lock(); defer { lock.unlock() }; return (spot, free, out) }

    /// Waits for Siri's window, takes it out of sight and measures it.
    private func acquire(on place: Place) -> (AXUIElement, RealSiri.Panel)? {
        var window: AXUIElement?
        let giveUp = Date().addingTimeInterval(3)
        while window == nil, Date() < giveUp {
            window = RealSiri.window()
            if window == nil { usleep(2000) }
        }
        guard let window else { return nil }
        // Out of sight in one call, before anything is asked of it: this short, the panel is far over the top.
        RealSiri.resize(window, to: CGSize(width: place.width, height: 100))
        var measured: RealSiri.Panel?
        let wait = Date().addingTimeInterval(1.5)
        while measured == nil, Date() < wait {
            measured = RealSiri.Panel(window, screen: place.height)
            if measured == nil { usleep(2000) }
        }
        guard let panel = measured else {
            // Never measurable: a window that fills the display again, so Siri is out where it rests, not out of sight.
            RealSiri.resize(window, to: CGSize(width: place.width, height: place.height))
            return nil
        }
        return (window, panel)
    }

    private func run(_ again: Out?, on place: Place) -> Out? {
        guard let (window, panel) = again.map({ ($0.window, RealSiri.Panel($0.window, like: $0.panel) ?? $0.panel) }) ?? acquire(on: place) else { return nil }
        let notch = place.hidden + Self.orb, room = max(place.half - Self.orb / 2, 0)
        let fit = Fit(hidden: place.hidden - Self.inset, notch: notch, minY: panel.minY, offset: panel.offset, screen: place.height)
        let tall = fit?.tall ?? place.height, below = fit?.below ?? panel.offset // Without a fit: the window as tall as the display, the orb never over the top.
        let resize = { (height: CGFloat) -> Bool in
            RealSiri.resize(window, to: CGSize(width: panel.width, height: height))
            return abs(RealControlCenter.frame(window).height - height) < 2
        }
        let own = { (x: CGFloat) in min(max(x, place.sides.0), place.sides.1) } // The nearest place on its own display, where it can be resized.
        // Where things stand: the orb's middle and top, and whether the window is the short one (the orb in the notch).
        var at = CGPoint(x: now.spot.x, y: place.hidden), inside = false, liftable = again?.liftable ?? (fit != nil)
        if again == nil, let fit {
            // Just called and out of sight: the short window, as high as it goes, the orb in the notch where it is gripped.
            inside = resize(fit.short)
            liftable = inside
            if !inside { _ = resize(tall) }
        } else {
            // Out already (or no way into the notch here): the tall window, the orb where it is. Siri may have set
            // its window anew since, so it is made the tall one without the orb moving, on its own display.
            let f = RealControlCenter.frame(window), c = RealControlCenter.content(of: window)
            let top = c.isNull ? f.minY + panel.offset + (f.height - place.height) / 2 : c.minY
            at = CGPoint(x: f.minX + panel.aside, y: top + Self.inset)
            if abs(f.height - tall) >= 2 {
                RealControlCenter.move(window, to: CGPoint(x: own(f.minX), y: f.minY))
                _ = resize(tall)
                RealControlCenter.move(window, to: CGPoint(x: f.minX, y: top - below))
            }
        }
        var x = at.x - panel.aside
        // Puts the orb's middle and top at `orb`, as near as it may be; returns whether it is there.
        let put = { (orb: CGPoint) -> Bool in
            var top = max(orb.y, place.hidden) - Self.inset, middle = orb.x
            if let fit, liftable {
                let between = abs(middle - place.mid) <= room
                if inside, top > fit.lip + 0.4 {
                    // Out through the notch's lip. Moved first, the short window has the orb up in the notch for
                    // that moment, not hanging under it, and resized on its own display it is the tall one.
                    RealControlCenter.move(window, to: CGPoint(x: own(x), y: fit.lip - fit.below))
                    inside = !resize(fit.tall)
                } else if !inside, top < fit.lip - 0.4, between {
                    // In through the lip: the short window, which hides the orb for the moment until it is moved.
                    RealControlCenter.move(window, to: CGPoint(x: own(x), y: fit.lip - fit.below))
                    inside = resize(fit.short)
                }
                if inside {
                    // In the notch: between its walls, and no further out than the lip.
                    (top, middle) = (min(top, fit.lip), min(max(middle, place.mid - room), place.mid + room))
                } else {
                    top = max(top, panel.minY + fit.below) // Beside the notch, or kept out: as high as the tall window goes.
                }
            } else {
                top = max(top, panel.minY + below)
            }
            // Sideways it catches up over a few steps, so coming out of the notch's walls it does not jump to the cursor.
            x += (middle - panel.aside - x) * 0.5
            if abs(middle - panel.aside - x) < 0.5 { x = middle - panel.aside }
            RealControlCenter.move(window, to: CGPoint(x: x, y: inside ? top + (fit?.above ?? 0) : top - below))
            at = CGPoint(x: x + panel.aside, y: top + Self.inset)
            return at == orb
        }
        // Eases the orb from one place to another; the curve takes 0...1 to 0...1.
        let ease = { (from: CGPoint, to: CGPoint, duration: Double, curve: (Double) -> Double) in
            let start = Date()
            while from != to {
                let k = min(Date().timeIntervalSince(start) / duration, 1), e = CGFloat(curve(k))
                _ = put(CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e))
                if k >= 1 { break }
                usleep(4000)
            }
        }
        while true {
            let (spot, free, _) = now
            _ = put(spot)
            if free { break }
            usleep(4000)
        }
        // Where the orb really is decides: in the notch with less than a third of it out, it goes in.
        guard now.out ?? !(inside && at.y - place.hidden < Self.orb / 3) else {
            ease(at, CGPoint(x: at.x, y: place.hidden), 0.15) { $0 * $0 }
            RealSiri.dismiss(window)
            return nil
        }
        // Out: where it was let go, or down to where it rests when part of it was still in the notch.
        let stay = CGPoint(x: at.x, y: max(at.y, panel.offset + Self.inset))
        ease(at, stay, 0.25) { 1 - pow(1 - $0, 3) }
        for _ in 0..<12 where !put(stay) { usleep(8000) } // Sideways it may still be catching up.
        usleep(60_000)
        _ = put(stay) // Once more, in case Siri moved its window in between.
        let content = RealControlCenter.content(of: window)
        return Out(window: window, panel: panel, liftable: liftable,
                   content: content.isNull ? CGRect(x: stay.x - 157.5, y: stay.y - Self.inset, width: 315, height: 75) : content)
    }

    /// How far beside the notch the cursor still goes on up over the top of the screen with the orb in hand.
    static let beside: CGFloat = 180

    /// One mouse move of the cursor's way up into the notch (`App.liftCursor`): `reach` is how far over the top of
    /// the screen the cursor is, `dy` the move (down is positive), `down` how far under the top edge the cursor now
    /// shows, `room` how far up it may go. Returns the new reach and, when the cursor has to be put back, how far
    /// under the edge. Only a press made up there (`held`) holds the cursor back: without a button it is never put
    /// back and is free the moment it comes off the edge (`free`, the jitter of a click allowed), and a drag that
    /// started elsewhere does not go up at all, so the cursor cannot stick to the notch.
    static let free: CGFloat = 4
    /// `carrying` is Siri's orb in hand on its way back in: that drag does go up.
    static func lift(reach: CGFloat, dy: CGFloat, down: CGFloat, held: Bool, carrying: Bool = false, room: CGFloat) -> (reach: CGFloat, put: CGFloat?) {
        guard reach > 0 else { return (down <= 0.5 && dy < 0 && (!held || carrying) ? min(-dy, room) : 0, nil) }
        let next = min(max(reach - dy, 0), room)
        guard held else { return (down > free ? 0 : next, nil) }
        guard down > 0 else { return (next, nil) }
        // The move took the cursor off the edge: back on it, or as far under it as the move went past the way back
        // (`down` when later moves are already in it, `dy` when an earlier put-back has taken this one out of it).
        return (next, next > 0 ? 0 : max(max(down, dy) - reach, 0))
    }
}

enum RealControlCenter {
    fileprivate static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    fileprivate static func frame(_ e: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }
    fileprivate static func move(_ w: AXUIElement, to p: CGPoint) {
        var p = p
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
    }

    /// Control Center's windows: none while closed, the panel while open, more while Edit Controls is up.
    static func windows() -> [AXUIElement] {
        guard let cc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else { return [] }
        let app = AXUIElementCreateApplication(cc.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        return attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    /// The panel among Control Center's windows: the largest. A privacy indicator ("System", "… recently") floats
    /// above the panel as a window of its own, so neither "first" nor "more than one" means anything.
    static func panel(_ wins: [AXUIElement]) -> AXUIElement? {
        wins.max { frame($0).width * frame($0).height < frame($1).width * frame($1).height }
    }

    /// Edit Controls is up: its gallery is a second big window, unlike the small privacy indicator.
    static func editing(_ wins: [AXUIElement]) -> Bool {
        wins.filter { frame($0).width > 400 && frame($0).height > 300 }.count > 1
    }

    /// The panel's window is wider than what it draws (part of it hangs off screen), so the modules' union is measured.
    static func content(of w: AXUIElement) -> CGRect {
        let wf = frame(w)
        var acc = CGRect.null
        func walk(_ e: AXUIElement, _ depth: Int) {
            for c in attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                let f = frame(c)
                if f.width > 0, f.width < wf.width - 1 { acc = acc.isNull ? f : acc.union(f) } else if depth < 4 { walk(c, depth + 1) }
            }
        }
        walk(w, 0)
        return acc
    }

    /// Where the window goes so its content is centered on `midX`, its top kept.
    static func origin(window: CGRect, content: CGRect, midX: CGFloat) -> CGPoint {
        CGPoint(x: window.minX + midX - content.midX, y: window.minY)
    }

    /// Content center minus window left, learned on the first open so later ones move without measuring first.
    private static var offset: CGFloat?
    /// The open panel's content in Accessibility coordinates (top-left origin), for the hover watch.
    private(set) static var openContent: CGRect?
    /// Where the content sat last time, so the island can start growing the moment the notch is touched.
    private(set) static var lastContent: CGRect?

    /// Control Center's menu bar item, kept: finding it walks the menu bar (dozens of calls), which made every open and
    /// close slow. Asked again only when the kept one stops answering (the menu bar was rebuilt or hidden).
    private static var item: AXUIElement?
    private static func controlCenterItem() -> AXUIElement? {
        if let item, attr(item, kAXIdentifierAttribute) as? String == "com.apple.menuextra.controlcenter" { return item }
        item = find("com.apple.menuextra.controlcenter")
        return item
    }

    /// The menu bar item with this Accessibility id, found by walking the bar from the right where Apple's sit.
    private static func find(_ id: String) -> AXUIElement? {
        guard AXIsProcessTrusted(), let screen = NSScreen.screens.first else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var x = screen.frame.maxX - 2
        while x > screen.frame.midX {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(system, Float(x), 12, &hit) == .success, let el = hit {
                if attr(el, kAXIdentifierAttribute) as? String == id { return el }
                var origin = CGPoint.zero
                if let v = attr(el, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &origin) }
                x = origin.x > 0 && origin.x < x ? origin.x - 1 : x - 6
            } else { x -= 6 }
        }
        return nil
    }

    /// Presses Control Center's menu bar item and moves the panel under the notch. Blocks up to ~1.6 s, so it runs off
    /// the main thread; `done` gets the content rect on the main thread (nil when it did not open).
    static func open(centeredAt midX: CGFloat, appeared: @escaping (CGRect) -> Void = { _ in }, done: @escaping (CGRect?) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            var result: CGRect?
            defer { DispatchQueue.main.async { openContent = result; if result != nil { lastContent = result }; done(result) } }
            guard windows().isEmpty else { return }
            // A full-screen app hides the menu bar, and with it the item, until the cursor at the top slides it down.
            var found: AXUIElement?
            for _ in 0..<24 { // ≤1.2 s
                found = controlCenterItem()
                if found != nil { break }
                usleep(50_000)
            }
            guard let found else { return }
            AXUIElementPerformAction(found, kAXPressAction as CFString)
            var w: AXUIElement?
            for _ in 0..<200 { // ≤0.4 s
                if let found = panel(windows()) { w = found; break }
                usleep(2000)
            }
            guard let w else { return }
            if let offset {
                move(w, to: CGPoint(x: midX - offset, y: frame(w).minY))
                // The panel is there and in place: the island grows now, with it, not ahead of it.
                if let last = lastContent { DispatchQueue.main.async { appeared(CGRect(x: midX - last.width / 2, y: last.minY, width: last.width, height: last.height)) } }
            }
            // Mid-animation the modules may not report frames yet: a few tries, then the last known content.
            var c = CGRect.null
            for _ in 0..<6 {
                c = content(of: w)
                if !c.isNull { break }
                usleep(15_000)
            }
            let moved = frame(w)
            guard !c.isNull else { // Already moved by the learned offset, so the last content centered on midX is where it is.
                if let last = lastContent { result = CGRect(x: midX - last.width / 2, y: last.minY, width: last.width, height: last.height) }
                return
            }
            offset = c.midX - moved.minX
            let target = origin(window: moved, content: c, midX: midX)
            if abs(target.x - moved.minX) > 0.5 { move(w, to: target) }
            result = c.offsetBy(dx: target.x - moved.minX, dy: 0)
        }
    }

    /// Closes it the way a second click on its menu bar item does; nothing when it is already closed.
    static func close() {
        openContent = nil
        DispatchQueue.global(qos: .userInteractive).async {
            guard !windows().isEmpty, let item = controlCenterItem() else { return }
            AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
    }
}

/// Settings › 모양 › 글래스. Apple's public Liquid Glass (`glassEffect`) has no blur knob and on macOS frosts whatever is
/// behind it, far from the iPhone's clear glass. So the island drives Apple's renderer itself (see `Backdrop`) with a blur
/// and refraction we choose, under a dimming layer (HIG › Materials: 35% black over bright content) and a rim light.
enum GlassPrefs {
    static let blurDefault = 6.0, dimDefault = 0.35, fadeDefault = 0.35, rimDefault = 0.7, refractDefault = 0.5
    /// "r g b a" in sRGB; empty means no tint.
    static func color(_ s: String) -> Color? {
        let v = s.split(separator: " ").compactMap { Double($0) }
        return v.count == 4 && v[3] > 0 ? Color(.sRGB, red: v[0], green: v[1], blue: v[2], opacity: v[3]) : nil
    }
    static func string(_ c: Color) -> String {
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return "" }
        return "\(n.redComponent) \(n.greenComponent) \(n.blueComponent) \(n.alphaComponent)"
    }
}

/// The island's glass: Apple's own Liquid Glass renderer, the private Core Animation filter `glassBackground` that
/// NSGlassEffectView is built on, driven directly so the blur and the rim refraction are ours to choose. The public
/// API fixes both and frosts everything on macOS. The layer tree and every filter value below were read off a live
/// NSGlassEffectView (clear style) on macOS 26; only the blur and refraction differ. Not App Store safe.
/// Before macOS 26 the filter does not exist and this falls back to a plain blurred backdrop.
struct Backdrop: NSViewRepresentable {
    let blur: Double
    /// The glass face's color saturation: 1 keeps the backdrop's color, lower greys it as macOS menus do.
    var saturation = 1.0
    /// 0...1: how strongly the picture behind bends at the glass's rim. Apple's own glass is 0.5.
    var refraction = 0.0
    /// The glass body the rim follows: top-centered in the view, square top, bottom corners of `radius`.
    var body = CGSize.zero
    var radius: CGFloat = 0
    /// Seconds before a refraction change starts, so it settles in after the shape has stopped moving.
    var delay = 0.0

    final class View: NSView {
        var config: Backdrop? { didSet { apply() } }
        /// The four animated filter values: where they are headed, and what is on screen right now.
        private var values: [String: Double] = [:], shown: [String: Double] = [:]
        private var timer: Timer?
        private var element: CALayer?

        override func makeBackingLayer() -> CALayer {
            guard let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return CALayer() }
            let l = cls.init()
            l.setValue(true, forKey: "windowServerAware")
            l.setValue(1.0, forKey: "scale") // Apple samples at 0.25-0.5 to blur cheaply; full scale keeps a light blur sharp.
            return l
        }
        override func layout() {
            super.layout()
            apply() // The shape needs the view's size, which is not known when the view is made.
        }

        private static func filter(_ type: String, _ values: [String: Any]) -> NSObject? {
            guard let cls = NSClassFromString("CAFilter") as? NSObject.Type,
                  let f = cls.perform(NSSelectorFromString("filterWithType:"), with: type)?.takeUnretainedValue() as? NSObject else { return nil }
            values.forEach { f.setValue($1, forKey: $0) }
            return f
        }

        /// The filter takes its outline from a signed-distance-field sublayer, named like Apple's.
        private func shapeLayer() -> CALayer? {
            if let element { return element }
            guard let layer, let sdfClass = NSClassFromString("CASDFLayer") as? CALayer.Type,
                  let elementClass = NSClassFromString("CASDFElementLayer") as? CALayer.Type else { return nil }
            let sdf = sdfClass.init(), holder = CALayer(), el = elementClass.init()
            sdf.name = "@0"
            el.cornerCurve = .continuous
            holder.addSublayer(el)
            sdf.addSublayer(holder)
            layer.addSublayer(sdf)
            element = el
            return el
        }

        private func apply() {
            guard let c = config, let layer, bounds.width > 0 else { return }
            let glassTypes = (NSClassFromString("CAFilter") as? NSObject.Type)?.perform(NSSelectorFromString("filterTypes"))?.takeUnretainedValue() as? [String]
            guard glassTypes?.contains("glassBackground") == true, let el = shapeLayer() else {
                layer.filters = [Self.filter("gaussianBlur", ["inputRadius": c.blur, "inputNormalizeEdges": true])].compactMap { $0 }
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            el.superlayer?.superlayer?.frame = bounds
            // Taller than the view at the top, so the top corners fall outside it: only the sides and the bottom show a rim.
            let over = c.radius * 2 + 40
            let top = isFlipped ? -over : bounds.height - c.body.height
            el.frame = CGRect(x: bounds.midX - c.body.width / 2, y: top, width: c.body.width, height: c.body.height + over)
            el.cornerRadius = c.radius
            CATransaction.commit()

            // Apple's glass is amount -60 over a 20 pt rim; the slider's 50% lands exactly there.
            let targets: [(String, Double, Double)] = [
                ("inputBlurRadius", c.blur, 0), ("inputFaceColorMatrixSaturation", c.saturation, 0),
                ("inputInnerRefractionAmount", -120 * c.refraction, c.delay), ("inputInnerRefractionHeight", 40 * c.refraction, c.delay),
            ]
            if shown.isEmpty {
                targets.forEach { values[$0.0] = $0.1 }
                shown = values
                render()
                return
            }
            let changed = targets.filter { values[$0.0] != $0.1 }
            guard !changed.isEmpty else { return }
            changed.forEach { values[$0.0] = $0.1 }
            // Stepped by hand, not with CABasicAnimation: the window server does not draw a backdrop filter's animated
            // values, so the glass sat at the old values for the whole animation and snapped when it ended. Starting
            // from what is on screen also keeps a close that cuts an open short from jumping.
            let from = shown, to = values, start = CACurrentMediaTime() + (changed.map(\.2).max() ?? 0)
            timer?.invalidate()
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] t in
                guard let self else { return t.invalidate() }
                let p = min((CACurrentMediaTime() - start) / 0.3, 1)
                guard p > 0 else { return }
                let e = p * p * (3 - 2 * p)
                for (k, v) in to { shown[k] = (from[k] ?? v) + (v - (from[k] ?? v)) * e }
                render()
                if p >= 1 { t.invalidate() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        private func render() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.filters = [Self.filter("glassBackground", Self.glass.merging(shown) { $1 })].compactMap { $0 }
            CATransaction.commit()
        }

        /// Every filter value below but the four in `shown`, read off a live NSGlassEffectView.
        private static let glass: [String: Any] = [
                    "name": "glass", "inputSourceSublayerName": "@0",
                    "inputOuterRefractionAmount": 0, "inputOuterRefractionHeight": 0,
                    "inputRefractionDistance0": -1, "inputRefractionDistance1": -0.5, "inputRefractionOpacity": 0,
                    "inputBlurOpacity0": 1, "inputBlurOpacity1": 1, "inputBlurOpacity2": 1, "inputBlurOpacity3": 1, "inputBlurOpacity4": 1,
                    "inputBlurDistance0": 0, "inputBlurDistance1": 0, "inputBlurDistance2": 0, "inputBlurDistance3": 0, "inputBlurDistance4": 0,
                    "inputFaceOpacity": 1, "inputFaceColorMatrixWhite": 0.8, "inputFaceColorMatrixBlack": 0.05,
                    "inputFaceColorMatrixFillColor": CGColor(red: 1, green: 1, blue: 1, alpha: 0.05),
                    "inputBleedAmount": 0, "inputBleedHeight": 0, "inputBleedBlurRadius": 0, "inputBleedDistance0": 1, "inputBleedDistance1": 0,
                    "inputBleedOpacity": 0, "inputBleedDarkenBlend": 1,
                    "inputBleedColorMatrixWhite": 1, "inputBleedColorMatrixBlack": 0.75, "inputBleedColorMatrixSaturation": 1.2,
                    "inputShadowOffset": NSValue(size: NSSize(width: 0, height: 8)), "inputShadowAmount": 75, "inputShadowHeight": 80, "inputShadowOpacity": 0,
                    "inputShadowColorMatrixWhite": 1, "inputShadowColorMatrixBlack": 0, "inputShadowColorMatrixSaturation": 1.2,
                    "inputShadowColorMatrixFillColor": CGColor(red: 0, green: 0, blue: 0, alpha: 0.1),
                    "inputShadowDistanceOffset": 0, "inputShadowBlurRadius": 0, "inputShadowRadius": 0,
                    "inputSDRHoldingToneEnabled": 0, "inputSDRHoldingToneWhite": 1,
                    "inputSDRGradientDistance0": 0, "inputSDRGradientDistance1": 0, "inputSDRShadowOpacity": 0,
                    "inputMaxHeadroom": 9999, "inputShadowVibrancyContribution": 0, "inputClamp": 1, "inputClampPreserveHue": 0,
        ]
    }

    func makeNSView(context: Context) -> View {
        let v = View()
        v.wantsLayer = true
        v.config = self
        return v
    }
    func updateNSView(_ v: View, context: Context) { v.config = self }
}

/// Like the Dynamic Island's Siri panel: black where it meets the hardware notch, melting into clear glass below.
/// Reduce Transparency and the glass switch off keep the solid black shape.
struct IslandFill: View {
    let shape: IslandShape
    let glass: Bool
    /// Fraction of the height (the notch band) that stays fully black, so the join with the notch never shows.
    let solidTop: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("glassOn") private var glassOn = true
    @AppStorage("glassBlur") private var blur = GlassPrefs.blurDefault
    @AppStorage("glassDim") private var dim = GlassPrefs.dimDefault
    @AppStorage("glassFade") private var fade = GlassPrefs.fadeDefault
    @AppStorage("glassRim") private var rim = GlassPrefs.rimDefault
    @AppStorage("glassTint") private var tint = ""
    @AppStorage("glassRefract") private var refract = GlassPrefs.refractDefault

    var body: some View {
        if glassOn, !reduceTransparency {
            let top = min(max(solidTop, 0), 1), end = min(top + max(fade, 0.01), 1)
            // Clear glass needs its dimming layer (HIG › Materials: at least 35% black); without it Control Center's
            // Color Dodge buttons pick up a bright desktop's color at full strength.
            let floor = glass ? min(max(dim, 0.35), 1) : 1
            // The rim light starts where the black ends, so the notch band keeps a hard black edge.
            let light = LinearGradient(stops: [
                .init(color: .white.opacity(0), location: top),
                .init(color: .white.opacity(0.6), location: end),
                .init(color: .white, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            ZStack {
                Backdrop(blur: blur, refraction: glass ? refract : 0, body: CGSize(width: shape.width, height: shape.height),
                         radius: shape.radius, delay: glass ? Store.hubOpen * 0.7 : 0)
                    .clipShape(shape)
                if let c = GlassPrefs.color(tint) { shape.fill(c) }
                shape.fill(LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: top),
                    .init(color: .black.opacity(floor), location: end),
                    .init(color: .black.opacity(floor), location: 1),
                ], startPoint: .top, endPoint: .bottom))
                Group {
                    shape.stroke(light, lineWidth: 12).blur(radius: 6).opacity(0.3) // Soft inner glow: the glass's thickness.
                    shape.stroke(light, lineWidth: 2.4).opacity(0.8)                // Hairline specular edge (half is clipped away).
                }
                .clipShape(shape)
                .blendMode(.plusLighter)
                .opacity(glass ? rim : 0)
            }
        } else {
            shape.fill(.black)
        }
    }
}

struct WingStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0), in: Circle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Buttons answer the first click even though the panel never becomes key.
final class FirstMouseHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A live blur of whatever is behind it, Control Center included (a window-server backdrop layer), whose radius
/// animates: Control Center comes in out of a blur and goes out into one.
final class BlurVeil: NSView {
    private var radius = 0.0

    override func makeBackingLayer() -> CALayer {
        guard let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              let blur = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?.takeUnretainedValue() as? NSObject
        else { return CALayer() }
        let l = cls.init()
        l.setValue(true, forKey: "windowServerAware")
        blur.setValue("blur", forKey: "name")
        blur.setValue(0.0, forKey: "inputRadius")
        blur.setValue(true, forKey: "inputNormalizeEdges")
        l.filters = [blur]
        l.cornerRadius = 24
        l.cornerCurve = .continuous
        l.masksToBounds = true
        return l
    }

    func set(_ r: Double) {
        radius = r
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.setValue(r, forKeyPath: "filters.blur.inputRadius")
        CATransaction.commit()
    }

    func animate(to r: Double, duration: Double, done: (() -> Void)? = nil) {
        guard let layer else { done?(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let a = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        a.fromValue = radius
        a.toValue = r
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "blur")
        layer.setValue(r, forKeyPath: "filters.blur.inputRadius")
        CATransaction.commit()
        radius = r
    }
}

/// Andeville's island (black at the notch, melting into glass), drawn under macOS's Control Center while it is
/// open under the notch, so Control Center's modules sit on Andeville's shape. One level
/// below Control Center's window (pop-up menu level) and above the menu bar; it never takes the mouse. Above
/// Control Center sit the blur veil for its way in and out, and the wings beside the notch (Andeville's settings).
final class IslandBackdrop {
    final class State: ObservableObject {
        @Published var expanded = false
        @Published var size = CGSize.zero
    }

    struct ShapeView: View {
        @ObservedObject var state: State
        let notch: CGSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let s = state.size
            let shape = IslandShape(width: state.expanded ? s.width : notch.width, height: state.expanded ? s.height : notch.height,
                                    radius: state.expanded ? 26 : Store.notchEar, ear: Store.notchEar, minWidth: notch.width, maxWidth: max(s.width, notch.width))
            IslandFill(shape: shape, glass: state.expanded, solidTop: notch.height / max(s.height, 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipShape(shape)
                .environment(\.colorScheme, .dark)
                .animation(reduceMotion ? .easeOut(duration: 0.15)
                           : state.expanded ? .spring(response: Store.hubOpen, dampingFraction: 1 - Store.hubBounce)
                           : .spring(response: IslandBackdrop.closeTime, dampingFraction: 1), value: state.expanded)
        }
    }

    /// Beside the notch: the battery left, Andeville's settings right.
    struct WingsView: View {
        @ObservedObject var state: State
        let notch: CGSize
        let settings: () -> Void

        var body: some View {
            let side = max((state.size.width - notch.width) / 2, 0)
            HStack(spacing: 0) {
                Group {
                    if let b = Battery.read() {
                        HStack(spacing: 4) {
                            Text("\(b.level)%").font(.system(size: 11, weight: .medium)).monospacedDigit()
                            Image(systemName: b.symbol).font(.system(size: 13)).foregroundStyle(b.charging ? Color.green : b.level <= 20 ? Color.red : Color.white)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("배터리 \(b.level)%")
                    }
                }
                .padding(.leading, 16).frame(width: side, alignment: .leading)
                Spacer(minLength: 0)
                Button(action: settings) {
                    Image(systemName: "gearshape").font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28).contentShape(Circle())
                }
                .buttonStyle(WingStyle())
                .help("Andeville 설정").accessibilityLabel("Andeville 설정")
                .padding(.trailing, 12).frame(width: side, alignment: .trailing)
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: state.size.width, height: notch.height)
            .opacity(state.expanded ? 1 : 0)
            .animation(.easeOut(duration: state.expanded ? 0.25 : 0.1).delay(state.expanded ? Store.hubOpen * 0.4 : 0), value: state.expanded)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private let state = State()
    private var panel: NSPanel?, veilPanel: NSPanel?, wingsPanel: NSPanel?
    private let veil = BlurVeil()
    private var generation = 0
    var settings: () -> Void = {}
    static let padding: CGFloat = 16, blur = 22.0
    /// Control Center's own dismissal is quick (~0.1 s, measured off a 60 fps recording) and fixed, so the island folds no slower than that, even when
    /// its close is set longer.
    static var closeTime: Double { min(Store.hubClose * 0.3, 0.15) } // Control Center was measured fading in ~0.1 s.

    /// The island's size around Control Center's content (Accessibility coordinates, top of the screen at 0).
    static func size(around content: CGRect) -> CGSize {
        CGSize(width: content.width + padding * 2, height: content.maxY + padding)
    }

    /// The island in Accessibility coordinates; the cursor anywhere on it (gap under the notch included) is "over".
    static func area(around content: CGRect) -> CGRect {
        CGRect(x: content.minX - padding, y: 0, width: content.width + padding * 2, height: content.maxY + padding)
    }

    private func makePanel(level: NSWindow.Level, mouse: Bool) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.animationBehavior = .none
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = !mouse
        p.level = level
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }

    /// Grows the island to wrap `content`; with `veil`, a blur sits over the content until `reveal()`.
    /// Called again with the measured content it only resizes, so the growth already under way is not restarted.
    func show(around content: CGRect, on screen: NSScreen, veil withVeil: Bool) {
        let notch = notchSize(of: screen), size = Self.size(around: content)
        let outer = CGSize(width: size.width + Store.notchEar * 2, height: size.height)
        // Control Center's content is centered under the notch (RealControlCenter.open), so the island is too.
        let frame = NSRect(x: screen.frame.midX - outer.width / 2, y: screen.frame.maxY - outer.height, width: outer.width, height: outer.height)
        let below = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1), above = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        let p = panel ?? makePanel(level: below, mouse: false)
        let w = wingsPanel ?? makePanel(level: above, mouse: true)
        if panel == nil {
            p.contentView = NSHostingView(rootView: ShapeView(state: state, notch: notch))
            w.contentView = FirstMouseHost(rootView: WingsView(state: state, notch: notch) { [weak self] in self?.settings() })
            panel = p
            wingsPanel = w
        }
        let fresh = !p.isVisible || !state.expanded
        generation += 1
        p.setFrame(frame, display: false)
        w.setFrame(NSRect(x: frame.minX, y: screen.frame.maxY - notch.height, width: frame.width, height: notch.height), display: false)
        state.size = size
        p.alphaValue = 1
        w.alphaValue = 1
        p.orderFrontRegardless()
        w.orderFrontRegardless()
        if fresh {
            state.expanded = false
            DispatchQueue.main.async { self.state.expanded = true }
        }
        if withVeil {
            let v = veilPanel ?? makePanel(level: above, mouse: false)
            if veilPanel == nil { v.contentView = veil; veilPanel = v }
            let top = screen.frame.maxY
            v.setFrame(NSRect(x: content.minX - 6, y: top - content.maxY - 6, width: content.width + 12, height: content.height + 12), display: false)
            if fresh || !v.isVisible { veil.set(Self.blur) }
            v.alphaValue = 1 // A close cut short by this open may have left it part faded.
            v.orderFrontRegardless()
        }
    }

    /// The blur clears off Control Center: its way in.
    func reveal() {
        guard let v = veilPanel, v.isVisible else { return }
        let current = generation
        veil.animate(to: 0, duration: 0.28) { [weak self] in
            if current == self?.generation { v.orderOut(nil) }
        }
    }

    /// Control Center blurs away while the island folds into the notch, quicker than the close setting; `closed`
    /// (which closes Control Center) runs at once so nothing waits on the blur.
    func hide(blur: Bool, closed: @escaping () -> Void = {}) {
        generation += 1
        let current = generation
        guard let p = panel, p.isVisible else { veilPanel?.orderOut(nil); return closed() }
        state.expanded = false
        wingsPanel?.orderOut(nil)
        if blur, let v = veilPanel, let content = RealControlCenter.openContent ?? RealControlCenter.lastContent, let screen = notchScreen() {
            v.setFrame(NSRect(x: content.minX - 6, y: screen.frame.maxY - content.maxY - 6, width: content.width + 12, height: content.height + 12), display: false)
            veil.set(0)
            v.orderFrontRegardless()
            // Control Center is told to close now and blurs out early in the island's (shortened) fold, not after it.
            veil.animate(to: Self.blur, duration: Self.closeTime * 0.7)
            closed()
        } else {
            veilPanel?.orderOut(nil)
            closed()
        }
        // Fades while it folds, not after: the two together end as Control Center does.
        NSAnimationContext.runAnimationGroup({ $0.duration = Self.closeTime; p.animator().alphaValue = 0; self.veilPanel?.animator().alphaValue = 0 },
                                             completionHandler: {
                                                 guard current == self.generation else { return }
                                                 p.orderOut(nil)
                                                 self.veilPanel?.orderOut(nil)
                                                 self.veilPanel?.alphaValue = 1
                                             })
    }
}

/// Private login.framework call, the same one the Lock Screen menu item uses. Not App Store safe.
func lockScreenNow() {
    guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
          let f = dlsym(h, "SACLockScreenImmediate") else { return log("lock now: SACLockScreenImmediate missing") }
    typealias Lock = @convention(c) () -> Int32
    _ = unsafeBitCast(f, to: Lock.self)()
}

// MARK: - Enrollment screen

/// Tracks which directions the head has pointed in, as tick marks clockwise from the top.
struct EnrollRing {
    static let count = 60
    private(set) var filled = [Bool](repeating: false, count: count)
    private var baseTurn = 0.0, basePitch = 0.0, seen = 0
    private let settleFrames = 8, minTilt = 0.14, pitchGain = 2.0 // Knobs: faces tilt less vertically than they turn.

    var progress: Double { Double(filled.filter { $0 }.count) / Double(Self.count) }

    /// Returns true when a new tick filled in. Directions are as seen in the mirrored preview.
    mutating func feed(turn: Double, pitch: Double) -> Bool {
        if seen < settleFrames {
            baseTurn = (baseTurn * Double(seen) + turn) / Double(seen + 1)
            basePitch = (basePitch * Double(seen) + pitch) / Double(seen + 1)
            seen += 1
            return false
        }
        let dx = -(turn - baseTurn), dy = (pitch - basePitch) * pitchGain
        guard hypot(dx, dy) >= minTilt else { return false }
        let tick = Int((atan2(dx, dy) / (2 * .pi) * Double(Self.count)).rounded())
        var changed = false
        for offset in -3...3 {
            let i = ((tick + offset) % Self.count + Self.count) % Self.count
            if !filled[i] { filled[i] = true; changed = true }
        }
        return changed
    }
}

enum EnrollPhase { case intro, scanning, between, done, failed }

final class EnrollModel: ObservableObject {
    @Published var phase = EnrollPhase.intro
    @Published var round = 1
    @Published var ring = [Bool](repeating: false, count: EnrollRing.count)
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // The connection exists only once the session has a camera input.
        guard let c = (view.layer as? AVCaptureVideoPreviewLayer)?.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = true
    }
}

struct EnrollView: View {
    @ObservedObject var model: EnrollModel
    let session: AVCaptureSession
    let action: () -> Void

    private var title: String {
        switch model.phase {
        case .intro: return "얼굴 등록"
        case .scanning: return model.round == 1 ? "첫 번째 스캔" : "두 번째 스캔"
        case .between: return "첫 번째 스캔 완료"
        case .done: return "등록 완료"
        case .failed: return "등록하지 못했습니다"
        }
    }

    private var detail: String {
        switch model.phase {
        case .intro: return "노트북 카메라 앞에 혼자 앉아 밝은 곳에서 진행해 주세요. 얼굴 정보는 이 Mac에 암호화되어 저장됩니다."
        case .scanning: return "고개를 천천히 돌려 원을 채워 주세요."
        case .between: return "한 번 더 천천히 고개를 돌려 주세요."
        case .done: return "이제 얼굴로 잠금을 해제할 수 있습니다."
        case .failed: return "얼굴을 충분히 찾지 못했습니다. 혼자 밝은 곳에서 다시 시도해 주세요."
        }
    }

    private var button: String? {
        switch model.phase {
        case .intro: return "시작하기"
        case .scanning: return nil
        case .between: return "계속"
        case .done: return "완료"
        case .failed: return "다시 시도"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch model.phase {
                case .scanning:
                    CameraPreview(session: session)
                        .frame(width: 256, height: 256)
                        .clipShape(Circle())
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    ForEach(0..<EnrollRing.count, id: \.self) { i in
                        Capsule()
                            .fill(model.ring[i] ? Color.green : Color.white.opacity(0.22))
                            .frame(width: 3, height: model.ring[i] ? 20 : 12)
                            .offset(y: -150)
                            .rotationEffect(.degrees(Double(i) * 6))
                            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: model.ring[i])
                    }
                case .done, .between:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 120, weight: .light))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                case .failed:
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 120, weight: .light))
                        .foregroundStyle(.orange)
                        .transition(.scale.combined(with: .opacity))
                case .intro:
                    Image(systemName: "faceid")
                        .font(.system(size: 130, weight: .ultraLight))
                        .foregroundStyle(.white)
                        .transition(.opacity)
                }
            }
            .frame(height: 340)
            .padding(.top, 44)

            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 8)
            Text(detail)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
                .padding(.top, 10)

            Spacer(minLength: 0)
            if let button {
                Button(action: action) {
                    Text(button)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .padding(.horizontal, 32)
            }
        }
        .padding(.bottom, 32)
        .frame(width: 420, height: 640)
        .background(Color.black)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.phase)
    }
}

func makeEnrollWindow(_ view: EnrollView) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 640), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    w.titlebarAppearsTransparent = true
    w.titleVisibility = .hidden
    w.backgroundColor = .black
    w.isReleasedWhenClosed = false
    w.contentView = NSHostingView(rootView: view)
    w.center()
    return w
}

// MARK: - Keychain terms

enum Terms {
    /// Any edit to `text` asks every user to sign again; bump `version` with it so the record says which edition.
    static let version = "1"
    static let text = """
    Faytai 키체인 이용 약관

    1. 저장하는 것
    잠금화면 해제를 켜면 맥 로그인 비밀번호를 macOS 키체인에 저장하고, 같은 비밀번호를 이 Mac의 Secure Enclave 키로 암호화한 사본을 앱 데이터 폴더(login.enc)에 함께 보관합니다. 어떤 정보도 외부로 전송하지 않습니다.

    2. 앱이 대신 인증하는 것
    앱이 업데이트되어 서명이 바뀌면 macOS는 키체인 접근을 허락할지 비밀번호로 다시 묻습니다. 이 약관에 동의하면 그때마다 비밀번호를 입력하는 대신 앱이 위 사본으로 직접 인증하고, 키체인 항목을 새 버전 앞으로 다시 등록합니다.

    3. 사용 시점
    비밀번호는 등록한 얼굴이 확인된 뒤 잠금화면에 입력할 때만 꺼냅니다.

    4. 위험
    비슷한 얼굴이나 사진·영상으로 잠금이 풀릴 수 있습니다. 암호화 사본은 이 Mac 밖에서는 열 수 없지만, 이 Mac에서 같은 사용자 계정으로 실행되는 다른 프로그램은 macOS 확인 창 없이 열 수 있습니다.

    5. 철회
    설정 > 일반에서 잠금화면 해제를 끄면 키체인 항목과 사본을 모두 지웁니다.

    6. 동의서 보관
    동의한 약관 전문, 판, 서명 시각, 사용자 계정 이름, 앱 버전을 이 Mac의 앱 데이터 폴더(consent.json)에 보관합니다. 약관이 바뀌면 다시 서명해야 하며, 다시 서명하기 전까지 앱은 키체인을 대신 인증하지 않습니다.
    """
    static var digest: String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func isSigned(by record: ConsentRecord?) -> Bool { record?.termsSHA256 == digest }
}

/// One signature. Kept forever as an append-only list, so earlier editions stay on record.
struct ConsentRecord: Codable {
    let termsVersion: String
    let termsSHA256: String
    let terms: String
    let user: String
    let appVersion: String
    let signedAt: Date
}

struct ConsentView: View {
    let renewal: Bool
    let sign: () -> Void
    @State private var agreed = false

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "lock.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .padding(.top, 44)
            Text("키체인 이용 동의")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 14)
            Text(renewal ? "약관이 갱신되어 다시 서명이 필요합니다 · \(Terms.version)판" : "약관 \(Terms.version)판")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ScrollView {
                Text(Terms.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 28)
            .padding(.top, 20)
            Toggle("위 약관을 읽었으며 동의합니다", isOn: $agreed)
                .toggleStyle(.checkbox)
                .padding(.top, 16)
            Button(action: sign) {
                Text("서명하고 동의")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!agreed)
            .opacity(agreed ? 1 : 0.4)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 28)
            .padding(.top, 14)
            Text("얼굴로 서명하며, 얼굴이 맞지 않으면 Touch ID 또는 비밀번호로 서명합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .padding(.bottom, 24)
        .frame(width: 460, height: 640)
    }
}

func makeConsentWindow(_ view: ConsentView) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    w.titlebarAppearsTransparent = true
    w.titleVisibility = .hidden
    w.isReleasedWhenClosed = false
    w.contentView = NSHostingView(rootView: view)
    w.center()
    return w
}

// MARK: - Ultrasonic presence

func sonarLog(_ s: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Andeville-sonar.log")
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        _ = try? h.seekToEnd()
        h.write(Data(line.utf8))
        try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Chirp (FMCW) presence experiment

struct ChirpMetrics {
    let gate: Float // dB of frame-to-frame change where a seated person would be.
    let noise: Float // dB of the same measure far beyond the room's echoes.
    let direct: Float // dB of the speaker-to-mic path.
    var score: Float { gate - noise }
}

/// Separates echoes by travel time, then measures how much the echoes at seated-person range change.
final class ChirpDetector {
    static let rate = 48000.0, period = 1920, f0 = 18000.0, f1 = 22000.0
    // Lags after the direct path, in samples of round trip (about 3.6 mm of distance each).
    static let gate = 70...250, noiseGate = 900...980

    /// One sweep, tapered at both ends so the repeats do not click.
    static func chirp() -> (i: [Float], q: [Float]) {
        let n = period, duration = Double(n) / rate, slope = (f1 - f0) / duration
        var i = [Float](repeating: 0, count: n), q = i
        for k in 0..<n {
            let t = Double(k) / rate
            let phase = 2 * Double.pi * (f0 * t + 0.5 * slope * t * t)
            let edge = n / 12
            let taper = k < edge ? 0.5 - 0.5 * cos(.pi * Double(k) / Double(edge)) : k > n - edge ? 0.5 - 0.5 * cos(.pi * Double(n - k) / Double(edge)) : 1
            i[k] = Float(cos(phase) * taper)
            q[k] = Float(sin(phase) * taper)
        }
        return (i, q)
    }

    private let refI: [Float], refQ: [Float]
    private let lags: [Int] = Array(0...0) + Array(gate) + Array(noiseGate)
    private var x: [Float] = []
    private var anchor: Int?
    private var frames = 0
    private var skip = Int(rate) // One second, for the fade-in and the audio path to start.
    private var bgI: [Float] = [], bgQ: [Float] = []
    private let guardBand = 16, alpha: Float = 0.04
    private(set) var directLag: Int?

    init() { (refI, refQ) = Self.chirp() }

    private func correlate(_ start: Int) -> (Float, Float) {
        var a: Float = 0, b: Float = 0
        x.withUnsafeBufferPointer { p in
            vDSP_dotpr(p.baseAddress! + start, 1, refI, 1, &a, vDSP_Length(Self.period))
            vDSP_dotpr(p.baseAddress! + start, 1, refQ, 1, &b, vDSP_Length(Self.period))
        }
        return (a, b)
    }

    private func strongest(_ range: ClosedRange<Int>) -> Int {
        var best = range.lowerBound, top: Float = -1
        for i in range {
            let (a, b) = correlate(i)
            let m = a * a + b * b
            if m > top { top = m; best = i }
        }
        return best
    }

    func feed(_ samples: [Float]) -> [ChirpMetrics] {
        x += samples
        var out: [ChirpMetrics] = []
        if anchor == nil {
            // Locking on before the sound has started would anchor everything to noise.
            if skip > 0 {
                let n = min(skip, x.count)
                x.removeFirst(n)
                skip -= n
            }
            guard skip == 0, x.count >= 3 * Self.period else { return [] }
            let mags = (0..<Self.period).map { lag -> Float in
                let (u, v) = correlate(lag)
                return hypot(u, v)
            }
            let found = mags.indices.max { mags[$0] < mags[$1] } ?? 0
            guard mags[found] > 20 * max(mags.sorted()[mags.count / 2], 1e-9) else {
                x.removeFirst(Self.period)
                return []
            }
            directLag = found
            anchor = found + guardBand >= Self.period ? found : found + Self.period
        }
        let reach = Self.noiseGate.upperBound + Self.period + guardBand
        while var a = anchor, a + reach < x.count {
            frames += 1
            if frames % 50 == 0 { // Input and output clocks drift apart slowly.
                let peak = strongest((a - 3)...(a + 3))
                if peak != a {
                    a = peak
                    bgI = []
                    bgQ = []
                }
            }
            let (d0, d1) = correlate(a)
            let direct = max(hypot(d0, d1), 1e-9)
            var res = [Float](repeating: 0, count: lags.count)
            var nowI = res, nowQ = res
            for (j, lag) in lags.enumerated() {
                let (u, v) = correlate(a + lag)
                nowI[j] = u / direct
                nowQ[j] = v / direct
            }
            if bgI.isEmpty {
                bgI = nowI
                bgQ = nowQ
            }
            for j in lags.indices {
                let di = nowI[j] - bgI[j], dq = nowQ[j] - bgQ[j]
                res[j] = di * di + dq * dq
                bgI[j] += alpha * di
                bgQ[j] += alpha * dq
            }
            let gateCount = Self.gate.count
            let gate = res[1..<(1 + gateCount)].reduce(0, +) / Float(gateCount)
            let noise = res[(1 + gateCount)...].reduce(0, +) / Float(Self.noiseGate.count)
            out.append(ChirpMetrics(gate: 10 * log10(max(gate, 1e-14)), noise: 10 * log10(max(noise, 1e-14)), direct: 20 * log10(direct)))
            let next = a + Self.period
            let drop = max(0, next - guardBand)
            x.removeFirst(drop)
            anchor = next - drop
        }
        return out
    }
}

/// Fires when someone arrives: only after the seat has been empty, so locking while seated stays locked.
/// Thresholds come from measurements here: seated scored 16-20, an empty seat 1-3. Other rooms may need retuning.
struct ChirpPresence {
    let high: Float, low: Float
    var arriveFrames = 25, emptyFrames = 50 // At 25 frames per second: one second present, two seconds empty.
    private var smooth: Float = 0, started = false
    private var above = 0, below = 0, armed = false

    /// Sensitivity 1-10: 10 is the most eager. The scale stays above where an empty seat scored.
    init(sensitivity: Double = 6) {
        let level = Float(min(max(sensitivity, 1), 10))
        high = 8 - (level - 1) * 4 / 9      // 8 at level 1 (old most-sensitive) down to 4 at level 10
        low = max(high - 2, 3.5)            // stays above the ~1-3 an empty seat scores, so arming still works
    }

    mutating func feed(_ score: Float) -> Bool {
        smooth = started ? smooth + 0.05 * (score - smooth) : score
        started = true
        below = smooth < low ? below + 1 : 0
        above = smooth >= high ? above + 1 : 0
        if below >= emptyFrames { armed = true }
        guard armed, above >= arriveFrames else { return false }
        armed = false
        return true
    }
}

/// Plays repeating chirps through the speakers and logs how the echoes change.
final class ChirpProbe {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "faytai.chirp")
    private let detector = ChirpDetector()
    private var collected: [ChirpMetrics] = []
    private var onMetrics: ((ChirpMetrics) -> Void)?
    private var running = false

    func start(onMetrics: @escaping (ChirpMetrics) -> Void) -> Bool {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let outRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sonarLog("chirp start inRate=\(inFormat.sampleRate) outRate=\(outRate) channels=\(inFormat.channelCount)")
        guard inFormat.sampleRate == ChirpDetector.rate, outRate == ChirpDetector.rate, inFormat.channelCount > 0 else {
            sonarLog("chirp FAILED: needs 48 kHz input and output")
            return false
        }
        self.onMetrics = onMetrics
        let wave = ChirpDetector.chirp().i
        var index = 0, gain: Float = 0
        let fade = Float(1 / (0.4 * outRate)) // A sudden start would be audible.
        let source = AVAudioSourceNode(format: AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 1)!) { _, _, frames, list in
            let out = UnsafeMutableAudioBufferListPointer(list)[0].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(frames) {
                gain = min(1, gain + fade)
                out[i] = wave[index] * 0.25 * gain
                index = (index + 1) % wave.count
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: nil)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self, let c = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: c, count: Int(buffer.frameLength)))
            self.queue.async {
                for m in self.detector.feed(samples) { self.onMetrics?(m) }
            }
        }
        do { try engine.start() } catch {
            sonarLog("chirp FAILED: \(error)")
            input.removeTap(onBus: 0)
            return false
        }
        running = true
        return true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func run(label: String, seconds: Double, done: @escaping () -> Void) {
        sonarLog("chirp run label=\(label)")
        let ok = start { [weak self] m in
            guard let self else { return }
            self.collected.append(m)
            if self.collected.count % 25 == 0 {
                sonarLog(String(format: "  chirp gate %.1f  noise %.1f  direct %.1f  score %.1f", m.gate, m.noise, m.direct, m.score))
            }
        }
        guard ok else { return done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            self.stop()
            self.queue.async {
                self.summarize(label)
                DispatchQueue.main.async(execute: done)
            }
        }
    }

    private func summarize(_ label: String) {
        // The first three seconds hold the fade-in and the background settling.
        let m = Array(collected.dropFirst(75))
        guard !m.isEmpty else { return sonarLog("chirp result label=\(label) FAILED: no frames") }
        let score = m.map(\.score).sorted(), gate = m.map(\.gate).sorted()
        let mean = score.reduce(0, +) / Float(score.count)
        let sd = sqrt(score.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(score.count))
        sonarLog(String(format: "chirp result label=%@ frames=%d direct=%.1f gate p50=%.1f score mean=%.2f sd=%.2f p10=%.2f p50=%.2f p90=%.2f lag=%d",
                        label, m.count, m.map(\.direct).reduce(0, +) / Float(m.count), gate[gate.count / 2], mean, sd,
                        score[score.count / 10], score[score.count / 2], score[score.count * 9 / 10], detector.directLag ?? -1))
    }
}

// MARK: - AirPods presence experiment

/// Away detection: ultrasound only, AirPods only, or AirPods while connected and ultrasound otherwise.
enum PresenceMode: String { case sonar, auto, airpods }

enum AirPods {
    // ponytail: matched by name, so renamed AirPods are missed; match the product ID (system_profiler) if that matters.
    static func connected() -> IOBluetoothDevice? {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first {
            $0.isConnected() && ($0.name ?? "").localizedCaseInsensitiveContains("AirPods")
        }
    }
}

/// Armed once the AirPods signal stays weak (away), fires when it turns strong again (back at the desk).
struct AirPodsPresence {
    let near: Float, far: Float
    var arriveTicks = 2, awayTicks = 10 // At 2 ticks per second: one second near, five seconds away.
    private var smooth: Float = 0, started = false
    private var above = 0, below = 0, armed = false

    /// Sensitivity 1-10: 10 counts you back from farther away. Back at -52 dBm (level 1) to -70 (level 10); away is 12 dB weaker.
    init(sensitivity: Double = 6) {
        near = -52 - (Float(min(max(sensitivity, 1), 10)) - 1) * 2
        far = near - 12
    }

    mutating func feed(_ rssi: Int) -> Bool {
        smooth = started ? smooth + 0.3 * (Float(rssi) - smooth) : Float(rssi)
        started = true
        below = smooth <= far ? below + 1 : 0
        above = smooth >= near ? above + 1 : 0
        if below >= awayTicks { armed = true }
        guard armed, above >= arriveTicks else { return false }
        armed = false
        return true
    }
}

// MARK: - Settings window

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, face, appLock, sensitivity, labs
    var id: String { rawValue }

    /// Sidebar sections: the notch first, face unlock as one of its features.
    static let groups: [(title: String, pages: [SettingsPage])] = [
        ("노치", [.general, .appearance]), ("얼굴 잠금", [.face, .appLock, .sensitivity]), ("실험", [.labs]),
    ]

    var title: String {
        switch self {
        case .general: return "일반"
        case .appearance: return "모양"
        case .face: return "얼굴"
        case .appLock: return "앱 잠금"
        case .sensitivity: return "인식 감도"
        case .labs: return "실험실"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintpalette.fill"
        case .face: return "faceid"
        case .appLock: return "lock.app.dashed"
        case .sensitivity: return "slider.horizontal.3"
        case .labs: return "flask.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .appearance: return .pink
        case .face: return .green
        case .appLock: return .blue
        case .sensitivity: return .orange
        case .labs: return .purple
        }
    }
}

struct LockedApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
}

final class SettingsModel: ObservableObject {
    @Published var page: SettingsPage? = .general
    @Published var hasPassword = false
    @Published var consent: ConsentRecord?
    @Published var loginItem = false
    @Published var faceCount = 0
    @Published var lockedApps: [LockedApp] = []
    @Published var airpodsConnected = false
}

struct SettingsActions {
    var enroll: () -> Void = {}
    var test: () -> Void = {}
    var togglePassword: () -> Void = {}
    var revealConsent: () -> Void = {}
    var toggleLogin: () -> Void = {}
    var addApp: () -> Void = {}
    var removeApp: (String) -> Void = { _ in }
}

struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        NavigationSplitView {
            List(selection: $model.page) {
                ForEach(SettingsPage.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.pages) { page in
                            Label {
                                Text(page.title)
                            } icon: {
                                SettingsIcon(symbol: page.symbol, tint: page.tint)
                            }
                            .tag(page)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 215, ideal: 215, max: 215)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let page = model.page ?? .general
            Group {
                switch page {
                case .general: GeneralPage(model: model, actions: actions)
                case .appearance: AppearancePage(model: model)
                case .face: facePage
                case .appLock: AppLockPage(model: model, actions: actions)
                case .sensitivity: SensitivityPage()
                case .labs: LabsPage(model: model)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(page.title)
        }
    }

    private var facePage: some View {
        Form {
            Section {
                LabeledContent("상태", value: model.faceCount > 0 ? "등록됨" : "미등록")
                LabeledContent("등록 샘플", value: "\(model.faceCount)개")
                LabeledContent("저장 위치", value: "Secure Enclave로 암호화")
            } footer: {
                Text("얼굴 정보는 이 Mac에만 저장되며 외부로 전송되지 않습니다.")
            }
            Section {
                LabeledContent(model.faceCount > 0 ? "얼굴 다시 등록" : "얼굴 등록") {
                    Button(model.faceCount > 0 ? "다시 등록…" : "등록…", action: actions.enroll)
                }
                LabeledContent("인식 테스트") {
                    Button("테스트", action: actions.test).disabled(model.faceCount == 0)
                }
            }
        }
    }
}

struct AppearancePage: View {
    @ObservedObject var model: SettingsModel
    @AppStorage("hubRealCC") private var realCC = true
    @AppStorage("notchEar") private var notchEar = Store.notchEarDefault

    var body: some View {
        Form {
            Section {
                Toggle("노치에서 macOS 제어 센터 열기", isOn: $realCC)
            } footer: {
                Text("켜면 노치에 커서를 올렸을 때 macOS의 실제 제어 센터가 노치 바로 아래에 열립니다. 모듈 추가·배치는 제어 센터 아래의 '컨트롤 편집'에서 macOS 그대로 합니다. 끄면 노치에서 아무것도 열리지 않습니다. 전체 화면 앱에서는 메뉴 막대가 내려온 뒤에 제어 센터가 열립니다. Andeville 설정은 노치를 오른쪽 클릭해 엽니다.")
            }
            Section {
                LabeledContent("모서리 라운드") {
                    HStack {
                        Slider(value: $notchEar, in: Store.notchEarRange, step: 1).frame(width: 190).labelsHidden()
                        Text("\(Int(notchEar))pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    }
                }
            } footer: {
                Text("노치의 둥근 모서리 크기입니다. 화면 상단과 만나는 곳과 접힌 노치 아래쪽 모서리가 같은 값으로 둥글어집니다. 데스크톱과 잠금화면에서 항상 표시되며, 노치와 Face ID 표시에 같이 적용됩니다. 기본값이자 최소값은 7pt입니다.")
            }
        }
    }
}

/// Settings › 모양 › 글래스: every Liquid Glass lever Apple offers, applied to the island under Control Center.
struct GlassSection: View {
    @AppStorage("glassOn") private var glassOn = true
    @AppStorage("glassBlur") private var blur = GlassPrefs.blurDefault
    @AppStorage("glassDim") private var dim = GlassPrefs.dimDefault
    @AppStorage("glassFade") private var fade = GlassPrefs.fadeDefault
    @AppStorage("glassRim") private var rim = GlassPrefs.rimDefault
    @AppStorage("glassTint") private var tint = ""
    @AppStorage("glassRefract") private var refract = GlassPrefs.refractDefault

    private func slider(_ title: String, _ value: Binding<Double>, in range: ClosedRange<Double> = 0...1, label: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range).frame(width: 190).labelsHidden()
                Text(label).monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
            }
        }
    }
    private func percent(_ title: String, _ value: Binding<Double>) -> some View {
        slider(title, value, label: "\(Int((value.wrappedValue * 100).rounded()))%")
    }

    private func tintRow(_ title: String, _ value: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                ColorPicker(title, selection: Binding(get: { GlassPrefs.color(value.wrappedValue) ?? .clear },
                                                      set: { value.wrappedValue = GlassPrefs.string($0) }),
                            supportsOpacity: true).labelsHidden()
                Button("없음") { value.wrappedValue = "" }.disabled(value.wrappedValue.isEmpty)
            }
        }
    }

    var body: some View {
        Section {
            Toggle("글래스 효과", isOn: $glassOn)
            Group {
                slider("흐림", $blur, in: 0...40, label: "\(Int(blur.rounded()))pt")
                percent("어둡기", $dim)
                percent("굴절", $refract)
                percent("가장자리 빛", $rim)
                percent("검정→글래스 전환 길이", $fade)
                tintRow("배경 틴트", $tint)
                LabeledContent("기본값으로 되돌리기") {
                    Button("되돌리기") {
                        blur = GlassPrefs.blurDefault
                        dim = GlassPrefs.dimDefault
                        fade = GlassPrefs.fadeDefault
                        rim = GlassPrefs.rimDefault
                        refract = GlassPrefs.refractDefault
                        tint = ""
                    }
                }
            }
            .disabled(!glassOn)
        } header: {
            Text("글래스")
        } footer: {
            Text("제어 센터 뒤 Andeville 배경의 유리입니다. 흐림은 유리 뒤가 흐려지는 정도로, 0pt면 맑은 유리, 클수록 불투명 유리가 됩니다. 어둡기는 유리에 까는 검정의 양입니다(100%면 완전한 검정). 애플 지침대로 맑은 유리에는 최소 35%가 깔립니다. 굴절은 유리 가장자리에서 뒤 화면이 휘어 보이는 정도, 가장자리 빛은 유리 테두리에 맺히는 빛의 세기, 전환 길이는 노치 아래에서 검정이 유리로 바뀌는 구간의 길이입니다. 틴트는 유리에 색을 입힙니다. '투명도 줄이기'를 켜 두면 항상 검정으로 표시됩니다.")
        }
    }
}

struct GeneralPage: View {
    @ObservedObject var model: SettingsModel
    let actions: SettingsActions
    @State private var updateStatus = ""
    @State private var downloadURL: URL?
    @State private var checking = false
    @AppStorage("hubOpen") private var hubOpen = Store.hubTimingDefault.open
    @AppStorage("hubClose") private var hubClose = Store.hubTimingDefault.close
    @AppStorage("hubDwell") private var hubDwell = Store.hubTimingDefault.dwell
    @AppStorage("hubLeave") private var hubLeave = Store.hubTimingDefault.leave
    @AppStorage("hubBounce") private var hubBounce = Store.hubBounceDefault
    @AppStorage("hoverSpeed") private var hoverSpeed = Store.hoverSpeedDefault
    @AppStorage("hubClickOpen") private var hubClickOpen = false
    @AppStorage("liveActivity") private var liveActivity = true
    @AppStorage("notchGestures") private var notchGestures = true
    @AppStorage("haptics") private var haptics = true
    @AppStorage("notchHUD") private var notchHUD = true

    private func timeSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double> = 0.15...1.2, step: Double = 0.05) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 190).labelsHidden()
                Text(String(format: "%.2f초", value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
            }
        }
    }


    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var consentStatus: String {
        guard let c = model.consent else { return "서명 안 함" }
        guard Terms.isSigned(by: c) else { return "약관 갱신됨 · 다시 서명 필요" }
        return "\(c.termsVersion)판 · \(c.signedAt.formatted(date: .abbreviated, time: .omitted)) 서명"
    }

    var body: some View {
        Form {
            Section {
                Picker("여는 방식", selection: $hubClickOpen) {
                    Text("노치에 커서 올리기").tag(false)
                    Text("노치 클릭").tag(true)
                }
                Toggle("라이브 활동 (재생 중인 곡 · 충전을 노치 옆에 표시)", isOn: $liveActivity)
                Toggle("노치에서 두 손가락 스와이프로 이전 · 다음 곡", isOn: $notchGestures)
                Toggle("음량 · 밝기 키를 노치에 표시 (시스템 HUD 대신)", isOn: $notchHUD)
                Toggle("트랙패드 햅틱", isOn: $haptics)
                timeSlider("감지 속도", value: $hubDwell, range: 0...0.5, step: 0.01).disabled(hubClickOpen)
                timeSlider("닫힘 감지 속도", value: $hubLeave, range: 0...0.6, step: 0.01)
                timeSlider("호버 반응 속도", value: $hoverSpeed, range: 0.1...1.2)
                timeSlider("펼치는 속도", value: $hubOpen)
                timeSlider("접히는 속도", value: $hubClose)
                LabeledContent("튕김") {
                    HStack {
                        Slider(value: $hubBounce, in: 0...0.6, step: 0.02).frame(width: 190).labelsHidden()
                        Text(hubBounce == 0 ? "끔" : "\(Int((hubBounce * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    }
                }
                LabeledContent("기본값으로 되돌리기") {
                    Button("되돌리기") {
                        hubDwell = Store.hubTimingDefault.dwell
                        hubLeave = Store.hubTimingDefault.leave
                        hubOpen = Store.hubTimingDefault.open
                        hubClose = Store.hubTimingDefault.close
                        hubBounce = Store.hubBounceDefault
                        hoverSpeed = Store.hoverSpeedDefault
                    }
                }
            } header: {
                Text("노치")
            } footer: {
                Text("데스크톱에서 노치에 커서를 올리거나(또는 노치를 클릭하면) 열리는 제어 센터의 여는 방식과 동작 속도입니다. 노치 클릭에서는 감지 속도를 쓰지 않습니다. 펼치는·접히는 속도는 다음에 열 때부터 적용됩니다. 감지 속도는 노치에 커서가 머물러야 열리는 시간, 닫힘 감지 속도는 커서가 제어 센터 밖으로 나간 뒤 닫히기까지의 시간이고(0초면 즉시, 두 감지 속도는 바로 적용), 호버 반응 속도는 커서를 올렸을 때 노치가 살짝 커지는 데 걸리는 시간, 펼치는·접히는 속도는 움직이는 데 걸리는 시간입니다. 모두 짧을수록 빠릅니다. 튕김은 펼쳐질 때(얼굴 잠금 표시 포함) 끝에서 살짝 넘쳤다 돌아오는 정도이고, 0이면 튕기지 않습니다. 접힐 때는 노치 밖으로 넘치지 않도록 튕기지 않습니다.")
            }
            Section {
                Toggle("잠금화면 해제", isOn: Binding(get: { model.hasPassword }, set: { _ in actions.togglePassword() }))
                LabeledContent("키체인 동의") {
                    HStack(spacing: 10) {
                        Text(consentStatus).font(.callout).foregroundStyle(Terms.isSigned(by: model.consent) ? Color.secondary : Color.orange)
                        Button(model.consent == nil ? "약관 보기…" : "동의서 보기", action: actions.revealConsent)
                    }
                }
            } header: {
                Text("얼굴 잠금")
            } footer: {
                Text("잠금화면에서 커서를 노치에 올리면 얼굴을 확인해 잠금을 해제합니다. 맥 로그인 비밀번호는 키체인에 저장되며, 약관에 서명하면 macOS가 키체인 비밀번호를 다시 물을 때 앱이 대신 인증합니다.")
            }
            Section {
                Toggle("로그인 시 시작", isOn: Binding(get: { model.loginItem }, set: { _ in actions.toggleLogin() }))
            }
            Section {
                LabeledContent("버전", value: version)
                LabeledContent("앱 업데이트") {
                    HStack(spacing: 10) {
                        if !updateStatus.isEmpty {
                            Text(updateStatus).font(.callout).foregroundStyle(.secondary)
                        }
                        if let downloadURL {
                            Button("다운로드") { NSWorkspace.shared.open(downloadURL) }
                        }
                        Button(Self.newerBuildOnDisk ? "업데이트" : "업데이트 확인", action: checkForUpdate).disabled(checking)
                    }
                }
            } header: {
                Text("정보")
            } footer: {
                Text("이 Mac에서 새로 빌드한 앱이 있으면 버튼이 '업데이트'로 바뀌고, 누르면 앱을 다시 실행해 바로 적용합니다. 다른 경우 새 버전은 DMG를 설치해 적용하며, 업데이트 피드를 설정하면 여기서 새 버전을 확인할 수 있습니다.")
            }
        }
    }

    /// True when the app's executable was rewritten (e.g. by build.sh or make-dmg.sh install) after this process started.
    static var newerBuildOnDisk: Bool {
        var kp = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride, mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, let exe = Bundle.main.executablePath,
              let built = (try? FileManager.default.attributesOfItem(atPath: exe))?[.modificationDate] as? Date else { return false }
        let t = kp.kp_proc.p_un.__p_starttime
        return built > Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6)
    }

    /// Waits for this process to exit, then reopens the same bundle so the new build loads.
    static func relaunch() {
        // The running build is the one the keychain already trusts: fill the consented copy now so the new build never prompts.
        DispatchQueue.global().async {
            Store.syncSecret()
            DispatchQueue.main.async { reopen() }
        }
    }

    private static func reopen() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// Checks an optional JSON feed {"version":"x.y","url":"https://…"} at the `updateFeedURL` default.
    private func checkForUpdate() {
        if Self.newerBuildOnDisk { return Self.relaunch() }
        downloadURL = nil
        let feed = UserDefaults.standard.string(forKey: "updateFeedURL") ?? ""
        guard let url = URL(string: feed), !feed.isEmpty else {
            updateStatus = "새 DMG로 업데이트합니다"
            return
        }
        checking = true
        updateStatus = "확인 중…"
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                checking = false
                guard let data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let latest = json["version"] as? String else {
                    updateStatus = "확인할 수 없습니다"
                    return
                }
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                if latest.compare(current, options: .numeric) == .orderedDescending {
                    updateStatus = "새 버전 \(latest)"
                    if let u = json["url"] as? String { downloadURL = URL(string: u) }
                } else {
                    updateStatus = "최신 버전입니다"
                }
            }
        }.resume()
    }
}

struct AppLockPage: View {
    @ObservedObject var model: SettingsModel
    let actions: SettingsActions
    @State private var selected: String?

    var body: some View {
        Form {
            Section {
                if model.lockedApps.isEmpty {
                    Text("잠근 앱 없음").foregroundStyle(.secondary)
                }
                ForEach(model.lockedApps) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
                        Text(app.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .listRowBackground(selected == app.id ? Color.accentColor.opacity(0.35) : nil)
                    .onTapGesture { selected = app.id }
                }
                HStack(spacing: 14) {
                    Button(action: actions.addApp) { Image(systemName: "plus") }
                        .accessibilityLabel("앱 추가")
                    Divider().frame(height: 14)
                    Button {
                        if let selected { actions.removeApp(selected) }
                        selected = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selected == nil)
                    .accessibilityLabel("선택한 앱 제거")
                    Spacer()
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("잠근 앱은 열 때 얼굴을 확인합니다. 인식에 실패하면 Touch ID나 비밀번호를 쓸 수 있고, 앱을 목록에서 뺄 때도 인증이 필요합니다.")
            }
        }
    }
}

struct SensitivityPage: View {
    @AppStorage("sfaceThreshold") private var distance = 0.5
    @AppStorage("liveThreshold") private var live = 0.5
    @AppStorage("fillLight") private var fillLight = true
    @AppStorage("darkLuma") private var darkLuma = 50.0
    @AppStorage("lockAwake") private var lockAwake = false

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 190).labelsHidden()
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    var body: some View {
        Form {
            Section {
                slider("얼굴 일치 기준", value: $distance, range: 0.3...0.7, step: 0.01, format: "%.2f")
                slider("실물 판정 기준", value: $live, range: 0...1, step: 0.01, format: "%.2f")
            } footer: {
                Text("얼굴 일치 기준은 낮을수록, 실물 판정 기준은 높을수록 엄격합니다. 실물 판정을 0으로 두면 사진 방어가 꺼집니다. 다음 인식부터 적용됩니다.")
            }
            Section {
                Toggle("어두울 때 화면 조명 사용", isOn: $fillLight)
                slider("조명을 켤 어두움 기준", value: $darkLuma, range: 20...90, step: 1, format: "%.0f").disabled(!fillLight)
            } footer: {
                Text("주변이 어두우면 인식하는 동안 화면을 하얗게 켜서 얼굴을 비춥니다. 다음 인식부터 적용됩니다.")
            }
            Section {
                Toggle("잠금화면에서 깨어 있기", isOn: $lockAwake)
            } footer: {
                Text("잠겨 있는 동안 화면과 Mac이 잠들지 않습니다. 덮개를 닫으면 평소처럼 잠듭니다. 다음 잠금부터 적용됩니다.")
            }
            Section {
                LabeledContent("기본값으로 되돌리기") {
                    Button("되돌리기") {
                        distance = 0.5
                        live = 0.5
                        fillLight = true
                        darkLuma = 50
                    }
                }
            }
        }
    }
}

struct LabsPage: View {
    @ObservedObject var model: SettingsModel
    @AppStorage("presenceOn") private var on = Store.presenceOn
    @AppStorage("presenceMode") private var mode = PresenceMode.auto.rawValue
    @AppStorage("sonarSensitivity") private var sonarSensitivity = 6.0
    @AppStorage("airpodsSensitivity") private var airpodsSensitivity = 6.0

    private var picked: PresenceMode { PresenceMode(rawValue: mode) ?? .auto }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    PresencePicker(mode: $mode, on: $on, sonar: $sonarSensitivity, airpods: $airpodsSensitivity)
                } label: {
                    Text("자리 비움 감지")
                    Text(on ? "\(["sonar": "초음파", "airpods": "에어팟"][mode, default: "Auto"]) · 민감도 \(Int(picked == .airpods ? airpodsSensitivity : sonarSensitivity))" : "꺼짐")
                        .monospacedDigit()
                }
                .onChange(of: on) { _, on in
                    if on { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
                }
            } header: {
                Text("실험 기능")
            } footer: {
                Text(footer)
            }
        }
    }

    private var footer: String {
        let common = "잠금 중에 자리를 비웠다가 돌아오면 자동으로 얼굴 인식을 시작합니다. 앉은 채로 잠갔다면 자리를 비웠다가 돌아와야 하고, 그 전에는 노치에 커서를 올려 주세요. 선택한 방식의 손잡이를 좌우로 밀어 민감도를 조절합니다(왼쪽 낮음, 오른쪽 높음). Auto에서는 두 감지의 민감도를 함께 맞춥니다. 민감도를 높이면 더 잘 감지하지만 사람이 없어도 시작될 수 있습니다. 선택된 손잡이를 누르면 꺼지고 켜집니다."
        let sonar = "초음파: 스피커로 18~22kHz 소리를 내고 반사음으로 앞자리를 확인합니다. 소리는 저장되지 않으며 이어폰이 연결되어 있으면 동작하지 않습니다."
        let airpods = "에어팟: 연결된 에어팟의 블루투스 신호 세기로 멀어졌다 가까워지는 것을 확인합니다. 에어팟이 연결되어 있을 때만 동작합니다."
        let now = model.airpodsConnected ? "지금은 에어팟이 연결되어 있습니다." : "지금은 연결된 에어팟이 없습니다."
        switch picked {
        case .sonar: return [common, sonar].joined(separator: "\n\n")
        case .airpods: return [common, airpods, now].joined(separator: "\n\n")
        case .auto: return [common, "Auto: 에어팟이 연결되어 있으면 에어팟으로, 연결이 끊기면(케이스에 넣으면) 초음파로 감지합니다. 잠금 중에도 바로 바뀝니다. " + now, sonar, airpods].joined(separator: "\n\n")
        }
    }
}

/// Switch-sized take on the AirPods listening-mode control: the picked mode opens into a small track, and sliding
/// its thumb sets that mode's sensitivity (dotted ring = low, solid ring = high). Tapping the thumb turns detection on or off.
struct PresencePicker: View {
    @Binding var mode: String
    @Binding var on: Bool
    @Binding var sonar: Double
    @Binding var airpods: Double
    @State private var dragStart: Double?
    private let items: [(mode: PresenceMode, title: String, icon: String)] = [
        (.sonar, "초음파", "dot.radiowaves.left.and.right"), (.auto, "Auto", "person.fill"), (.airpods, "에어팟", "airpodspro"),
    ]
    private let slot: CGFloat = 26, track: CGFloat = 72, thumb: CGFloat = 30, height: CGFloat = 22 // Same height as a switch.

    private var picked: PresenceMode { PresenceMode(rawValue: mode) ?? .auto }
    private var level: Double { picked == .airpods ? airpods : sonar }

    /// Auto drives both detectors, so it sets both levels.
    private func setLevel(_ v: Double) {
        let v = min(max(v.rounded(), 1), 10)
        if picked != .airpods, sonar != v { sonar = v }
        if picked != .sonar, airpods != v { airpods = v }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.mode) { item in
                if item.mode == picked {
                    slider(item)
                } else {
                    Button { mode = item.mode.rawValue; on = true } label: {
                        icon(item.mode, item.icon, white: false)
                            .frame(width: slot, height: height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                    .accessibilityLabel(item.title)
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(height: height)
        .background(Capsule().fill(.quaternary).overlay(Capsule().strokeBorder(.white.opacity(0.12))))
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: mode)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: on)
    }

    private func slider(_ item: (mode: PresenceMode, title: String, icon: String)) -> some View {
        let travel = track - thumb
        let x = CGFloat(level - 1) / 9 * travel
        return ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.09))
                .frame(height: height - 6)
                .overlay {
                    HStack {
                        Image(systemName: "circle.dotted")
                        Spacer()
                        Image(systemName: "circle")
                    }
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                }
                .contentShape(Capsule())
                .onTapGesture { p in setLevel(level + (p.x < x + thumb / 2 ? -1 : 1)) } // Tap a ring to step toward it.
            Capsule()
                .fill(on ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.thinMaterial))
                .overlay(Capsule().strokeBorder(.white.opacity(on ? 0.45 : 0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                .overlay(icon(item.mode, item.icon, white: on))
                .frame(width: thumb, height: height - 3)
                .offset(x: x)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStart == nil { dragStart = level }
                        setLevel(dragStart! + Double(g.translation.width / travel * 9))
                    }
                    .onEnded { g in
                        if abs(g.translation.width) < 2 { on.toggle() }
                        dragStart = nil
                    })
        }
        .frame(width: track, height: height)
        .help("\(item.title) · 민감도 \(Int(level))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title) 민감도")
        .accessibilityValue(on ? "\(Int(level))" : "꺼짐")
        .accessibilityAdjustableAction { d in setLevel(level + (d == .increment ? 1 : -1)) }
        .accessibilityAction(named: on ? "끄기" : "켜기") { on.toggle() }
    }

    @ViewBuilder private func icon(_ m: PresenceMode, _ name: String, white: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 10, weight: .semibold))
            .overlay(alignment: .topTrailing) {
                if m == .auto { Image(systemName: "sparkles").font(.system(size: 6, weight: .bold)).offset(x: 5, y: -3) }
            }
            .foregroundStyle(white ? AnyShapeStyle(.white) : AnyShapeStyle(m == picked ? .primary : .secondary))
    }
}

/// The settings window coming down out of the notch, turning from 38° to level as it lands. A window cannot be
/// turned, so its own content (live: sidebar glass and all) is lent to a card in a clear window over the screen
/// while it falls, then goes back into the real window.
final class SettingsFall {
    private let window: NSWindow, content: NSView, over: NSWindow, card: NSView
    private let from: CATransform3D

    init?(window w: NSWindow, on screen: NSScreen) {
        guard let content = w.contentView else { return nil }
        let s = screen.frame, end = w.frame
        window = w
        self.content = content
        // Turned about its middle (AppKit anchors the layer at its corner), then lifted to just above the screen.
        let mid = CATransform3DMakeTranslation(end.width / 2, end.height / 2, 0)
        let turn = CATransform3DConcat(CATransform3DConcat(CATransform3DInvert(mid), CATransform3DMakeRotation(38 * .pi / 180, 0, 0, 1)), mid)
        from = CATransform3DConcat(turn, CATransform3DMakeTranslation(0, s.maxY - end.minY, 0))
        over = NSWindow(contentRect: s, styleMask: .borderless, backing: .buffered, defer: false)
        over.isOpaque = false
        over.backgroundColor = .clear
        over.ignoresMouseEvents = true
        over.level = .floating
        card = NSView(frame: end.offsetBy(dx: -s.minX, dy: -s.minY))
        card.wantsLayer = true
        over.contentView?.addSubview(card)
        let bar = end.height - w.contentLayoutRect.height // The title bar the window keeps clear above its content.
        w.contentView = NSView()
        content.frame = card.bounds
        content.additionalSafeAreaInsets.top = bar
        card.addSubview(content)
        if let layer = card.layer {
            layer.cornerRadius = 12
            layer.masksToBounds = true
            w.effectiveAppearance.performAsCurrentDrawingAppearance { layer.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        }
    }

    func land(done: @escaping () -> Void) {
        over.orderFrontRegardless()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [self] in
            content.removeFromSuperview()
            content.additionalSafeAreaInsets.top = 0
            window.contentView = content
            window.makeKeyAndOrderFront(nil)
            over.orderOut(nil)
            done()
        }
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = from
        a.toValue = CATransform3DIdentity
        a.duration = 0.55
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        card.layer?.add(a, forKey: "land")
        CATransaction.commit()
    }
}

func makeSettingsWindow(_ view: SettingsView) -> NSWindow {
    let w = NSWindow(contentViewController: NSHostingController(rootView: view))
    w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
    w.title = "Andeville 설정"
    w.toolbarStyle = .unified
    w.isReleasedWhenClosed = false
    w.setContentSize(NSSize(width: 760, height: 540))
    w.center()
    return w
}

// MARK: - Matching logic

/// 1 - cosine similarity of two unit vectors: 0 is identical.
func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return .infinity }
    return 1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
}

struct Similarity {
    let a, b, tx, ty: CGFloat
    func apply(_ p: CGPoint) -> CGPoint { CGPoint(x: a * p.x - b * p.y + tx, y: b * p.x + a * p.y + ty) }
    var affine: CGAffineTransform { CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty) }
}

/// Least-squares rotation + uniform scale + translation mapping `src` onto `dst`.
func fitSimilarity(from src: [CGPoint], to dst: [CGPoint]) -> Similarity? {
    guard src.count == dst.count, !src.isEmpty else { return nil }
    let n = CGFloat(src.count)
    let sx = src.reduce(0) { $0 + $1.x } / n, sy = src.reduce(0) { $0 + $1.y } / n
    let dx = dst.reduce(0) { $0 + $1.x } / n, dy = dst.reduce(0) { $0 + $1.y } / n
    var a: CGFloat = 0, b: CGFloat = 0, norm: CGFloat = 0
    for (s, d) in zip(src, dst) {
        let x = s.x - sx, y = s.y - sy, u = d.x - dx, v = d.y - dy
        a += x * u + y * v
        b += x * v - y * u
        norm += x * x + y * y
    }
    guard norm > 0 else { return nil }
    a /= norm
    b /= norm
    return Similarity(a: a, b: b, tx: dx - (a * sx - b * sy), ty: dy - (b * sx + a * sy))
}

func meanLuma(_ rgba: [UInt8]) -> Float {
    guard !rgba.isEmpty else { return 0 }
    var total = 0
    for i in stride(from: 0, to: rgba.count, by: 4) { total += 299 * Int(rgba[i]) + 587 * Int(rgba[i + 1]) + 114 * Int(rgba[i + 2]) }
    return Float(total) / Float(rgba.count / 4) / 1000
}

/// Gamma-lifts an underexposed crop toward `target`; normally lit images pass through untouched.
func brightened(_ rgba: [UInt8], below limit: Float = 85, target: Float = 115) -> [UInt8] {
    let mean = meanLuma(rgba)
    guard mean >= 4, mean < limit else { return rgba } // Near-black holds nothing to recover.
    let gamma = log(target / 255) / log(mean / 255)
    let table = (0...255).map { UInt8(min(255, pow(Float($0) / 255, gamma) * 255)) }
    var out = rgba
    for i in stride(from: 0, to: out.count, by: 4) {
        for c in 0..<3 { out[i + c] = table[Int(out[i + c])] }
    }
    return out
}

/// The anti-spoofing crop: the face box scaled about its center, shifted to stay inside the image.
func spoofCrop(box: CGRect, image: CGSize, scale requested: CGFloat) -> CGRect {
    let scale = min(requested, min((image.height - 1) / box.height, (image.width - 1) / box.width))
    let w = box.width * scale, h = box.height * scale
    let x = min(max(box.midX - w / 2, 0), image.width - 1 - w)
    let y = min(max(box.midY - h / 2, 0), image.height - 1 - h)
    return CGRect(x: x, y: y, width: w, height: h)
}

/// SFace's 112x112 alignment template, y-up to match Core Image and Vision.
let faceTemplate = [(38.2946, 51.6963), (73.5318, 51.5014), (56.0252, 71.7366), (41.5493, 92.3655), (70.7299, 92.2041)]
    .map { CGPoint(x: $0.0, y: 112 - $0.1) }

/// Image-left eye, image-right eye, nose tip, image-left and image-right mouth corners, y-up pixels.
func fivePoints(_ l: VNFaceLandmarks2D, size: CGSize) -> [CGPoint]? {
    func center(_ r: VNFaceLandmarkRegion2D?) -> CGPoint? {
        guard let p = r?.pointsInImage(imageSize: size), !p.isEmpty else { return nil }
        return CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
    }
    guard let e1 = center(l.leftEye), let e2 = center(l.rightEye),
          let nose = l.noseCrest?.pointsInImage(imageSize: size).min(by: { $0.y < $1.y }),
          let lips = l.outerLips?.pointsInImage(imageSize: size),
          let m1 = lips.min(by: { $0.x < $1.x }), let m2 = lips.max(by: { $0.x < $1.x }) else { return nil }
    return [e1.x < e2.x ? e1 : e2, e1.x < e2.x ? e2 : e1, nose, m1, m2]
}

/// Accepts after `need` consecutive matching frames.
struct Verifier {
    var threshold: Float
    var need = 5
    private var hits = 0

    init(threshold: Float) { self.threshold = threshold }

    mutating func feed(distance: Float) -> Bool {
        hits = distance <= threshold ? hits + 1 : 0
        return hits >= need
    }
}

func selfCheck() {
    var ring = EnrollRing()
    for _ in 0..<8 { assert(!ring.feed(turn: 0.05, pitch: 0.1), "settling frames must not fill the ring") }
    assert(!ring.feed(turn: 0.06, pitch: 0.1), "a still head must not fill the ring")
    assert(ring.feed(turn: 0.05, pitch: 0.4) && ring.filled[0], "looking up must fill the top tick")
    assert(ring.feed(turn: 0.55, pitch: 0.1) && ring.filled[45], "the user's left must fill the left side of the mirrored preview")
    assert(ring.feed(turn: -0.45, pitch: 0.1) && ring.filled[15], "the user's right must fill the right side")
    assert(!ring.feed(turn: -0.45, pitch: 0.1), "the same direction must not count twice")

    let dark = [UInt8](repeating: 30, count: 400).enumerated().map { $0.offset % 4 == 3 ? UInt8(255) : $0.element }
    let lifted = brightened(dark)
    assert(abs(meanLuma(dark) - 30) < 0.5, "luma of a flat gray must be that gray")
    assert(abs(meanLuma(lifted) - 115) < 3, "a dark crop must be lifted to the target")
    assert(lifted[3] == 255, "alpha must stay untouched")
    let normal = dark.enumerated().map { $0.offset % 4 == 3 ? UInt8(255) : UInt8(140) }
    assert(brightened(normal) == normal, "a normally lit crop must not change")
    let black = dark.enumerated().map { $0.offset % 4 == 3 ? UInt8(255) : UInt8(0) }
    assert(brightened(black) == black, "a black crop must not be amplified")

    func chirpScore(echo: (Int) -> Float) -> (score: Float, lag: Int?) {
        let wave = ChirpDetector.chirp().i, n = ChirpDetector.period, detector = ChirpDetector()
        var seed: UInt32 = 7
        func noise() -> Float {
            seed = seed &* 1664525 &+ 1013904223
            return (Float(seed >> 16) / 65536 - 0.5) * 0.0004
        }
        var stream = [Float](repeating: 0, count: n * 240)
        for i in stream.indices {
            stream[i] = wave[(i + n - 77) % n] + echo(i / n) * wave[(i + n - 77 - 160) % n] + noise()
        }
        var results: [ChirpMetrics] = []
        for chunk in stride(from: 0, to: stream.count - 4096, by: 4096) {
            results += detector.feed(Array(stream[chunk..<(chunk + 4096)]))
        }
        let settled = results.dropFirst(75)
        return (settled.map(\.score).reduce(0, +) / Float(max(settled.count, 1)), detector.directLag)
    }
    let staticEcho = chirpScore { _ in 0.05 }
    let movingEcho = chirpScore { 0.05 * (1 + 0.5 * sin(Float($0) * 0.5)) }
    assert(staticEcho.lag == 77, "the direct path must be found at its true delay")
    assert(movingEcho.score > staticEcho.score + 6, "a changing echo at seated range must raise the score")

    func presence(_ scores: [Float]) -> Int {
        var p = ChirpPresence()
        return scores.filter { p.feed($0) }.count
    }
    let empty = [Float](repeating: 2, count: 100), seated = [Float](repeating: 18, count: 150)
    assert(presence(empty + seated) == 1, "arriving at an empty seat must trigger once")
    assert(presence(seated + seated) == 0, "someone who was already seated when it locked must not trigger")
    assert(presence(empty + empty) == 0, "an empty seat must not trigger")
    assert(presence(empty + [Float](repeating: 18, count: 5) + empty) == 0, "a brief echo must not trigger")
    assert(presence(empty + seated + empty + seated) == 2, "leaving and coming back must trigger again")

    assert("0.2".compare("0.10", options: .numeric) == .orderedAscending, "version compare must be numeric, not lexical")
    assert(ChirpPresence(sensitivity: 1).high == 8 && abs(ChirpPresence(sensitivity: 10).high - 4) < 0.001, "the slider must span the tuned range")
    assert(ChirpPresence(sensitivity: 99).high == ChirpPresence(sensitivity: 10).high, "out-of-range sensitivity must be clamped")
    var modest = ChirpPresence(sensitivity: 10)
    assert((empty + [Float](repeating: 6, count: 150)).contains { modest.feed($0) }, "high sensitivity must catch a weaker echo")
    var strict = ChirpPresence(sensitivity: 1)
    assert(!(empty + [Float](repeating: 6, count: 150)).contains { strict.feed($0) }, "low sensitivity must ignore a weaker echo")

    var owner = Verifier(threshold: 0.5)
    assert(!(0..<4).contains { _ in owner.feed(distance: 0.1) }, "too few frames must not pass")
    assert(owner.feed(distance: 0.1), "enough matching frames must pass")

    var stranger = Verifier(threshold: 0.5)
    assert(!(0..<30).contains { _ in stranger.feed(distance: 0.9) }, "a stranger must not pass")

    var mixed = Verifier(threshold: 0.5)
    assert(!(0..<30).contains { i in mixed.feed(distance: i % 4 == 3 ? 0.9 : 0.1) }, "a mismatch must reset the count")

    assert(cosineDistance([1, 0], [1, 0]) == 0)
    assert(cosineDistance([1, 0], [0, 1]) == 1)
    assert(cosineDistance([1, 0], [1]) == .infinity, "mismatched vectors must never match")

    let identity = fitSimilarity(from: faceTemplate, to: faceTemplate)!
    assert(zip(faceTemplate, faceTemplate.map(identity.apply)).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.001 })
    let tilted = Similarity(a: 2 * cos(0.4), b: 2 * sin(0.4), tx: 300, ty: 120)
    let realign = fitSimilarity(from: faceTemplate.map(tilted.apply), to: faceTemplate)!
    assert(zip(faceTemplate, faceTemplate.map(tilted.apply).map(realign.apply)).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.001 }, "a tilted face must align to the template")

    let area = CGRect(x: 0, y: 0, width: 112, height: 112)
    let topRed = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 56, width: 112, height: 56))
        .composited(over: CIImage(color: .blue).cropped(to: area))
    let rgba = FaceEngine.shared.rgba(topRed)
    assert(rgba[0] > 200 && rgba[2] < 50, "row 0 must be the top of the image")
    assert(rgba[4 * 112 * 111 + 2] > 200 && rgba[4 * 112 * 111] < 50, "the last row must be the bottom of the image")

    let one = FaceEngine.shared.embedding(rgba: rgba)
    assert(one?.count == 128, "the bundled model must load and output 128 values")
    let other = FaceEngine.shared.embedding(rgba: rgba.reversed())!
    assert(cosineDistance(one!, one!) < 0.0001, "the same image must match itself")
    assert(cosineDistance(one!, other) > 0.01, "different images must not match")

    let notch = notchRect(in: NSRect(x: 0, y: 0, width: 1800, height: 1169), notch: CGSize(width: 220, height: 38))
    assert(cursor(NSPoint(x: 900, y: 1169), isOver: notch), "the top edge must count as the notch")
    assert(!cursor(NSPoint(x: 900, y: 1100), isOver: notch), "below the notch must not count")
    assert(!cursor(NSPoint(x: 100, y: 1169), isOver: notch), "the menu bar corner must not count")

    assert(SecureEnclave.isAvailable, "this Mac must have a Secure Enclave")
    let vaultKey = try! FaceVault.Key()
    let secret = Data("embedding".utf8)
    var sealed = try! FaceVault.seal(secret, to: vaultKey)
    assert(try! FaceVault.open(sealed, with: vaultKey) == secret, "sealed face data must open again")
    assert(try! FaceVault.open(FaceVault.seal(secret, to: FaceVault.Key(dataRepresentation: vaultKey.dataRepresentation)), with: vaultKey) == secret, "the saved key blob must restore the same key")
    assert(sealed.range(of: secret) == nil, "sealed data must not contain the plaintext")
    assert((try? FaceVault.open(sealed, with: try! FaceVault.Key())) == nil, "another key must not open it")
    sealed[sealed.count - 1] ^= 1
    assert((try? FaceVault.open(sealed, with: vaultKey)) == nil, "tampered data must not open")
    assert((try? FaceVault.open(Data(), with: vaultKey)) == nil, "empty data must not open")

    let frameSize = CGSize(width: 1280, height: 720)
    let centered = spoofCrop(box: CGRect(x: 600, y: 300, width: 100, height: 100), image: frameSize, scale: 2.7)
    assert(abs(centered.width - 270) < 0.001 && abs(centered.midX - 650) < 0.001, "the crop must grow about the face center")
    let edge = spoofCrop(box: CGRect(x: 0, y: 0, width: 100, height: 100), image: frameSize, scale: 4)
    assert(edge.minX == 0 && edge.minY == 0 && abs(edge.width - 400) < 0.001, "a face at the edge must stay inside the image")
    let huge = spoofCrop(box: CGRect(x: 200, y: 100, width: 500, height: 500), image: frameSize, scale: 4)
    assert(huge.minY >= 0 && huge.maxY <= 719.001, "a close face must not crop past the image")

    let flat = CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: frameSize))
    let live = FaceEngine.shared.liveScore(image: flat, box: CGRect(x: 600, y: 300, width: 100, height: 100))
    assert(live != nil && live! >= 0 && live! <= 1, "both anti-spoofing models must load and give a probability")

    assert(Store.decodeFaces(try! PropertyListEncoder().encode([one!])).count == 1, "enrolled faces must survive a relaunch")
    assert(Store.decodeFaces(Data("old format".utf8)).isEmpty, "unreadable face data must count as not enrolled")

    let signed = ConsentRecord(termsVersion: Terms.version, termsSHA256: Terms.digest, terms: Terms.text, user: "u", appVersion: "0", signedAt: Date(timeIntervalSince1970: 0))
    let older = ConsentRecord(termsVersion: "0", termsSHA256: "old", terms: "old", user: "u", appVersion: "0", signedAt: Date(timeIntervalSince1970: 0))
    let kept = Store.decodeConsents(try! Store.encodeConsents([older, signed]))
    assert(kept.count == 2 && kept[0].terms == "old", "every signed edition must stay on record")
    assert(Terms.isSigned(by: kept.last), "a signature of the current text must count")
    assert(!Terms.isSigned(by: older) && !Terms.isSigned(by: nil), "changed terms or no signature must ask to sign again")

    var away = AirPodsPresence(sensitivity: 6)
    assert(!(0..<20).contains { _ in away.feed(-50) }, "AirPods already near at lock time must not trigger")
    assert(!(0..<20).contains { _ in away.feed(-85) }, "walking away must not trigger")
    assert((0..<10).contains { _ in away.feed(-50) }, "coming back after being away must trigger")

    assert(IslandBackdrop.area(around: CGRect(x: 609, y: 42, width: 295, height: 489)).contains(CGPoint(x: 880, y: 16)), "the wings beside the notch count as over the island, so reaching for the gear does not close it")
    assert(IslandBackdrop.size(around: CGRect(x: 609, y: 42, width: 295, height: 489)) == CGSize(width: 327, height: 547), "the island wraps Control Center with its padding, from the top of the screen")
    assert(RealControlCenter.origin(window: CGRect(x: 1032, y: 0, width: 656, height: 967), content: CGRect(x: 1204.5, y: 42, width: 295, height: 489), midX: 756) == CGPoint(x: 436, y: 0),
           "Control Center's window moves so its content, not the window, is centered under the notch")
    assert(NowPlaying.parse(Data(#"{"playing":true,"title":"A","artist":"B"}"#.utf8)).map { $0.playing && $0.title == "A" && $0.artist == "B" } == true
           && NowPlaying.parse(Data("{}".utf8)) == nil && NowPlaying.parse(Data("junk".utf8)) == nil, "now playing: a title is required, the rest is read when there")
    assert(Controls.swipeKey(-49) == nil && Controls.swipeKey(-50) == 17 && Controls.swipeKey(80) == 18, "a swipe needs its travel; left is next, right is previous")
    assert(Spectrum.loudestBand(ofTone: 80) == 0 && Spectrum.loudestBand(ofTone: 700) == 2 && Spectrum.loudestBand(ofTone: 9000) == 5, "a tone lands in its band: bass left, treble right")
    assert(NotchHUD.step(0.5, up: true) == 0.5625 && NotchHUD.step(0.02, up: false) == 0 && NotchHUD.step(1, up: true) == 1 && NotchHUD.step(0.5, up: false, fine: true) == 0.484375, "a key moves one of 16 steps (64 fine) and clamps")
    assert(NotchHUD.volume(0.5, muted: true) == NotchHUD(symbol: "speaker.slash.fill", value: 0) && NotchHUD.volume(1, muted: false).symbol == "speaker.wave.3.fill" && NotchHUD.volume(0.1, muted: false).symbol == "speaker.wave.1.fill", "the volume glyph follows the level, muted reads as zero")
    var lineBuffer = Data()
    assert(NowPlaying.lines(Data("a\nb\nc".utf8), into: &lineBuffer) == [Data("a".utf8), Data("b".utf8)] && lineBuffer == Data("c".utf8)
           && NowPlaying.lines(Data("d\n".utf8), into: &lineBuffer) == [Data("cd".utf8)] && lineBuffer.isEmpty, "the stream splits on newlines and keeps the unfinished line")
    assert(!screenLocked(), "self-check runs on an unlocked session")
    assert(!typeIntoLockScreen("x"), "nothing may be typed while unlocked")
    let fit = SiriGrip.Fit(hidden: -65, notch: 38, minY: -15, offset: 73.5, screen: 1169)
    assert(fit.map { [$0.short, $0.tall, $0.above, $0.below, $0.lip] } == [920, 1024, 51, 1, -13.5] && SiriGrip.Fit(hidden: -65, notch: 30, minY: -15, offset: 73.5, screen: 1169) == nil,
           "the short window hides the orb in the notch with its edge behind the notch, the tall one draws all of the orb, and they meet at the notch's lip (as measured); a notch too shallow has no fit")
    assert(SiriGrip.lift(reach: 0, dy: -10, down: 0, held: true, carrying: true, room: 64).reach == 10, "with the orb in hand the drag does go up")
    let lift = { (reach: CGFloat, dy: CGFloat, down: CGFloat, held: Bool) in SiriGrip.lift(reach: reach, dy: dy, down: down, held: held, room: 64) }
    assert(lift(0, -10, 0, false).reach == 10 && lift(0, -10, 5, false).reach == 0 && lift(60, -20, 0, false).reach == 64, "pushed against the top edge the cursor goes on up, as far as the orb's top and no further")
    assert(lift(30, 10, 10, true) == (20, 0) && lift(3, 5, 5, true) == (0, 2) && lift(3, 5, 10, true).put == 7, "with the orb in hand the cursor covers the way back down before it moves on screen, and loses none of the move")
    assert(lift(30, 5, 5, false) == (0, nil) && lift(30, 1, 2, false) == (29, nil) && lift(0, -10, 0, true).reach == 0, "without a button held the cursor is never put back, and a drag from elsewhere does not go up")
    print("self-check ok")
}

// MARK: - Storage

/// Encrypts to a Secure Enclave key, so the stored face data is useless on any other Mac.
/// ponytail: no user-presence check, because it must open on the lock screen. Malware running as this user could still ask this Mac to decrypt it.
enum FaceVault {
    typealias Key = SecureEnclave.P256.KeyAgreement.PrivateKey

    private static func symmetricKey(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("faytai face v1".utf8), outputByteCount: 32)
    }

    static func seal(_ plain: Data, to key: Key) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let box = try AES.GCM.seal(plain, using: symmetricKey(try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey)))
        return ephemeral.publicKey.x963Representation + box.combined!
    }

    static func open(_ sealed: Data, with key: Key) throws -> Data {
        guard sealed.count > 65 else { throw CryptoKitError.incorrectParameterSize }
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: sealed.prefix(65))
        return try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed.dropFirst(65)), using: symmetricKey(try key.sharedSecretFromKeyAgreement(with: peer)))
    }
}

enum Store {
    // The app was renamed Andeville; the old identifiers stay so saved faces, the password and settings carry over.
    static let service = "com.ggear.faytai"
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Faytai")
    static var faceFile: URL { dir.appendingPathComponent("face.enc") }
    static var keyFile: URL { dir.appendingPathComponent("face.key") }
    static var plainFaceFile: URL { dir.appendingPathComponent("face.sface") }
    static var legacyFaceFile: URL { dir.appendingPathComponent("face.dat") }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The key file is an opaque blob that only this Mac's Secure Enclave can use.
    private static func vaultKey() throws -> FaceVault.Key {
        if let blob = try? Data(contentsOf: keyFile) { return try FaceVault.Key(dataRepresentation: blob) }
        let key = try FaceVault.Key()
        try writePrivate(key.dataRepresentation, to: keyFile)
        return key
    }

    static func saveFaces(_ embeddings: [[Float]]) throws {
        try writePrivate(FaceVault.seal(PropertyListEncoder().encode(embeddings), to: vaultKey()), to: faceFile)
        // Removed only after the encrypted copy is on disk, so a failure above loses nothing.
        try? FileManager.default.removeItem(at: plainFaceFile)
        try? FileManager.default.removeItem(at: legacyFaceFile)
    }

    static func loadFaces() -> [[Float]] {
        if let sealed = try? Data(contentsOf: faceFile) {
            do { return decodeFaces(try FaceVault.open(sealed, with: vaultKey())) }
            catch {
                log("face data decrypt failed: \(error)")
                return []
            }
        }
        guard let plain = try? Data(contentsOf: plainFaceFile) else { return [] }
        let faces = decodeFaces(plain)
        if !faces.isEmpty {
            do {
                try saveFaces(faces)
                log("face data migrated to encrypted storage")
            } catch { log("face data encryption failed, keeping existing file: \(error)") }
        }
        return faces
    }

    static func decodeFaces(_ data: Data) -> [[Float]] {
        do { return try PropertyListDecoder().decode([[Float]].self, from: data) }
        catch {
            log("face data decode failed: \(error)")
            return []
        }
    }

    /// Calibration knob: `defaults write com.ggear.faytai sfaceThreshold -float <value>` (lower = stricter).
    static var threshold: Float {
        let v = UserDefaults.standard.float(forKey: "sfaceThreshold")
        return v > 0 ? v : 0.5
    }

    /// Calibration knob: `defaults write com.ggear.faytai liveThreshold -float <value>` (higher = stricter, 0 = off).
    static var liveThreshold: Float {
        UserDefaults.standard.object(forKey: "liveThreshold") == nil ? 0.5 : UserDefaults.standard.float(forKey: "liveThreshold")
    }

    /// `defaults write com.ggear.faytai fillLight -bool false` keeps the screen from lighting up in the dark.
    static var fillLight: Bool {
        UserDefaults.standard.object(forKey: "fillLight") == nil || UserDefaults.standard.bool(forKey: "fillLight")
    }

    /// Settings › 모양: radius of the concave fillets where the notch meets the top edge.
    /// The default is also the minimum: the fillets are always on.
    static let notchEarDefault = 7.0, notchEarRange = notchEarDefault...24
    static var notchEar: CGFloat {
        let v = UserDefaults.standard.object(forKey: "notchEar") == nil ? notchEarDefault : UserDefaults.standard.double(forKey: "notchEar")
        return CGFloat(min(max(v, notchEarRange.lowerBound), notchEarRange.upperBound))
    }

    /// Calibration knob: `defaults write com.ggear.faytai darkLuma -float <value>` (0-255 scene brightness that turns on the screen light).
    static var darkLuma: Float {
        let v = UserDefaults.standard.float(forKey: "darkLuma")
        return v > 0 ? v : 50
    }

    /// Settings › 실험실 › 자리 비움 감지. Falls back to the old per-experiment switches.
    static var presenceOn: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "presenceOn") as? Bool ?? (d.bool(forKey: "sonarPresence") || d.bool(forKey: "airpodsPresence"))
    }

    static var presenceMode: PresenceMode { PresenceMode(rawValue: UserDefaults.standard.string(forKey: "presenceMode") ?? "") ?? .auto }

    static var airpodsSensitivity: Double {
        let v = UserDefaults.standard.double(forKey: "airpodsSensitivity")
        return v > 0 ? v : 6
    }

    static var sonarSensitivity: Double {
        let v = UserDefaults.standard.double(forKey: "sonarSensitivity")
        return v > 0 ? v : 6
    }

    /// The island's open/close animation lengths in seconds; Settings › 일반 › 노치.
    static let hubTimingDefault = (open: 0.4, close: 0.45, dwell: 0.08, leave: 0.1)
    /// Overshoot of the opening spring, 0 (none) to 0.6; Settings › 일반 › 노치 › 튕김. Spring damping is 1 - this.
    static let hubBounceDefault = 0.26
    /// How long the notch takes to swell under the cursor; Settings › 일반 › 노치 › 호버 반응 속도.
    static let hoverSpeedDefault = 0.5
    static var hubBounce: Double {
        UserDefaults.standard.object(forKey: "hubBounce") == nil ? hubBounceDefault : min(max(UserDefaults.standard.double(forKey: "hubBounce"), 0), 0.6)
    }
    /// How long the cursor may be off Control Center before it closes; 0 closes on exit.
    static var hubLeave: Double {
        UserDefaults.standard.object(forKey: "hubLeave") == nil ? hubTimingDefault.leave : max(UserDefaults.standard.double(forKey: "hubLeave"), 0)
    }
    /// How long the cursor must rest on the notch before it opens; 0 opens on contact.
    static var hubDwell: Double {
        UserDefaults.standard.object(forKey: "hubDwell") == nil ? hubTimingDefault.dwell : max(UserDefaults.standard.double(forKey: "hubDwell"), 0)
    }
    /// The notch opens macOS's own Control Center under it (on unless turned off).
    static var hubRealCC: Bool { UserDefaults.standard.object(forKey: "hubRealCC") as? Bool ?? true }
    /// Andeville's island behind macOS's Control Center, with the blur in and out (on unless turned off).
    /// The collapsed notch's live activity, swipe gestures and trackpad ticks (all on unless turned off).
    static var liveActivity: Bool { UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true }
    static var notchGestures: Bool { UserDefaults.standard.object(forKey: "notchGestures") as? Bool ?? true }
    static var notchHUD: Bool { UserDefaults.standard.object(forKey: "notchHUD") as? Bool ?? true }
    /// Keeps the display and the Mac awake while the screen is locked (off unless turned on).
    static var lockAwake: Bool { UserDefaults.standard.bool(forKey: "lockAwake") }
    static var haptics: Bool { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }
    /// Hub opens on a notch click instead of a hover.
    static var hubClickOpen: Bool { UserDefaults.standard.bool(forKey: "hubClickOpen") }
    static var hubOpen: Double {
        let v = UserDefaults.standard.double(forKey: "hubOpen")
        return v > 0 ? v : hubTimingDefault.open
    }
    static var hubClose: Double {
        let v = UserDefaults.standard.double(forKey: "hubClose")
        return v > 0 ? v : hubTimingDefault.close
    }


    static var lockedApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: "lockedApps") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "lockedApps") }
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: NSUserName()]
    }

    static func deletePassword() {
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: secretFile)
    }
    /// Either store counts: the consented copy alone is enough to unlock, even if the keychain item went missing.
    static var hasPassword: Bool {
        SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess || (hasCurrentConsent && hasSealedSecret)
    }

    static func savePassword(_ pw: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(pw.utf8)
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { return false }
        sealSecret(pw)
        return true
    }

    private static func keychainPassword() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        // Never let macOS show its keychain prompt: on the lock screen nobody can answer it, and the consented copy answers instead.
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let d = out as? Data else {
            log("keychain read failed: \(status) (app re-signed?)")
            return nil
        }
        return String(data: d, encoding: .utf8)
    }

    /// Keychain first; when macOS would ask for the keychain password instead, the app answers with its consented copy.
    /// The consented copy first: reading the keychain item after a rebuild makes macOS ask for the keychain password,
    /// and `kSecUseAuthenticationUIFail` does not stop that prompt on the login keychain, it just blocks the caller.
    static func password() -> String? {
        if hasCurrentConsent, let pw = sealedSecret() { return pw }
        if !hasCurrentConsent { log("keychain terms not signed: app may not answer for the keychain") }
        guard let pw = keychainPassword() else { return nil }
        // Any read that got through fills the consented copy, so the next update never asks macOS again.
        if sealedSecret() == nil { sealSecret(pw); if hasSealedSecret { log("consented copy filled from the keychain") } }
        return pw
    }

    static var hasSealedSecret: Bool { sealedSecret() != nil }

    private static func sealedSecret() -> String? {
        guard let sealed = try? Data(contentsOf: secretFile), let plain = try? FaceVault.open(sealed, with: vaultKey()) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    // MARK: Consent

    static var consentFile: URL { dir.appendingPathComponent("consent.json") }
    static var secretFile: URL { dir.appendingPathComponent("login.enc") }

    static func encodeConsents(_ records: [ConsentRecord]) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(records)
    }

    static func decodeConsents(_ data: Data) -> [ConsentRecord] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode([ConsentRecord].self, from: data)) ?? []
    }

    static var consents: [ConsentRecord] { (try? Data(contentsOf: consentFile)).map(decodeConsents) ?? [] }
    static var hasCurrentConsent: Bool { Terms.isSigned(by: consents.last) }

    static func signConsent() throws {
        let record = ConsentRecord(
            termsVersion: Terms.version, termsSHA256: Terms.digest, terms: Terms.text, user: NSUserName(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?", signedAt: Date())
        try writePrivate(encodeConsents(consents + [record]), to: consentFile)
    }

    /// ponytail: same Secure Enclave trust as the face data, so any process running as this user on this Mac can open it; the terms say so.
    private static func sealSecret(_ pw: String) {
        guard hasCurrentConsent else { return }
        do { try writePrivate(FaceVault.seal(Data(pw.utf8), to: vaultKey()), to: secretFile) }
        catch { log("secret seal failed: \(error)") }
    }

    /// Run while logged in, e.g. after an update re-signed the app: hands the keychain item to this build, or fills a missing copy.
    /// Fills a missing consented copy from the keychain. May wait on a macOS keychain prompt, so never call it on the main thread.
    static func syncSecret() {
        guard hasPassword, hasCurrentConsent, sealedSecret() == nil else { return }
        _ = password()
    }
}

// MARK: - Camera

struct FaceFrame { let embedding: [Float]; let live: Float; let turn: Double; let pitch: Double }

/// Runs the bundled SFace model. Used from one queue at a time.
final class FaceEngine {
    static let shared = FaceEngine()
    private let context = CIContext()
    private let model: MLModel? = {
        guard let url = Bundle.main.url(forResource: "SFace", withExtension: "mlmodelc") else { log("SFace model missing from the app"); return nil }
        do { return try MLModel(contentsOf: url) }
        catch { log("SFace model load failed: \(error)"); return nil }
    }()

    private let spoofModels: [(model: MLModel, scale: CGFloat)] = [("MiniFASNetV2", CGFloat(2.7)), ("MiniFASNetV1SE", CGFloat(4))].compactMap { name, scale in
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc"), let m = try? MLModel(contentsOf: url) else {
            log("\(name) model failed to load")
            return nil
        }
        return (m, scale)
    }

    /// Square RGBA, row 0 at the top of the image.
    func rgba(_ image: CIImage, side: Int = 112) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: side * side * 4)
        context.render(image, toBitmap: &out, rowBytes: side * 4, bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return out
    }

    /// Mean probability that the face is real, or nil if a model is unavailable, so a broken model can only refuse.
    func liveScore(image: CIImage, box: CGRect) -> Float? {
        guard spoofModels.count == 2 else { return nil }
        var total: Float = 0
        for (model, scale) in spoofModels {
            let crop = spoofCrop(box: box, image: image.extent.size, scale: scale)
            let patch = image.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(scaleX: 80 / crop.width, y: 80 / crop.height))
            let pixels = brightened(rgba(patch, side: 80))
            guard let input = try? MLMultiArray(shape: [1, 3, 80, 80], dataType: .float32) else { return nil }
            let p = input.dataPointer.bindMemory(to: Float32.self, capacity: 3 * 80 * 80)
            for i in 0..<(80 * 80) {
                for c in 0..<3 { p[c * 80 * 80 + i] = Float32(pixels[i * 4 + 2 - c]) } // Planar BGR, 0-255.
            }
            guard let features = try? MLDictionaryFeatureProvider(dictionary: ["patch": input]),
                  let probs = try? model.prediction(from: features).featureValue(for: "probs")?.multiArrayValue,
                  probs.count == 3 else { return nil }
            total += probs[1].floatValue // Index 1 is "real face".
        }
        return total / 2
    }

    func embedding(rgba: [UInt8]) -> [Float]? {
        guard let model, rgba.count == 112 * 112 * 4,
              let input = try? MLMultiArray(shape: [1, 3, 112, 112], dataType: .float32) else { return nil }
        let p = input.dataPointer.bindMemory(to: Float32.self, capacity: 3 * 112 * 112)
        for i in 0..<(112 * 112) {
            for c in 0..<3 { p[c * 112 * 112 + i] = Float32(rgba[i * 4 + c]) } // Planar RGB, 0-255.
        }
        guard let features = try? MLDictionaryFeatureProvider(dictionary: ["face": input]),
              let output = try? model.prediction(from: features).featureValue(for: "embedding")?.multiArrayValue else { return nil }
        let v = (0..<output.count).map { output[$0].floatValue }
        let length = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return length > 0 ? v.map { $0 / length } : nil
    }

    func embedding(pixels: CVPixelBuffer, points: [CGPoint]) -> [Float]? {
        guard let align = fitSimilarity(from: points, to: faceTemplate) else { return nil }
        return embedding(rgba: brightened(rgba(CIImage(cvPixelBuffer: pixels).transformed(by: align.affine))))
    }
}

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "faytai.camera")
    private var configured = false
    var onFrame: ((FaceFrame) -> Void)?
    var onLuma: ((Float) -> Void)?

    func start() -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return false }
        if !configured {
            guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified),
                  let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else { return false }
            session.sessionPreset = .hd1280x720
            session.addInput(input)
            let out = AVCaptureVideoDataOutput()
            out.alwaysDiscardsLateVideoFrames = true
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            out.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(out)
            configured = true
        }
        queue.async { self.session.startRunning() }
        return true
    }

    func stop() {
        onFrame = nil
        onLuma = nil
        queue.async { self.session.stopRunning() }
    }

    func captureOutput(_ o: AVCaptureOutput, didOutput b: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let cb = onFrame, let px = CMSampleBufferGetImageBuffer(b) else { return }
        // Measured before face detection: in a truly dark room no face is found at all.
        if let onLuma, let luma = sceneLuma(px) { onLuma(luma) }
        let handler = VNImageRequestHandler(cvPixelBuffer: px)
        let faces = VNDetectFaceLandmarksRequest()
        guard (try? handler.perform([faces])) != nil,
              faces.results?.count == 1, let face = faces.results?.first, // more than one face: reject
              let landmarks = face.landmarks else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))
        guard let points = fivePoints(landmarks, size: size),
              let embedding = FaceEngine.shared.embedding(pixels: px, points: points) else { return }
        let box = face.boundingBox
        let pixelBox = VNImageRectForNormalizedRect(box, Int(size.width), Int(size.height))
        guard let live = FaceEngine.shared.liveScore(image: CIImage(cvPixelBuffer: px), box: pixelBox) else { return }
        // An unmirrored camera sees the user's left on the image's right, so the nose moving right is a turn to their left.
        let eyeSpan = max(points[1].x - points[0].x, 1)
        let offset = Double((points[2].x - (points[0].x + points[1].x) / 2) / eyeSpan)
        let eyes = (points[0].y + points[1].y) / 2, mouth = (points[3].y + points[4].y) / 2
        let pitch = Double((points[2].y - (eyes + mouth) / 2) / max(eyes - mouth, 1))
        cb(FaceFrame(embedding: embedding, live: live, turn: c.isVideoMirrored ? -offset : offset, pitch: pitch))
    }
}

/// Average of a sparse grid of the camera's luma plane, 0-255.
func sceneLuma(_ px: CVPixelBuffer) -> Float? {
    guard CVPixelBufferIsPlanar(px), CVPixelBufferLockBaseAddress(px, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(px, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let row = CVPixelBufferGetBytesPerRowOfPlane(px, 0), w = CVPixelBufferGetWidthOfPlane(px, 0), h = CVPixelBufferGetHeightOfPlane(px, 0)
    var total = 0, n = 0
    for y in stride(from: 0, to: h, by: 16) {
        for x in stride(from: 0, to: w, by: 16) { total += Int(base[y * row + x]); n += 1 }
    }
    return n > 0 ? Float(total) / Float(n) : nil
}

func screenLocked() -> Bool {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

func notchSize(of screen: NSScreen) -> CGSize {
    guard screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea else {
        return CGSize(width: 180, height: 28)
    }
    return CGSize(width: screen.frame.width - l.width - r.width, height: screen.safeAreaInsets.top)
}

func notchScreen() -> NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main }

func notchRect(in frame: NSRect, notch: CGSize) -> NSRect {
    NSRect(x: frame.midX - notch.width / 2, y: frame.maxY - notch.height, width: notch.width, height: notch.height)
}

func cursor(_ p: NSPoint, isOver rect: NSRect) -> Bool {
    // Inclusive edges: at the top of the screen the cursor sits exactly on maxY.
    p.x >= rect.minX && p.x <= rect.maxX && p.y >= rect.minY && p.y <= rect.maxY
}

/// Stops the moment the session is no longer locked, so the password can never reach a regular app.
@discardableResult
private func postKey(_ code: CGKeyCode, _ text: String?) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
        if let t = text { let u = Array(t.utf16); e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u) }
        e.post(tap: .cghidEventTap)
    }
    usleep(25_000)
}

/// Shift reveals the lock screen's password field. Pressed when the scan starts, so the reveal overlaps the scan.
func revealPasswordField() {
    guard screenLocked() else { return }
    postKey(56, nil)
}

/// `revealedAt`: when `revealPasswordField` ran; only the rest of the 0.4s the field needs to appear is waited.
func typeIntoLockScreen(_ pw: String, revealedAt: Date? = nil) -> Bool {
    guard screenLocked() else { return false }
    func post(_ code: CGKeyCode, _ text: String?) { postKey(code, text) }
    let since: TimeInterval
    if let revealedAt { since = Date().timeIntervalSince(revealedAt) } else { post(56, nil); since = 0 }
    if since < 0.4 { usleep(useconds_t((0.4 - since) * 1_000_000)) } // Typed before the field shows, the first character is lost.
    for ch in pw {
        guard screenLocked() else { return false }
        post(0, String(ch))
    }
    guard screenLocked() else { return false }
    post(36, nil) // Return
    return true
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let camera = Camera()
    private let island = Island()
    private let fillLight = FillLight()
    private var lockAwake: NSObjectProtocol?
    private let live = NotchModel()
    private let backdrop = IslandBackdrop()
    private var rightTap: CFMachPort?
    private var rightOnNotch = false // A right press that began on the notch: its release is kept too.
    private var fall: SettingsFall?
    private lazy var notchBase = NotchBase(model: live)
    private var nowPlayingStream: Process?
    private var swipeMonitors: [Any?] = []
    private var plugged: Bool?
    fileprivate var hudTap: CFMachPort?
    private var hudGeneration = 0
    private var appCache: [String: LockedApp] = [:]
    private var notchTimer: Timer?
    private var faces = Store.loadFaces()
    private var busy = false
    private let settingsModel = SettingsModel()
    private var settingsWindow: NSWindow?
    /// macOS's Control Center under the notch (see `openNotch`). While opening, Control Center has no window yet, so
    /// the watch must not take that for "closed by the user".
    private enum RealState { case idle, opening, open }
    private var real = RealState.idle
    /// Closed by a scroll up: the cursor must leave the notch before a hover opens it again.
    private var mustLeave = false
    private var realEditing = false
    /// Siri while it is out, and the grip while its orb is in hand (taken out of the notch, or on its way back in).
    /// Only while Siri is out are presses looked at before the apps get them (`orbEvent`).
    private var siri: SiriGrip.Out? {
        didSet {
            if let tap = gripTap { CGEvent.tapEnable(tap: tap, enable: siri != nil) }
            if siri == nil { orbPress = nil }
        }
    }
    private var grip: SiriGrip?
    fileprivate var gripTap: CFMachPort?
    /// A press on Siri's orb, kept from Siri (where, Accessibility coordinates), and once it has become a drag,
    /// where on the orb the cursor has it (from its middle, from its top).
    fileprivate var orbPress: CGPoint?
    fileprivate var orbHold: CGPoint?
    private static let replayed: Int64 = 0x41_6E_64_65 // Marks the click handed back to Siri, so it is let through.
    /// How far over the top of the screen the cursor has been pushed, inside the notch (see `liftCursor`).
    private var reach: CGFloat = 0
    private var liftMonitors: [Any?] = []
    private let enrollModel = EnrollModel()
    private var enrollWindow: NSWindow?
    private var enrollSamples: [[Float]] = []
    private var consentWindow: NSWindow?
    private var unlockedApps = Set<String>()
    private var pendingApp: NSRunningApplication?
    private var lockTimer: Timer?
    private var cancelScan: (() -> Void)?
    private var sonar: ChirpProbe?
    private var airpodsTimer: Timer?
    private var airpodsWatch: Timer?
    private var airpodsConnected: Bool?
    private var faceWatching = false
    private var faceRetryAfter = Date.distantPast
    private var wakePending = false

    /// andeville:// links from Andeville's controls in the Mac's Control Center and menu bar (Controls/): the extension
    /// is sandboxed, so the app does the work.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "andeville" {
            switch url.host {
            case "lock": lockScreenNow()
            case "test": test()
            default: break
            }
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        setUpNotch()
        notchBase.update()
        setUpLive()
        setUpHUD()
        setUpGripTap()
        _ = lockedAppList()
        NotificationCenter.default.addObserver(self, selector: #selector(updateNotchBase), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateNotchBase), name: UserDefaults.didChangeNotification, object: nil)
        backdrop.settings = { [weak self] in
            self?.closeReal()
            self?.openSettings()
        }
        setUpRightTap()
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        wc.addObserver(self, selector: #selector(appQuit(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        wc.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenDidLock), name: .init("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenDidUnlock), name: .init("com.apple.screenIsUnlocked"), object: nil)
        checkConsent()
        airpodsWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.airpodsTick() }
        airpodsTick()
    }

    /// Auto mode: AirPods worn (connected) use the AirPods check, taken off (disconnected) go back to ultrasound.
    private func airpodsTick() {
        let on = AirPods.connected() != nil
        guard on != airpodsConnected else { return }
        airpodsConnected = on
        settingsModel.airpodsConnected = on
        log("airpods connected=\(on)")
        guard Store.presenceOn, Store.presenceMode == .auto else { return }
        if lockTimer != nil { // Swapped while locked: switch watchers now, not at the next lock.
            startSonarWatch()
            startAirPodsWatch()
        }
    }

    // MARK: Keychain consent

    /// At launch (an update or a terms change lands here): fill a missing consented copy, or ask for a new signature.
    private func checkConsent() {
        guard Store.hasPassword else { return }
        if Store.hasCurrentConsent { return DispatchQueue.global().async { Store.syncSecret() } } // Off main: may wait on a keychain prompt.
        island.askConsent()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.showConsent {} }
    }

    private func showConsent(then: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        consentWindow?.close()
        let w = makeConsentWindow(ConsentView(renewal: !Store.consents.isEmpty) { [weak self] in
            self?.authenticate(reason: "키체인 이용 약관 서명") { ok in
                guard let self, ok else { return }
                do { try Store.signConsent() }
                catch { return self.alert("동의서를 저장하지 못했습니다: \(error.localizedDescription)") }
                log("keychain terms v\(Terms.version) signed")
                self.consentWindow?.close()
                self.consentWindow = nil
                DispatchQueue.global().async { // May wait on a keychain prompt; the notch must keep working meanwhile.
                    Store.syncSecret()
                    let missing = Store.hasPassword && !Store.hasSealedSecret
                    DispatchQueue.main.async {
                        if missing {
                            // Saved by a build from before the terms, which left no copy, and the keychain no longer trusts this build.
                            Store.deletePassword()
                            self.toggleUnlock()
                        }
                        then()
                    }
                }
            }
        })
        consentWindow = w
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func revealConsent() {
        guard FileManager.default.fileExists(atPath: Store.consentFile.path) else { return showConsent {} }
        NSWorkspace.shared.activateFileViewerSelecting([Store.consentFile])
    }

    // MARK: Notch

    @objc private func updateNotchBase() {
        DispatchQueue.main.async {
            self.notchBase.update()
        }
    }

    /// Opening the app again (Finder, Spotlight) is the way in without a notch hover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func setUpNotch() {
        var overSince: Date?, awaySince: Date?, realTicks = 0
        var wasDown = false // Click mode opens on the press itself, not on a drag that started elsewhere and crosses the notch.
        var armed = true // After Control Center closes, the cursor must leave the notch before it can open again.
        // A press on the notch itself: the cursor's x and its height then (from the top of the screen, negative over it).
        // Pulled down it takes Siri's orb out, let go in place it is a click.
        var grab: (x: CGFloat, y: CGFloat)?
        // A ⌘-drag that started on a menu bar item: taken to the notch it opens Control Center, to drop the item in.
        var menuDrag = false
        var hold: CGPoint? // Siri's orb in hand: where on it the cursor has it, from its middle and from its top.
        var siriTicks = 0, siriGone = 0, siriLooking = false
        // Polled like the lock screen watch; a 60 Hz mouse read is negligible and keeps the dwell setting accurate.
        notchTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard !screenLocked(), !self.busy, !self.island.isShowing, let screen = notchScreen() else {
                overSince = nil
                armed = false
                grab = nil
                hold = nil
                if self.live.hover { self.live.hover = false }
                self.grip?.release(out: false)
                return
            }
            let p = NSEvent.mouseLocation, now = Date()
            let overNotch = cursor(p, isOver: notchRect(in: screen.frame, notch: notchSize(of: screen)))
            let hover = (overNotch || self.real != .idle) && self.grip == nil && self.siri == nil // Stays swollen while Control Center is open.
            if self.live.hover != hover { self.live.hover = hover }
            let down = NSEvent.pressedMouseButtons & 1 != 0
            let pressed = down && !wasDown
            wasDown = down
            let notch = notchSize(of: screen)
            if pressed {
                let bar = max(notch.height, screen.frame.maxY - screen.visibleFrame.maxY)
                menuDrag = !overNotch && NSEvent.modifierFlags.contains(.command) && screen.frame.maxY - p.y <= bar
            } else if !down { menuDrag = false }
            // The cursor's height from the top of the screen; inside the notch it goes on over it (liftCursor).
            let cursorY = self.reach > 0 ? -self.reach : screen.frame.maxY - p.y
            // The orb's top while it is in the notch: its bottom on the notch's lower edge.
            let hidden = notch.height - SiriGrip.orb
            if let grip = self.grip {
                // In hand the orb follows the cursor, no further in than the notch holds it, until it is let go.
                if let h = hold {
                    let spot = CGPoint(x: p.x - h.x, y: max(cursorY - h.y, hidden))
                    grip.move(to: spot)
                    if !down {
                        hold = nil
                        grip.release()
                    }
                }
                grab = nil
                overSince = nil
                armed = false
                return
            }
            // Siri is out: its orb can be taken in hand again, and a click on the notch puts it away.
            if let s = self.siri {
                siriTicks += 1
                if self.orbPress != nil {
                    // A press on the orb, kept from Siri: orbEvent has it.
                } else if pressed, overNotch {
                    self.siri = nil
                    Controls.haptic()
                    DispatchQueue.global(qos: .userInteractive).async { RealSiri.dismiss(s.window) }
                    armed = false
                } else if siriTicks % 30 == 0, !siriLooking {
                    // Twice a second, off the main thread: a busy Siri keeps such a call waiting, and the main thread
                    // waiting with it would hold up the mouse (seen: a drag on the orb that went unnoticed).
                    siriLooking = true
                    DispatchQueue.global(qos: .utility).async {
                        let gone = RealSiri.window() == nil
                        let c = gone ? CGRect.null : RealControlCenter.content(of: s.window) // Where the orb is, for the next press on it.
                        DispatchQueue.main.async {
                            siriLooking = false
                            guard self.siri != nil, self.grip == nil, self.orbPress == nil else { return }
                            // Its window drops out of the list for a moment now and then (measured): gone is twice in a row.
                            siriGone = gone ? siriGone + 1 : 0
                            if siriGone >= 2 {
                                self.siri = nil
                                armed = false
                            } else if !c.isNull {
                                self.siri?.content = c
                            }
                        }
                    }
                }
                grab = nil
                return
            }
            siriGone = 0
            if pressed, overNotch { grab = (p.x, cursorY) }
            var tapped = false
            if let g = grab, !down || cursorY - g.y >= 3 {
                // Let go in place it is a click, which brings Siri out by itself when hovering already opens Control
                // Center. Pulled, the orb is in hand: in the notch where the cursor is, at the height the cursor has it.
                grab = nil
                tapped = !down && Store.hubClickOpen
                if !tapped {
                    // Control Center makes way, also one that is still opening (the first time after launch that
                    // takes seconds, and the orb is not kept waiting for it): it is closed when it has opened.
                    if self.real == .open { self.closeReal() } else if self.real == .opening { self.real = .idle; self.backdrop.hide(blur: false) }
                    overSince = nil
                    armed = false
                    let room = max((notch.width - SiriGrip.orb) / 2, 0), mid = screen.frame.midX
                    let middle = down ? min(max(g.x, mid - room), mid + room) : mid
                    self.takeSiri(on: screen, at: CGPoint(x: middle, y: hidden))
                    if down { hold = CGPoint(x: g.x - middle, y: g.y - hidden) } else { self.grip?.release(out: true) }
                    return
                }
            }
            // macOS's own Control Center under the notch: closes once the cursor has left it, but not while
            // its Edit Controls gallery is up or after the user closed it themselves.
            if self.real == .opening { awaySince = nil; return }
            if self.real == .open {
                realTicks += 1
                // Control Center itself is asked only at 10 Hz (each look is a call into it); the leave check below
                // runs every tick off the remembered rect, so closing answers at once.
                if realTicks % 6 == 0 {
                    let wins = RealControlCenter.windows()
                    if wins.isEmpty { self.real = .idle; self.backdrop.hide(blur: false); armed = !overNotch; return }
                    // Edit Controls moves Control Center's panel to make room for its gallery: the island steps away.
                    self.realEditing = RealControlCenter.editing(wins)
                    if self.realEditing { self.backdrop.hide(blur: false) }
                }
                if self.realEditing { awaySince = nil; return }
                let ax = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
                let over = RealControlCenter.openContent.map { IslandBackdrop.area(around: $0).contains(ax) } ?? true
                if over || overNotch || down { awaySince = nil } else if awaySince == nil { awaySince = now }
                if let a = awaySince, now.timeIntervalSince(a) >= Store.hubLeave {
                    self.closeReal()
                    armed = false
                }
                return
            }
            if self.mustLeave { self.mustLeave = false; armed = false; overSince = nil }
            if !overNotch { armed = true }
            guard overNotch, armed, grab == nil, self.fall == nil else { overSince = nil; return } // A held grab is not a hover.
            // A click opens on release (in either mode), so a pull can still become Siri. Settings › 노치 › 여는 방식: 클릭.
            if (Store.hubClickOpen || tapped) && !menuDrag {
                if tapped { awaySince = nil; self.openNotch(on: screen) }
                return
            }
            if overSince == nil { overSince = now }
            // Dwell (Settings › 노치 › 감지 속도), so a cursor passing over the top edge does not open it.
            if now.timeIntervalSince(overSince!) >= Store.hubDwell {
                overSince = nil
                awaySince = nil
                if !down || menuDrag { self.openNotch(on: screen) } // A drag crossing the notch opens nothing, but a menu bar item's ⌘-drag does.
            }
        }
        // Every mouse move, for the cursor's way up into the notch. Global for the other apps', local for Andeville's own.
        let lift: (NSEvent) -> Void = { [weak self] e in self?.liftCursor(by: e.deltaY) }
        liftMonitors = [NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: lift),
                        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { lift($0); return $0 }]
    }

    /// The cursor's way up into the notch. The screen ends at the notch's top, but Siri's orb is taller than the
    /// notch, so in the notch it reaches higher than the cursor can go. A cursor pushed against the top edge inside
    /// the notch therefore goes on up, out of sight, as far as the orb's top (`reach`); coming down it covers that
    /// way again before it moves on screen, put back on the edge until then (it is behind the notch all the while).
    private func liftCursor(by dy: CGFloat) {
        guard reach > 0 || dy < 0 else { return } // Every mouse move comes through here: the common ones leave at once.
        guard siri == nil || grip != nil, let screen = notchScreen(), screen.safeAreaInsets.top > 0 else { reach = 0; return }
        let notch = notchSize(of: screen), p = NSEvent.mouseLocation, down = screen.frame.maxY - p.y
        let carrying = orbPress != nil // A press kept from the apps may not show as a button held.
        // Inside the notch; with the orb in hand also beside it, as far as the notch reaches for the orb.
        guard abs(p.x - screen.frame.midX) <= notch.width / 2 + (carrying ? SiriGrip.beside : 0), reach > 0 || (down <= 0.5 && !screenLocked()) else { reach = 0; return }
        let step = SiriGrip.lift(reach: reach, dy: dy, down: down, held: carrying || NSEvent.pressedMouseButtons & 1 != 0, carrying: carrying, room: SiriGrip.orb - notch.height)
        reach = step.reach
        guard let put = step.put else { return }
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) - screen.frame.maxY + put))
        CGAssociateMouseAndMouseCursorPosition(1) // A warp otherwise holds mouse moves back for a quarter of a second.
    }

    /// The song stream, started again a second after its reader dies, so the notch never stops following the player.
    /// ponytail: a reader that dies at once is retried every second forever; back off if that ever shows up in the log.
    private func startNowPlaying() {
        nowPlayingStream = NowPlaying.stream { [weak self] n in
            guard let self else { return }
            log("DIAG np \(n?.playing ?? false) art=\(n?.artwork.map { "\(Int($0.size.width))x\(Int($0.size.height)) \($0.tiffRepresentation?.count ?? 0)" } ?? "nil") \(n?.title.prefix(40) ?? "none")") // DIAG
            // A read of the same song without its artwork (a browser still loading it) keeps the one already shown.
            if let n, n.artwork == nil, let old = self.live.nowPlaying, old.title == n.title, let art = old.artwork {
                self.live.nowPlaying = NowPlaying(title: n.title, artist: n.artist, playing: n.playing, artwork: art)
            } else {
                self.live.nowPlaying = n
            }
            if self.live.nowPlaying?.playing == true { self.live.spectrum.start() } else { self.live.spectrum.stop() } // Sound is read only while a song plays.
        }
        nowPlayingStream?.terminationHandler = { [weak self] p in
            log("now playing reader exited \(p.terminationStatus), restarting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.startNowPlaying() }
        }
    }

    /// The collapsed notch's live side: the song stream, the charge flash and the swipe across the notch.
    private func setUpLive() {
        startNowPlaying()

        plugged = Battery.read()?.plugged
        let source = IOPSNotificationCreateRunLoopSource({ me in
            guard let me else { return }
            Unmanaged<App>.fromOpaque(me).takeUnretainedValue().powerChanged()
        }, Unmanaged.passUnretained(self).toOpaque()).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        var sum: CGFloat = 0, sumUp: CGFloat = 0, fired = false, wingSum: CGFloat = 0
        let swipe: (NSEvent) -> Void = { [weak self] e in
            guard e.momentumPhase.isEmpty, let screen = notchScreen() else { return }
            let wheel = e.phase.isEmpty // A mouse wheel has no phase: each tick stands alone.
            if wheel || e.phase == .began { sum = 0; sumUp = 0; fired = false; wingSum = 0 }
            let bare = notchRect(in: screen.frame, notch: notchSize(of: screen))
            let rect = bare.insetBy(dx: -NotchLive.wing, dy: 0)
            let p = NSEvent.mouseLocation, ax = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
            // On the player's wings, up and down set the level: the artwork side brightness, the bars side volume.
            if let self, self.real == .idle, !self.live.locked, self.live.nowPlaying?.playing == true,
               UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true,
               cursor(p, isOver: bare.insetBy(dx: -NotchLive.wing - NotchLive.swell, dy: 0)), !cursor(p, isOver: bare) {
                let dy = e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY
                let steps: Int
                if wheel { steps = dy > 0 ? 1 : dy < 0 ? -1 : 0 } else {
                    wingSum += dy
                    let per: CGFloat = 12 // ponytail: trackpad travel per 64th (~50pt a key press), both wings; raise for slower.
                    steps = Int(wingSum / per)
                    wingSum -= CGFloat(steps) * per
                }
                self.adjust(volume: p.x > bare.midX, steps: steps)
                return
            }
            let open = self?.real == .open
            let overCC = open && (RealControlCenter.openContent.map { IslandBackdrop.area(around: $0).contains(ax) } ?? false)
            guard !fired, cursor(p, isOver: rect) || overCC else { return }
            let knob = UserDefaults.standard.double(forKey: "swipeTravel")
            let travel = knob > 0 ? knob : 50
            // Fingers (or the wheel) moving down, whichever way "natural scrolling" is set.
            sumUp += e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY
            // Moving up while Control Center is open (over it or the notch): it folds away.
            if open, let self {
                guard wheel ? sumUp > 0 : sumUp >= travel else { return }
                fired = true
                self.mustLeave = true
                self.closeReal()
                return Controls.haptic()
            }
            // Moving down while the notch is hovered: Control Center opens at once, without waiting out the dwell.
            if wheel ? sumUp < 0 : sumUp <= -travel, let self, self.live.hover, self.real == .idle {
                fired = true
                return self.openNotch(on: screen) // Its own haptic.
            }
            guard Store.notchGestures, !wheel else { return } // Song swipes are trackpad only.
            sum += e.scrollingDeltaX
            guard let key = Controls.swipeKey(sum, travel: travel) else { return }
            fired = true // One song per swipe, however far it goes.
            Controls.mediaKey(key)
            Controls.haptic()
        }
        // Global for every other app's events, local for the ones over Andeville's own windows.
        swipeMonitors = [NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: swipe),
                         NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { swipe($0); return $0 }]
    }

    /// The volume and brightness keys, taken before macOS sees them (Accessibility, which face unlock already has):
    /// Andeville moves the level itself and shows it in the notch, so the system's HUD never comes up.
    private func setUpHUD() {
        let callback: CGEventTapCallBack = { _, type, event, me in
            guard let me else { return Unmanaged.passUnretained(event) }
            let app = Unmanaged<App>.fromOpaque(me).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { // macOS turns a slow tap off; turn it back on.
                if let tap = app.hudTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return app.hudKey(event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(1 << 14), // NX_SYSDEFINED, where the media keys arrive.
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("hud: no event tap (Accessibility not granted?); the system HUD stays")
            return
        }
        hudTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    }

    /// True when the key was Andeville's to handle. Anything it cannot move itself (an output without a volume, a
    /// display that is not ours to dim, the lock screen, ⌥ for the settings pane) goes on to macOS untouched.
    /// ponytail: no volume feedback pop; play /System/Library/Sounds via NSSound here if it is missed.
    private func hudKey(_ event: CGEvent) -> Bool {
        guard Store.notchHUD, !screenLocked(), let e = NSEvent(cgEvent: event), e.subtype.rawValue == 8 else { return false }
        let key = (e.data1 & 0xFFFF0000) >> 16, down = (e.data1 & 0xFF00) >> 8 == 0xA
        let flags = e.modifierFlags, fine = flags.contains([.option, .shift])
        guard [0, 1, 2, 3, 7].contains(key), !flags.contains(.option) || fine else { return false }
        let hud: NotchHUD
        if key == 2 || key == 3 { // NX_KEYTYPE_BRIGHTNESS_UP, _DOWN
            guard let now = Controls.brightness else { return false }
            guard down else { return true }
            let v = NotchHUD.step(now, up: key == 2, fine: fine)
            Controls.brightness = v
            hud = NotchHUD(symbol: "sun.max.fill", value: v)
        } else { // NX_KEYTYPE_SOUND_UP 0, _DOWN 1, MUTE 7
            guard let now = Controls.volume else { return false }
            guard down else { return true }
            if key == 7 {
                Controls.muted.toggle()
                hud = .volume(now, muted: Controls.muted)
            } else {
                if Controls.muted { Controls.muted = false }
                let v = NotchHUD.step(now, up: key == 0, fine: fine)
                Controls.volume = v
                hud = .volume(v, muted: false)
            }
        }
        showHUD(hud)
        return true
    }

    /// Scroll on the player's wings: left the display brightness, right the volume, both in 64ths, one step per wheel
    /// tick or per stretch of trackpad travel, shown like the keys. `steps` > 0 is up.
    private func adjust(volume: Bool, steps: Int) {
        guard steps != 0 else { return }
        if volume {
            guard var v = Controls.volume else { return }
            if Controls.muted { Controls.muted = false }
            for _ in 0..<abs(steps) { v = NotchHUD.step(v, up: steps > 0, fine: true) } // 64ths: a scroll never jumps loud.
            Controls.volume = v
            showHUD(.volume(v, muted: false))
        } else {
            guard var v = Controls.brightness else { return }
            for _ in 0..<abs(steps) { v = NotchHUD.step(v, up: steps > 0, fine: true) }
            Controls.brightness = v
            showHUD(NotchHUD(symbol: "sun.max.fill", value: v))
        }
    }

    private func showHUD(_ hud: NotchHUD) {
        live.hud = hud
        hudGeneration += 1
        let current = hudGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.hudGeneration == current { self?.live.hud = nil }
        }
    }

    private func powerChanged() {
        guard let b = Battery.read() else { return }
        guard b.plugged != plugged else { return }
        plugged = b.plugged
        guard b.plugged else { live.charge = nil; return }
        live.charge = b
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.plugged == true { self?.live.charge = nil }
        }
    }

    /// The notch's answer: macOS's own Control Center moved under it. Turned off, or when Control Center cannot be
    /// opened, nothing opens.
    private func openNotch(on screen: NSScreen) {
        guard Store.hubRealCC, AXIsProcessTrusted() else { return }
        Controls.haptic()
        real = .opening
        realEditing = false
        // No shape of Andeville's behind it: Control Center opens bare under the notch.
        // ponytail: IslandBackdrop, IslandFill, GlassSection and GlassPrefs stay in the file unused; delete them once the backdrop is surely gone for good.
        RealControlCenter.open(centeredAt: screen.frame.midX) { [weak self] content in
            guard let self else { return }
            guard self.real == .opening else {
                // Given up while it was still opening (Siri was taken out of the notch): it opened all the same, so away with it.
                if self.grip != nil || self.siri != nil { RealControlCenter.close() }
                return
            }
            guard let content else {
                self.real = RealControlCenter.windows().isEmpty ? .idle : .open
                if self.real == .idle { self.backdrop.hide(blur: false) }
                return
            }
            self.real = .open
        }
    }

    /// Calls Siri and takes its orb out of the notch from `spot` (its middle and top); see `SiriGrip`.
    private func takeSiri(on screen: NSScreen, at spot: CGPoint) {
        Controls.haptic()
        grip = SiriGrip(at: spot, on: siriPlace(on: screen)) { [weak self] out in self?.gripDone(out) }
    }

    private func gripDone(_ out: SiriGrip.Out?) {
        grip = nil
        orbHold = nil
        siri = out
        reach = 0
    }

    private func siriPlace(on screen: NSScreen) -> SiriGrip.Place {
        let notch = notchSize(of: screen), others = NSScreen.screens.filter { $0 != screen }, left = screen.frame.minX
        let mid = screen.frame.midX
        return SiriGrip.Place(hidden: notch.height - SiriGrip.orb, width: screen.frame.width, height: screen.frame.height,
                              sides: (others.contains { $0.frame.maxX <= left + 1 } ? left : -.infinity, others.contains { $0.frame.minX >= screen.frame.maxX - 1 } ? left : .infinity),
                              mid: mid, half: notch.width / 2)
    }

    /// Right button on the notch, kept from the menu bar (no "Menu Bar Settings…", no menu at all): pulled down,
    /// the settings window drops in; a plain right-click does nothing.
    private func setUpRightTap() {
        let callback: CGEventTapCallBack = { _, type, event, me in
            guard let me else { return Unmanaged.passUnretained(event) }
            let app = Unmanaged<App>.fromOpaque(me).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = app.rightTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return app.rightEvent(type) ? nil : Unmanaged.passUnretained(event)
        }
        let mask = [CGEventType.rightMouseDown, .rightMouseUp].reduce(CGEventMask(0)) { $0 | 1 << CGEventMask($1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("right tap: no event tap (Accessibility not granted?)")
            return
        }
        rightTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    }

    /// True when the right-button event is kept from the apps: a press on the notch (two fingers on the trackpad) and
    /// its release, so the menu bar shows no menu. The press drops the settings window in.
    fileprivate func rightEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .rightMouseDown:
            guard let screen = notchScreen(), cursor(NSEvent.mouseLocation, isOver: notchRect(in: screen.frame, notch: notchSize(of: screen))) else {
                rightOnNotch = false
                return false
            }
            rightOnNotch = true
            dropSettings(on: screen)
            return true
        case .rightMouseUp:
            defer { rightOnNotch = false }
            return rightOnNotch
        default: return false
        }
    }

    private func dropSettings(on screen: NSScreen) {
        if real != .idle { closeReal() }
        let w = settingsReady()
        guard !w.isVisible, fall == nil else { return w.makeKeyAndOrderFront(nil) }
        // Lands on the notch's screen (the MacBook's), not whichever screen has the menu bar's focus.
        let v = screen.visibleFrame
        w.setFrameOrigin(NSPoint(x: v.midX - w.frame.width / 2, y: v.midY - w.frame.height / 2))
        fall = SettingsFall(window: w, on: screen)
        Controls.haptic()
        fall?.land { [weak self] in self?.fall = nil }
    }

    /// Presses, before the apps get them, while Siri is out. Siri drags its own window, but only as far up as a
    /// window goes, and a window that it and Andeville both move jumps between the two. So a press on the orb is
    /// kept from Siri: moved, the orb is in Andeville's hand until the button comes up; not moved, it was a click,
    /// and Siri gets it after all.
    private func setUpGripTap() {
        let callback: CGEventTapCallBack = { _, type, event, me in
            guard let me else { return Unmanaged.passUnretained(event) }
            let app = Unmanaged<App>.fromOpaque(me).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { // macOS turns a slow tap off.
                app.orbPress = nil
                if app.orbHold != nil { // Mid-drag: the orb is let go where it is.
                    app.orbHold = nil
                    app.grip?.release()
                }
                if let tap = app.gripTap, app.siri != nil { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return app.orbEvent(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        let mask = [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged].reduce(CGEventMask(0)) { $0 | 1 << CGEventMask($1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("siri: no event tap (Accessibility not granted?); the orb cannot be dragged back into the notch")
            return
        }
        gripTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false) // On only while Siri is out.
    }

    /// True when the event is kept from the apps.
    private func orbEvent(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayed { return false }
        switch type {
        case .leftMouseDown:
            // On the orb itself, and only while Siri is just its orb: an answer's panel is Siri's to click and drag in.
            let r = SiriGrip.orb / 2, at = event.location
            guard grip == nil, let c = siri?.content, c.height <= 110, hypot(at.x - c.midX, at.y - (c.minY + SiriGrip.inset + r)) <= r else { return false }
            (orbPress, orbHold) = (at, nil)
            return true
        case .leftMouseDragged:
            guard let press = orbPress else { return false }
            liftCursor(by: CGFloat(event.getIntegerValueField(.mouseEventDeltaY))) // The monitors do not see what is kept back.
            guard let screen = notchScreen(), let s = siri else { return true }
            let at = event.location, top = (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) - screen.frame.maxY
            // Moved: the orb is in hand where it was pressed. Straight from the mouse's own events, not from the
            // notch timer, which a busy moment holds up.
            if orbHold == nil, hypot(at.x - press.x, at.y - press.y) >= 3 {
                let orbTop = s.content.minY + SiriGrip.inset
                orbHold = CGPoint(x: press.x - s.content.midX, y: press.y - orbTop)
                Controls.haptic()
                grip = SiriGrip(at: CGPoint(x: s.content.midX, y: orbTop), again: s, on: siriPlace(on: screen)) { [weak self] out in self?.gripDone(out) }
            }
            if let h = orbHold, let grip {
                // The cursor's height, going on over the top of the screen inside the notch; the orb no further in than the notch holds it.
                let y = reach > 0 ? top - reach : at.y
                grip.move(to: CGPoint(x: at.x - h.x, y: max(y - h.y, top + notchSize(of: screen).height - SiriGrip.orb)))
            }
            return true
        case .leftMouseUp:
            guard let at = orbPress else { return false }
            orbPress = nil
            if orbHold != nil {
                orbHold = nil
                grip?.release()
            } else { // Not moved: a click, which Siri gets after all.
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                    guard let click = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left) else { continue }
                    click.setIntegerValueField(.eventSourceUserData, value: Self.replayed)
                    click.post(tap: .cgSessionEventTap)
                }
            }
            return true
        default:
            return false
        }
    }

    /// Control Center goes out into a blur while the island folds away (or at once without the island).
    private func closeReal() {
        real = .idle
        RealControlCenter.close()
    }

    /// Icons are cached: loading them takes ~20 ms.
    private func lockedAppList() -> [LockedApp] {
        Store.lockedApps.map { id in
            if let app = appCache[id] { return app }
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
            let app = LockedApp(id: id, name: url?.deletingPathExtension().lastPathComponent ?? id, icon: icon)
            appCache[id] = app
            return app
        }
    }

    @objc private func openSettings() {
        settingsReady().makeKeyAndOrderFront(nil)
    }

    private func settingsReady() -> NSWindow {
        NSApp.activate(ignoringOtherApps: true)
        refreshSettings()
        if settingsWindow == nil {
            let actions = SettingsActions(
                enroll: { [weak self] in self?.enroll() },
                test: { [weak self] in self?.test() },
                togglePassword: { [weak self] in
                    self?.toggleUnlock()
                    self?.refreshSettings()
                },
                revealConsent: { [weak self] in self?.revealConsent() },
                toggleLogin: { [weak self] in
                    self?.toggleLogin()
                    self?.refreshSettings()
                },
                addApp: { [weak self] in
                    self?.addApp()
                    self?.refreshSettings()
                },
                removeApp: { [weak self] in self?.removeLockedApp($0) }
            )
            let w = makeSettingsWindow(SettingsView(model: settingsModel, actions: actions))
            w.delegate = self
            settingsWindow = w
            return w
        }
        return settingsWindow!
    }

    private func refreshSettings() {
        settingsModel.hasPassword = Store.hasPassword
        settingsModel.consent = Store.consents.last
        settingsModel.loginItem = SMAppService.mainApp.status == .enabled
        settingsModel.faceCount = faces.count
        settingsModel.lockedApps = lockedAppList()
    }

    // Returning from enrollment or a permission alert must show the new state.
    func windowDidBecomeKey(_ n: Notification) {
        if (n.object as? NSWindow) === settingsWindow { refreshSettings() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLogin() {
        let s = SMAppService.mainApp
        do { if s.status == .enabled { try s.unregister() } else { try s.register() } }
        catch { alert("로그인 항목 변경 실패: \(error.localizedDescription)") }
    }

    private func alert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = text
        a.runModal()
    }

    // MARK: Scanning

    private func withCamera(_ go: @escaping () -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                if ok { go() } else { self.alert("시스템 설정 > 개인정보 보호 > 카메라에서 Andeville을 허용해 주세요.") }
            }
        }
    }

    /// `frame` runs on the camera queue and returns true to finish successfully.
    private func scan(seconds: Double?, frame: @escaping (FaceFrame) -> Bool, done: @escaping (Bool) -> Void) {
        guard !busy, camera.start() else { return done(false) }
        busy = true
        var finished = false
        let finish: (Bool) -> Void = { ok in
            guard !finished else { return }
            finished = true
            self.cancelScan = nil
            self.camera.stop()
            self.busy = false
            done(ok)
        }
        camera.onFrame = { f in
            if frame(f) { DispatchQueue.main.async { finish(true) } }
        }
        cancelScan = { finish(false) }
        if let seconds { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish(false) } }
    }

    private func bestDistance(_ embedding: [Float], _ against: [[Float]]) -> Float {
        against.map { cosineDistance(embedding, $0) }.min() ?? .infinity
    }

    /// A frame that looks like a photo or screen counts as no match at all, resetting the match streak.
    /// Call right after `scan` starts; pair with `fillLight.off()` when it ends.
    private func lightIfDark(overLockScreen: Bool) {
        guard Store.fillLight else { return }
        let limit = Store.darkLuma
        var darkFrames = 0
        camera.onLuma = { luma in
            darkFrames = luma < limit ? darkFrames + 1 : 0
            if darkFrames == 8 { // Auto-exposure needs a moment; a cold camera always starts dark.
                log("dark scene (luma \(luma)), screen light on")
                DispatchQueue.main.async { self.fillLight.on(overLockScreen: overLockScreen) }
            }
        }
    }

    private func matchDistance(_ f: FaceFrame, _ against: [[Float]]) -> Float {
        f.live >= Store.liveThreshold ? bestDistance(f.embedding, against) : .infinity
    }

    private func verify(island showIsland: Bool, overLockScreen: Bool = false, seconds: Double, done: @escaping (Bool) -> Void) {
        guard !busy else { return done(false) }
        var v = Verifier(threshold: Store.threshold)
        let known = faces
        if showIsland { island.show("카메라를 봐 주세요", overLockScreen: overLockScreen) }
        scan(seconds: seconds, frame: { f in
            v.feed(distance: self.matchDistance(f, known))
        }, done: { ok in
            self.fillLight.off()
            if showIsland { self.island.finish(ok) { done(ok) } } else { done(ok) }
        })
        lightIfDark(overLockScreen: overLockScreen)
    }

    // MARK: Enroll and test

    @objc private func enroll() {
        NSApp.activate(ignoringOtherApps: true)
        if let enrollWindow { return enrollWindow.makeKeyAndOrderFront(nil) }
        enrollModel.phase = .intro
        enrollModel.round = 1
        enrollSamples = []
        let w = makeEnrollWindow(EnrollView(model: enrollModel, session: camera.session) { [weak self] in self?.enrollAction() })
        w.delegate = self
        enrollWindow = w
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) {
        guard (n.object as? NSWindow) === enrollWindow else { return }
        enrollWindow = nil // Cleared first, so the cancelled scan knows nobody is watching.
        cancelScan?()
    }

    private func enrollAction() {
        switch enrollModel.phase {
        case .intro, .failed:
            enrollModel.round = 1
            enrollSamples = []
            withCamera { self.enrollScan() }
        case .between:
            enrollModel.round = 2
            enrollScan()
        case .done:
            enrollWindow?.close()
            if !Store.hasPassword { toggleUnlock() }
        case .scanning:
            break
        }
    }

    private func enrollScan() {
        guard !busy else { return }
        var ring = EnrollRing()
        var samples: [[Float]] = []
        var tick = 0
        let enough = 8
        enrollModel.ring = ring.filled
        scan(seconds: 30, frame: { f in
            tick += 1
            // Only near-frontal views: strongly turned faces make poor references.
            if tick % 5 == 0, abs(f.turn) < 0.35, samples.count < 25 { samples.append(f.embedding) }
            if ring.feed(turn: f.turn, pitch: f.pitch) {
                let filled = ring.filled
                DispatchQueue.main.async { self.enrollModel.ring = filled }
            }
            return ring.progress >= 0.9 && samples.count >= enough
        }, done: { [self] _ in
            guard enrollWindow != nil else { return }
            // A partly filled ring still counts: the ring is guidance, the samples are what matters.
            guard samples.count >= enough else { return enrollModel.phase = .failed }
            enrollSamples += samples
            guard enrollModel.round == 2 else { return enrollModel.phase = .between }
            do {
                try Store.saveFaces(enrollSamples)
                faces = enrollSamples
                enrollModel.phase = .done
            } catch {
                log("enroll save failed: \(error)")
                enrollModel.phase = .failed
            }
        })
        enrollModel.phase = .scanning
    }

    @objc private func test() {
        withCamera {
            let known = self.faces, limit = Store.threshold
            guard !self.busy else { return }
            var v = Verifier(threshold: limit)
            self.island.show("카메라를 봐 주세요")
            self.scan(seconds: 20, frame: { f in
                let d = self.bestDistance(f.embedding, known)
                DispatchQueue.main.async { self.island.update(String(format: "거리 %.3f · 실물 %.2f", d, f.live)) }
                return v.feed(distance: self.matchDistance(f, known))
            }, done: { ok in
                self.fillLight.off()
                self.island.finish(ok)
            })
            self.lightIfDark(overLockScreen: false)
        }
    }

    // MARK: Lock screen

    @objc private func toggleUnlock() {
        if Store.hasPassword { return Store.deletePassword() }
        guard !faces.isEmpty else { return alert("먼저 얼굴을 등록해 주세요.") }
        guard Store.hasCurrentConsent else { return showConsent { [weak self] in self?.toggleUnlock() } }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "맥 로그인 비밀번호"
        a.informativeText = "키체인에 저장되며, 얼굴이 일치하면 잠금화면에 입력됩니다. 비슷한 얼굴이나 사진·영상으로 잠금이 풀릴 수 있습니다."
        a.addButton(withTitle: "저장")
        a.addButton(withTitle: "취소")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        a.accessoryView = field
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard passwordIsCorrect(field.stringValue) else { return alert("비밀번호가 맞지 않습니다.") }
        guard Store.savePassword(field.stringValue) else { return alert("키체인 저장에 실패했습니다.") }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            alert("시스템 설정 > 손쉬운 사용에서 Andeville을 허용해야 비밀번호를 입력할 수 있습니다.")
        }
        withCamera {}
    }

    private func passwordIsCorrect(_ pw: String) -> Bool {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication)),
              let rec = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil) else { return false }
        return (try? rec.verifyPassword(pw)) != nil
    }

    private func startSonarWatch() {
        stopSonarWatch()
        guard presenceSource == .sonar else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return log("skip sonar: no microphone permission") }
        let probe = ChirpProbe()
        var presence = ChirpPresence(sensitivity: Store.sonarSensitivity)
        let started = probe.start { m in
            guard presence.feed(m.score) else { return }
            DispatchQueue.main.async { self.sonarTriggered() }
        }
        guard started else { return log("sonar failed to start") }
        sonar = probe
        log("sonar watch start")
    }

    private func stopSonarWatch() {
        sonar?.stop()
        sonar = nil
    }

    /// Which away detector runs now, if any.
    private var presenceSource: PresenceMode? {
        guard Store.presenceOn else { return nil }
        let m = Store.presenceMode
        return m == .auto ? (airpodsConnected == true ? .airpods : .sonar) : m
    }

    private func startAirPodsWatch() {
        stopAirPodsWatch()
        guard presenceSource == .airpods else { return }
        var presence = AirPodsPresence(sensitivity: Store.airpodsSensitivity)
        airpodsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let rssi = AirPods.connected()?.rawRSSI(), rssi != 127 else { return } // 127: no reading
            if presence.feed(Int(rssi)) { self.sonarTriggered("airpods") }
        }
        log("airpods watch start")
    }

    private func stopAirPodsWatch() {
        airpodsTimer?.invalidate()
        airpodsTimer = nil
    }

    private func sonarTriggered(_ source: String = "sonar") {
        guard screenLocked(), !busy, Date() >= faceRetryAfter, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return }
        log("\(source) trigger")
        faceRetryAfter = Date() + 20 // A false trigger must not keep the camera cycling.
        unlockWithFace()
    }

    private func stopFaceWatch() {
        if faceWatching { cancelScan?() }
    }

    /// Started by a notch hover: the owner's face alone unlocks.
    private func unlockWithFace() {
        log("scan start")
        let revealed = Date()
        DispatchQueue.global().async { revealPasswordField() }
        faceWatching = true
        verify(island: true, overLockScreen: true, seconds: 8) { ok in
            self.faceWatching = false
            log(String(format: "scan result: \(ok) after %.2fs", Date().timeIntervalSince(revealed)))
            guard ok, screenLocked() else { return }
            self.faceRetryAfter = Date() + 5 // Long enough for typing to land before a new hover can count.
            let started = Date()
            guard let pw = Store.password() else {
                if !Store.hasCurrentConsent { self.island.askConsent(overLockScreen: true) }
                return
            }
            // A slow read means a keychain prompt was answered, so the user may already be back in an app.
            guard Date().timeIntervalSince(started) < 1, screenLocked() else { return log("typing aborted: state changed during keychain read") }
            log("typing password")
            DispatchQueue.global().async {
                let ok = typeIntoLockScreen(pw, revealedAt: revealed)
                log(String(format: ok ? "typing finished %.2fs after scan start" : "typing aborted: screen unlocked", Date().timeIntervalSince(revealed)))
            }
        }
    }

    /// Backup for a lid close, where the system can sleep before the lock timer sees the display go dark.
    @objc private func screensDidWake() {
        log("screens woke")
        wakePending = true
    }

    @objc private func screenDidUnlock() {
        live.locked = false
        lockAwake.map(ProcessInfo.processInfo.endActivity)
        lockAwake = nil
    }

    @objc private func screenDidLock() {
        let wings = Store.liveActivity && live.nowPlaying?.playing == true
        live.locked = true // The wings fold in right now, during the transition.
        notchBase.sitOutLock(hold: wings ? 0.3 : 0)
        log("screen locked")
        if Store.lockAwake, lockAwake == nil {
            lockAwake = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled, reason: "Stay awake on the lock screen")
        }
        unlockedApps.removeAll()
        lockTimer?.invalidate()
        lockTimer = nil
        guard Store.hasPassword, !faces.isEmpty else { return log("skip: password saved=\(Store.hasPassword), faces=\(faces.count)") }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return log("skip: no camera permission") }
        guard AXIsProcessTrusted() else { return log("skip: no accessibility permission") }
        faceRetryAfter = Date()
        startSonarWatch()
        startAirPodsWatch()
        var wasOver = true // A cursor already on the notch at lock time must leave and come back.
        var awakeTicks = 0
        wakePending = false
        // Polled because event monitors do not receive input on the lock screen.
        lockTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            guard screenLocked() else {
                self.stopFaceWatch()
                self.stopSonarWatch()
                self.stopAirPodsWatch()
                self.lockTimer = nil
                return t.invalidate()
            }
            if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
                self.stopFaceWatch()
                wasOver = false
                self.wakePending = true
                awakeTicks = 0
                return
            }
            // Display back on (lid opened or woken from display sleep): scan without waiting for a notch hover.
            if self.wakePending {
                awakeTicks += 1
                if awakeTicks >= 10, !self.busy { // ~0.5s for the camera and lock screen window to settle.
                    self.wakePending = false
                    log("wake trigger")
                    self.unlockWithFace()
                }
            }
            guard let screen = notchScreen() else { return }
            let over = cursor(NSEvent.mouseLocation, isOver: notchRect(in: screen.frame, notch: notchSize(of: screen)))
            if over, !wasOver, !self.busy, Date() >= self.faceRetryAfter {
                log("cursor entered notch")
                self.unlockWithFace()
            }
            wasOver = over
        }
    }

    // MARK: App lock

    @objc private func addApp() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.applicationBundle]
        guard p.runModal() == .OK, let u = p.url, let id = Bundle(url: u)?.bundleIdentifier, id != Store.service else { return }
        if !Store.lockedApps.contains(id) { Store.lockedApps.append(id) }
    }

    private func removeLockedApp(_ id: String) {
        authenticate(reason: "앱 잠금 해제") { ok in
            guard ok else { return }
            Store.lockedApps.removeAll { $0 == id }
            self.refreshSettings()
        }
    }

    @objc private func appQuit(_ n: Notification) {
        guard let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
        unlockedApps.remove(id)
    }

    @objc private func appActivated(_ n: Notification) {
        guard !faces.isEmpty, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier, Store.lockedApps.contains(id), !unlockedApps.contains(id) else { return }
        // ponytail: hides the window only, app data stays unencrypted on disk.
        app.hide()
        guard pendingApp == nil else { return }
        pendingApp = app
        authenticate(reason: "\(app.localizedName ?? id) 열기") { ok in
            self.pendingApp = nil
            guard ok else { return }
            self.unlockedApps.insert(id)
            app.unhide()
            app.activate()
        }
    }

    /// Face first, then Touch ID or password as the fallback.
    private func authenticate(reason: String, done: @escaping (Bool) -> Void) {
        let fallback = {
            LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { passed, _ in
                DispatchQueue.main.async { done(passed) }
            }
        }
        guard !faces.isEmpty else { return fallback() }
        withCamera {
            self.verify(island: true, seconds: 8) { ok in ok ? done(true) : fallback() }
        }
    }
}

if CommandLine.arguments.contains("--self-check") {
    selfCheck()
    exit(0)
}

if CommandLine.arguments.contains("--island-demo") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let demo = Island()
    demo.show("카메라를 봐 주세요", overLockScreen: CommandLine.arguments.contains("--over-lock"))
    let demoLight = FillLight()
    if CommandLine.arguments.contains("--fill") {
        demoLight.on(overLockScreen: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { demoLight.off() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { demo.finish(true) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { demo.show("카메라를 봐 주세요") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 7) { demo.finish(false) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 9.5) { exit(0) }
    NSApp.run()
}

if CommandLine.arguments.contains("--consent-demo") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let demo = Island()
    demo.askConsent()
    let consentDemo = makeConsentWindow(ConsentView(renewal: true) {})
    NSApp.activate(ignoringOtherApps: true)
    consentDemo.makeKeyAndOrderFront(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
    NSApp.run()
}

if let i = CommandLine.arguments.firstIndex(of: "--enroll-demo") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let model = EnrollModel()
    let name = CommandLine.arguments.dropFirst(i + 1).first ?? "scanning"
    model.phase = ["intro": .intro, "between": .between, "done": .done, "failed": .failed][name] ?? .scanning
    model.ring = (0..<EnrollRing.count).map { $0 < 38 }
    let demoWindow = makeEnrollWindow(EnrollView(model: model, session: AVCaptureSession()) {})
    NSApp.activate(ignoringOtherApps: true)
    demoWindow.makeKeyAndOrderFront(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    NSApp.run()
}

if let i = CommandLine.arguments.firstIndex(of: "--settings-demo") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let model = SettingsModel()
    model.page = SettingsPage(rawValue: CommandLine.arguments.dropFirst(i + 1).first ?? "") ?? .general
    model.hasPassword = true
    model.faceCount = 50
    model.lockedApps = ["Safari", "Notes", "Mail"].map { name in
        LockedApp(id: name, name: name, icon: NSWorkspace.shared.icon(forFile: "/System/Applications/\(name).app"))
    }
    let settingsDemo = makeSettingsWindow(SettingsView(model: model, actions: SettingsActions()))
    NSApp.activate(ignoringOtherApps: true)
    settingsDemo.makeKeyAndOrderFront(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    NSApp.run()
}

if let i = CommandLine.arguments.firstIndex(of: "--chirp-test") {
    // Arguments: label, seconds to record, seconds to wait first (time to walk away).
    let args = Array(CommandLine.arguments.dropFirst(i + 1))
    let label = args.first ?? "test"
    let seconds = args.count > 1 ? Double(args[1]) ?? 25 : 25
    let wait = args.count > 2 ? Double(args[2]) ?? 0 : 0
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let chirpProbe = ChirpProbe()
    AVCaptureDevice.requestAccess(for: .audio) { ok in
        DispatchQueue.main.async {
            guard ok else { exit(1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                chirpProbe.run(label: label, seconds: seconds) { exit(0) }
            }
        }
    }
    NSApp.run()
}

let delegate = App()
NSApplication.shared.delegate = delegate
NSApp.setActivationPolicy(.accessory)
NSApp.run()
