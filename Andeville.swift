import AppKit
import Accelerate
import AVFoundation
import CoreAudio
import Combine
import CoreML
import CoreImage
import CryptoKit
import IOBluetooth
import IOKit.ps
import LocalAuthentication
import OpenDirectory
import CommonCrypto
import Security
import SQLite3
import SceneKit
import ScreenCaptureKit
import ServiceManagement
import SwiftUI
import Vision
import WebKit

// MARK: - Brand

/// The website's rule: orange is the moment Andeville recognises you or answers you. A recognised state, the one
/// primary action on a screen, the accent of a control you just set. Never decoration and never a warning (that is red).
enum Brand {
    static let orangeNS = NSColor(srgbRed: 1, green: 0x5B / 255.0, blue: 0x14 / 255.0, alpha: 1) // #FF5B14
    static let orange = Color(nsColor: orangeNS)
    static let ink = Color(red: 0x15 / 255.0, green: 0x15 / 255.0, blue: 0x15 / 255.0) // #151515, the text on orange
}

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

/// A panel that stays where it is put, even up in the menu bar: AppKit moves a window under the menu bar's level down
/// out of it otherwise.
final class PinnedPanel: NSPanel {
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { r }
}

/// The collapsed notch's live activity: while a song plays, the notch grows a wing each side, artwork left and a
/// waveform right; plugging in the power adapter shows the charge there for a moment. Otherwise the bare notch shape.
struct NotchLive: View {
    @ObservedObject var model: NotchModel
    let notch: CGSize
    /// The menu bar's height: hovered, the notch reaches down to its bottom edge and no further.
    var bar: CGFloat = 0
    @AppStorage("liveActivity") private var liveActivity = true
    private var enabled: Bool { liveActivity && model.liveUp }
    @AppStorage("hoverSpeed") private var hoverSpeed = Store.hoverSpeedDefault
    @AppStorage("notchEar") private var ear = Store.notchEarDefault // Redraws live when the slider moves.
    static let wing: CGFloat = 44
    /// How far the notch widens under the cursor, each side.
    static let swell: CGFloat = 3

    var body: some View {
        // Paused, the song stays a minute (and while the cursor is on its bars), to be played again from there.
        let song = model.locked ? nil : model.nowPlaying.flatMap { $0.playing || model.paused || model.barsHover ? $0 : nil }
        let on = model.hud != nil || enabled && (model.charge != nil || model.accessory != nil || song != nil)
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
                    } else if let a = model.accessory {
                        SpinIn(shown: a).id(a.id).transition(.blurReplace)
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
                    } else if let a = model.accessory {
                        BatteryRing(level: a.level).transition(.blurReplace)
                    } else if model.barsHover, let song {
                        // Hovered, the bars blur into pause (or play): a click there sends the play/pause key.
                        Image(systemName: song.playing ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint).contentTransition(.symbolEffect(.replace))
                            .transition(.blurReplace)
                    } else {
                        MusicBars(playing: song?.playing == true, color: tint, spectrum: model.spectrum)
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
        .animation(.easeInOut(duration: 0.25), value: model.accessory?.id)
        .animation(.easeInOut(duration: 0.3), value: model.hud != nil) // Inner, so it wins over the 0.15 below: the blur swap with the player has time to read.
        .animation(.easeInOut(duration: 0.15), value: model.hud?.symbol)
        .animation(.easeInOut(duration: 0.25), value: model.barsHover)
        .animation(.easeInOut(duration: 0.2), value: song?.playing)
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

/// The connected AirPods turning as one pair about their vertical axis, as the Dynamic Island shows them on iPhone: two
/// buds facing front, a half turn in which they close into one bud seen side on, a pause, then two buds again. Apple's
/// own 3D model of them (`Buds3D`), else the SF Symbol.
struct SpinIn: View {
    let shown: AirPods.Shown
    var body: some View {
        if let scene = Buds3D.cached(shown.model) {
            Buds3D(scene: scene).frame(width: 30, height: 18)
        } else {
            Image(systemName: shown.max ? "airpodsmax" : "airpods.pro").font(.system(size: 12, weight: .medium))
        }
    }
}

/// Apple's AR model of the AirPods (the `.usdz` apple.com shows in AR, built into the app from `AirPods3D/`), the case
/// left out, turning from the first frame the notch starts to widen: one whole turn without a stop, ending front on,
/// after which the notch closes again.
struct Buds3D: NSViewRepresentable {
    let scene: (SCNScene, SCNNode)

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero, options: nil)
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        v.autoenablesDefaultLighting = true
        v.rendersContinuously = true
        v.scene = scene.0
        v.isPlaying = true
        // The scene is kept between connections: back to front, then straight into the turn, fastest at the start
        // so it is already moving as the notch widens.
        scene.1.removeAllActions()
        scene.1.eulerAngles.y = 0
        let turn = SCNAction.rotateBy(x: 0, y: .pi * 2 * Buds3D.turns, z: 0, duration: Buds3D.spin)
        turn.timingMode = .easeOut
        scene.1.runAction(turn)
        return v
    }
    func updateNSView(_ v: SCNView, context: Context) {}

    /// Models already read, by name. Main thread only. Read at launch (`preload`), as a 6 MB model read when the
    /// AirPods connect holds up the notch's first frames.
    private static var loaded: [String: (SCNScene, SCNNode)] = [:]
    static let models = ["airpods-pro", "airpods-mid", "airpods-max-midnight"]
    /// Whole turns, and how long they take; the notch closes `spin` plus a breath after the AirPods connect.
    static let turns: CGFloat = 1, spin: TimeInterval = 4.8

    static func preload() {
        DispatchQueue.global(qos: .utility).async {
            for m in models { if let l = load(m) { DispatchQueue.main.async { loaded[m] = loaded[m] ?? l } } }
        }
    }

    static func cached(_ name: String) -> (SCNScene, SCNNode)? {
        if loaded[name] == nil { loaded[name] = load(name) } // Connected before the preload got there.
        return loaded[name]
    }

    /// The model's scene with only the buds shown (the part standing highest; the case sits below them), turning about
    /// their own center, and a camera that fits them to a 30 by 18 point view. Nil when the model is not in the app.
    static func load(_ name: String) -> (SCNScene, SCNNode)? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "usdz"),
              let s = try? SCNScene(url: url), let group = s.rootNode.childNodes.first?.childNodes.first else { return nil }
        let parts = group.childNodes.filter { $0.boundingBox.max.x > $0.boundingBox.min.x }
        guard let buds = parts.max(by: { $0.boundingBox.min.y < $1.boundingBox.min.y }) else { return nil }
        if parts.count > 1 { parts.filter { $0 !== buds }.forEach { $0.isHidden = true } } // A lone part (AirPods Max) is the whole thing.
        let (lo, hi) = buds.boundingBox
        buds.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        let width = max(hi.x - lo.x, (hi.y - lo.y) * 30 / 18) * 1.1, distance: CGFloat = 60
        let cam = SCNNode(); cam.camera = SCNCamera()
        cam.camera!.projectionDirection = .horizontal
        cam.camera!.fieldOfView = 2 * atan(width / 2 / distance) * 180 / .pi
        cam.position = SCNVector3(0, 0, distance)
        s.rootNode.addChildNode(cam)
        return (s, buds)
    }
}

/// The accessory's charge as a ring, green, red at 20% and below; a dim empty ring while the level is unknown.
struct BatteryRing: View {
    let level: Int?
    var body: some View {
        let v = Double(level ?? 0) / 100, color: Color = (level ?? 100) <= 20 ? .red : .green
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: v).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
        .animation(.easeOut(duration: 0.6), value: level)
    }
}

/// The Dynamic Island's music bars, bass on the left to treble on the right, moving with what the Mac is playing
/// (`Spectrum`), tinted from the artwork; flat when stopped.
struct MusicBars: View {
    let playing: Bool, color: Color
    @ObservedObject var spectrum: Spectrum
    static let count = 4

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

/// The Mac's sound output in four bands, bass to treble, 0...1 each. Reads it through a Core Audio process tap (macOS 14.2+;
/// asks once for System Audio Recording), only while a song plays. Nothing is recorded or kept.
final class Spectrum: ObservableObject {
    @Published private(set) var levels = [CGFloat](repeating: 0, count: MusicBars.count)
    static let n = 1024
    /// Band edges in Hz: bass, low-mid, upper-mid, treble.
    static let edges: [Double] = [40, 250, 1000, 4000, 16000]
    private var tap = AudioObjectID(kAudioObjectUnknown), aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "spectrum", qos: .userInteractive)
    // On `queue` only.
    private var samples: [Float] = []
    private var sampleRate = 48000.0
    private var ceiling: [Float] = [], floor: [Float] = [] // Empty until the first block sets them around it.
    private var smooth = [CGFloat](repeating: 0, count: MusicBars.count)
    private var gain: CGFloat = 1, feeds = 0, blocks = 0
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
        // ponytail: volume re-read every 24 buffers (~0.25 s); the HAL calls per buffer were the audio thread's main cost.
        if feeds % 24 == 0 { gain = Spectrum.gain(volume: Controls.volume ?? 1, muted: Controls.muted) }
        feeds &+= 1
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
                let target: CGFloat = db[i] < -90 ? 0 : CGFloat(min(max((db[i] - floor[i]) / range, 0), 1)) * gain
                // Eased toward it, rising quicker than falling, so bars glide instead of jumping block to block.
                // ponytail: 0.35 up / 0.12 down per ~21 ms block; lower both for calmer bars.
                smooth[i] += (target - smooth[i]) * (target > smooth[i] ? 0.35 : 0.12)
                out[i] = smooth[i]
            }
            // Every other block (~23×/s): each one redraws the notch, and the bars' 0.12 s ease fills in between.
            // ponytail: the redraw was the main thread's largest cost while a song plays; every block if bars look late.
            blocks &+= 1
            if blocks % 2 == 0 { DispatchQueue.main.async { if self.levels != out { self.levels = out } } } // Silence: no redraw.
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

    /// How tall the bars may get at this output volume: the tap hears the sound before the volume is applied, so it
    /// is put back here. The square root keeps them readable at low volumes; muted they lie flat.
    static func gain(volume: Double, muted: Bool) -> CGFloat { muted ? 0 : CGFloat(min(max(volume, 0), 1).squareRoot()) }

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
        case .success: return Brand.orange
        case .failure: return .red
        case .consent: return .white
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
    private typealias Connection = (cid: Int32, space: Int32, addWindows: @convention(c) (Int32, Int32, CFArray, Int32) -> Int32)
    private static let connection = open(level: 400)
    private static let beside = open(level: 0)

    /// A window-server space of Andeville's own, always shown, at that absolute level (the desktops are at 0, the lock screen at 300).
    private static func open(level absolute: Int32) -> Connection? {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let main = dlsym(lib, "SLSMainConnectionID"), let create = dlsym(lib, "SLSSpaceCreate"),
              let level = dlsym(lib, "SLSSpaceSetAbsoluteLevel"), let show = dlsym(lib, "SLSShowSpaces"),
              let add = dlsym(lib, "SLSSpaceAddWindowsAndRemoveFromSpaces") else { log("SkyLight symbols missing"); return nil }
        let cid = unsafeBitCast(main, to: (@convention(c) () -> Int32).self)()
        let space = unsafeBitCast(create, to: (@convention(c) (Int32, Int32, Int32) -> Int32).self)(cid, 1, 0)
        _ = unsafeBitCast(level, to: (@convention(c) (Int32, Int32, Int32) -> Int32).self)(cid, space, absolute)
        _ = unsafeBitCast(show, to: (@convention(c) (Int32, CFArray) -> Int32).self)(cid, [space] as CFArray)
        return (cid, space, unsafeBitCast(add, to: (@convention(c) (Int32, Int32, CFArray, Int32) -> Int32).self))
    }

    static func adopt(_ window: NSWindow) {
        guard let c = connection else { return }
        _ = c.addWindows(c.cid, c.space, [window.windowNumber] as CFArray, 7)
    }

    /// Out of the desktops and into a space beside them, at their level: the window stays where it is as one desktop
    /// slides to the next, as the Dock does (a window on every desktop slides off and back in with them), and is still
    /// stacked among the desktop's windows by its own level, under menus and notifications.
    static func pin(_ window: NSWindow) {
        guard let c = beside else { return }
        _ = c.addWindows(c.cid, c.space, [window.windowNumber] as CFArray, 7)
    }
}

/// Private SkyLight API: a screen's desktops (Spaces), so a window can be put on each ahead of time and slide in with
/// its desktop, as the wallpaper does. A window on every desktop instead stays behind with the one sliding out.
enum Desktops {
    private static let api: (cid: Int32, copy: @convention(c) (Int32) -> Unmanaged<CFArray>?,
                             move: @convention(c) (Int32, CFArray, UInt64) -> Void)? = {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let main = dlsym(lib, "SLSMainConnectionID"), let copy = dlsym(lib, "SLSCopyManagedDisplaySpaces"),
              let move = dlsym(lib, "SLSMoveWindowsToManagedSpace") else { log("SkyLight spaces missing"); return nil }
        return (unsafeBitCast(main, to: (@convention(c) () -> Int32).self)(),
                unsafeBitCast(copy, to: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self),
                unsafeBitCast(move, to: (@convention(c) (Int32, CFArray, UInt64) -> Void).self))
    }()

    /// The screen's Spaces, in order, and whether each is a desktop (type 0) rather than a full-screen app's.
    /// The screen's entry in the window server's list of Spaces.
    private static func display(_ screen: NSScreen) -> [String: Any]? {
        guard let a = api, let all = a.copy(a.cid)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        let uuid = CFUUIDCreateString(nil, CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()) as String?
        // "Displays have separate Spaces" off: one list, named "Main", for every screen.
        return all.first { $0["Display Identifier"] as? String == uuid } ?? all.first { $0["Display Identifier"] as? String == "Main" }
    }

    static func of(_ screen: NSScreen) -> [(id: UInt64, desktop: Bool)] {
        (display(screen)?["Spaces"] as? [[String: Any]] ?? []).compactMap { sp in
            (sp["id64"] as? NSNumber).map { ($0.uint64Value, (sp["type"] as? NSNumber)?.intValue == 0) }
        }
    }

    /// macOS's menu bar is showing on that Space: always when it is not set to hide, and while it is slid down when it is.
    static func menuBarShows(on space: UInt64) -> Bool {
        guard let a = api, let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLSIsMenuBarVisibleOnSpace") else { return false }
        return unsafeBitCast(f, to: (@convention(c) (Int32, UInt64) -> Bool).self)(a.cid, space)
    }

    /// The menu bar's titles and icons are light there (the theme the window server gives the menu bar on that Space:
    /// light on dark in Dark Mode whatever is behind, and over a dark wallpaper). Without the call, as the system theme has it.
    static func menuBarTextIsLight(on space: UInt64) -> Bool {
        guard let a = api, let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLSGetMenuAppearanceThemeOnSpace") else {
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        return unsafeBitCast(f, to: (@convention(c) (Int32, UInt64) -> Int32).self)(a.cid, space) == 1
    }

    /// The desktop (or full-screen Space) on show on the screen.
    static func current(_ screen: NSScreen) -> UInt64? {
        ((display(screen)?["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
    }

    static func put(_ window: NSWindow, on space: UInt64) {
        guard let a = api else { return }
        a.move(a.cid, [window.windowNumber] as CFArray, space)
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
    private static let size = CGSize(width: 320, height: 240)

    init() {
        // Waking from sleep scans ~0.5 s after the display comes on, before macOS has settled the screens (the external
        // display reattaching, the notch's safe area reported again): the island placed then sat off the notch. It
        // follows the screens as they settle.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.follow()
        }
    }

    private static func frame(on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Moves the shown island back onto the notch (and to its current size) when the screens change under it.
    func follow() {
        guard let p = panel, let host = p.contentView as? NSHostingView<IslandView>, let screen = notchScreen() else { return }
        let notch = notchSize(of: screen), frame = Island.frame(on: screen)
        if host.rootView.notch != notch { host.rootView = IslandView(model: model, notch: notch) }
        if p.frame != frame { p.setFrame(frame, display: true) }
    }

    func show(_ message: String, phase: IslandPhase = .scanning, overLockScreen: Bool = false) {
        generation += 1
        panel?.orderOut(nil)
        guard let screen = notchScreen() else { return }
        let notch = notchSize(of: screen)
        let size = Island.size, frame = Island.frame(on: screen)
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
    @Published var nowPlaying: NowPlaying? {
        didSet {
            if nowPlaying?.playing == true || nowPlaying == nil { paused = false; pauseToken = nil }
            else if oldValue?.playing == true {
                paused = true
                let t = UUID()
                pauseToken = t
                DispatchQueue.main.asyncAfter(deadline: .now() + NotchModel.pauseLinger) { [weak self] in
                    if self?.pauseToken == t { self?.paused = false }
                }
            }
        }
    }
    /// A song just paused stays in the notch this long, to be played again from its bars, as the Dynamic Island keeps it.
    static let pauseLinger: TimeInterval = 60 // ponytail: fixed; a Settings slider if a minute is wrong for someone.
    @Published private(set) var paused = false
    private var pauseToken: UUID?
    /// The volume or brightness key just pressed, shown in the collapsed notch in place of the system's HUD.
    @Published var hud: NotchHUD?
    /// Set for a few seconds after the power adapter goes in: the collapsed notch shows the charge.
    @Published var charge: Battery?
    /// Set for a few seconds after AirPods connect: the collapsed notch spins their picture in and shows their battery.
    @Published var accessory: AirPods.Shown?
    /// The cursor is on the notch: it swells a little, so the dwell before opening is felt.
    @Published var hover = false
    /// The cursor is on the music bars: they show pause (or play), and a click there toggles the song.
    @Published var barsHover = false
    /// The screen is locked: the song stays private, the notch shows no player.
    @Published var locked = false
    /// The app in front is in full screen on the notch's screen.
    @Published var fullScreen = false
    /// The live activity is not hidden away (Settings › 노치 › 자동으로 가리기 및 보기), or the cursor brought it back.
    @Published var liveUp = true
    /// The live activity may show: on in Settings, and not hidden away.
    var liveShown: Bool { Store.liveActivity && liveUp }
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
        /// `left` is the display's left edge: asked high there, all of the window is on it (one reaching into a
        /// taller display beside it would go up that display's way).
        init?(_ w: AXUIElement, screen: CGFloat, left: CGFloat) {
            let c = RealControlCenter.content(of: w), f = RealControlCenter.frame(w)
            guard !c.isNull else { return nil }
            (window, self.screen, width) = (w, screen, f.width)
            offset = c.minY - f.minY - (f.height - screen) / 2
            aside = c.midX - f.minX
            RealControlCenter.move(w, to: CGPoint(x: left, y: -screen)) // Asked far too high: where it stops is the limit.
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
            guard slack >= 0.5 else { return nil } // macOS 27.2 stops the window higher: 1pt is all there is now, at 1512 and at 1800 wide alike.
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
            measured = RealSiri.Panel(window, screen: place.height, left: place.mid - place.width / 2)
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

    /// `e` itself or, inside a menu extra's own window or group, the element with this id. On the item's right edge
    /// the hit is the group around it, not the item, and the walk then stepped past the item: Control Center was not
    /// found, and the notch opened nothing, for as long as the clock's width put a step exactly on that edge.
    private static func holder(of id: String, in e: AXUIElement, depth: Int = 2) -> AXUIElement? {
        if attr(e, kAXIdentifierAttribute) as? String == id { return e }
        guard depth > 0, frame(e).width < 100 else { return nil } // Not the app's whole menu bar, which is hit between items.
        for c in attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = holder(of: id, in: c, depth: depth - 1) { return found }
        }
        return nil
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
                if let found = holder(of: id, in: el) { return found }
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
    /// The bent band's depth in points, when not `refraction`'s own 40 pt scale.
    var rimDepth: Double?
    /// The glass body the rim follows: top-centered in the view, square top, bottom corners of `radius`.
    var body = CGSize.zero
    var radius: CGFloat = 0
    /// False: all four corners round and rimmed (the Duo buttons' capsule), not only the bottom ones (the island).
    var squareTop = true
    /// Seconds before a refraction change starts, so it settles in after the shape has stopped moving.
    var delay = 0.0
    /// The glass face's tone, in place of the clear style's (white 0.8, black 0.05, a 5% white fill).
    var face: Face?

    /// The face's colour matrix: how far the backdrop's whites and blacks are pulled, and a fill laid over it (sRGB).
    struct Face: Equatable {
        var white: Double, black: Double
        var fill: [CGFloat] // r g b a
        /// Applied to the backdrop before the glass, as a CoreMaterial recipe does: a luminance curve (4 values, mixed
        /// in by `curveAmount`) and a brightness shift.
        var curve: [CGFloat] = [], curveAmount: CGFloat = 0, brightness: CGFloat = 0
        /// The face's brightest luma (1: uncapped; bright backdrops ease down toward it), and the lit hairline round the rim.
        var maxLuma = 1.0, highlight = 0.0
    }

    final class View: NSView {
        var config: Backdrop? { didSet { apply() } }
        private var face: Face?
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
            let over = c.squareTop ? c.radius * 2 + 40 : 0
            let top = isFlipped ? -over : bounds.height - c.body.height
            el.frame = CGRect(x: bounds.midX - c.body.width / 2, y: top, width: c.body.width, height: c.body.height + over)
            el.cornerRadius = c.radius
            CATransaction.commit()

            // Apple's glass is amount -60 over a 20 pt rim; the slider's 50% lands exactly there.
            let targets: [(String, Double, Double)] = [
                ("inputBlurRadius", c.blur, 0), ("inputFaceColorMatrixSaturation", c.saturation, 0),
                ("inputInnerRefractionAmount", -120 * c.refraction, c.delay), ("inputInnerRefractionHeight", c.rimDepth ?? 40 * c.refraction, c.delay),
            ]
            let faceChanged = c.face != face
            face = c.face
            if shown.isEmpty {
                targets.forEach { values[$0.0] = $0.1 }
                shown = values
                render()
                return
            }
            let changed = targets.filter { values[$0.0] != $0.1 }
            guard !changed.isEmpty else { return faceChanged ? render() : () }
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
            var v = Self.glass.merging(shown) { $1 }
            if let f = face {
                v["inputFaceColorMatrixWhite"] = f.white
                v["inputFaceColorMatrixBlack"] = f.black
                v["inputFaceColorMatrixFillColor"] = CGColor(srgbRed: f.fill[0], green: f.fill[1], blue: f.fill[2], alpha: f.fill[3])
                v["inputFaceColorMatrixMaxLuma"] = f.maxLuma
                v["inputFaceColorMatrixMaxLumaSDR"] = f.maxLuma
                v["inputKeyFillHighlightAmount"] = f.highlight
            }
            var tone: [NSObject?] = []
            if let f = face, f.curve.count == 4 { tone.append(Self.filter("luminanceCurveMap", ["inputValues": f.curve, "inputAmount": f.curveAmount])) }
            if let f = face, f.brightness != 0 { tone.append(Self.filter("colorBrightness", ["inputAmount": f.brightness])) }
            layer?.filters = (tone + [Self.filter("glassBackground", v)]).compactMap { $0 }
            CATransaction.commit()
        }

        /// Every filter value below but the four in `shown`, read off a live NSGlassEffectView.
        private static let glass: [String: Any] = [
                    "name": "glass", "inputSourceSublayerName": "@0",
                    "inputOuterRefractionAmount": 0, "inputOuterRefractionHeight": 0,
                    "inputRefractionDistance0": -1, "inputRefractionDistance1": 0, "inputRefractionOpacity": 0,
                    // The rim's lit hairline, as macOS 27's glass has it; off (amount 0) unless the face asks.
                    "inputKeyFillHighlightHeight": 0.5, "inputKeyFillHighlightAngle": Double.pi / 2, "inputKeyFillHighlightAmount": 0,
                    "inputKeyFillHighlightSpread": 1.308996938995747, "inputKeyFillHighlightSpreadSDR": 1.308996938995747,
                    "inputKeyFillHighlightEffectOffset": -0.5, "inputKeyFillHighlightColorBias": -0.25,
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
                            .fill(model.ring[i] ? Brand.orange : Color.white.opacity(0.22))
                            .frame(width: 3, height: model.ring[i] ? 20 : 12)
                            .offset(y: -150)
                            .rotationEffect(.degrees(Double(i) * 6))
                            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: model.ring[i])
                    }
                case .done, .between:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 120, weight: .light))
                        .foregroundStyle(Brand.orange)
                        .transition(.scale.combined(with: .opacity))
                case .failed:
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 120, weight: .light))
                        .foregroundStyle(.red)
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
                        .foregroundStyle(Brand.ink)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Brand.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
    w.contentView = NSHostingView(rootView: view.tint(Brand.orange))
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
                .foregroundStyle(.primary)
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
                    .foregroundStyle(Brand.ink)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Brand.orange, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    w.contentView = NSHostingView(rootView: view.tint(Brand.orange))
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
    /// Apple's earbuds and headphones, renamed or not: Apple's Bluetooth vendor ID on an audio-class device.
    static func isApple(_ d: IOBluetoothDevice) -> Bool {
        d.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) && int(d, "vendorID") == 0x4C
    }

    static func connected() -> IOBluetoothDevice? {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first { $0.isConnected() && isApple($0) }
    }

    /// IOBluetooth's private getters, read only where the device answers them (KVC on a missing key throws).
    private static func int(_ d: IOBluetoothDevice, _ k: String) -> Int {
        d.responds(to: Selector(k)) ? (d.value(forKey: k) as? Int ?? 0) : 0
    }

    /// What the notch shows when they connect.
    struct Shown {
        var id = UUID(); let address: String, max: Bool; var level: Int?
        /// Apple's AR model to turn in the notch: AirPods Max, AirPods Pro, else the plain AirPods (4).
        var model: String { max ? "airpods-max-midnight" : pro ? "airpods-pro" : "airpods-mid" }
        var pro = false
    }

    /// AirPods Max (product IDs 0x200A, 0x201F, 0x2025) are drawn as headphones, the rest as buds.
    static func isMax(productID: Int) -> Bool { [8202, 8223, 8237].contains(productID) }

    /// AirPods Pro, 2 (Lightning and USB-C) and 3: product IDs 0x200E, 0x2014, 0x2024, 0x2027.
    /// ponytail: a new Pro shows as plain AirPods until its ID is added here.
    static func isPro(productID: Int) -> Bool { [8206, 8212, 8228, 8231].contains(productID) }

    static func shown(_ d: IOBluetoothDevice) -> Shown {
        let id = int(d, "productID")
        return Shown(address: d.addressString ?? "", max: isMax(productID: id), level: level(of: d), pro: isPro(productID: id))
    }

    /// The lower bud, as iOS warns on the weaker one; 0 means not reported. Nil when nothing is known yet.
    static func level(left: Int, right: Int, combined: Int) -> Int? {
        let buds = [left, right].filter { $0 > 0 }
        return buds.min() ?? (combined > 0 ? combined : nil)
    }

    static func level(of d: IOBluetoothDevice) -> Int? {
        level(left: int(d, "batteryPercentLeft"), right: int(d, "batteryPercentRight"),
              combined: max(int(d, "batteryPercentCombined"), int(d, "batteryPercentSingle")))
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
    case general, appearance, notch, controlCenter, desk, face, appLock, labs
    var id: String { rawValue }

    /// Sidebar sections: the notch first, face unlock as one of its features.
    static let groups: [(title: String, pages: [SettingsPage])] = [
        ("일반", [.general, .appearance, .notch, .controlCenter, .desk]), ("얼굴 잠금", [.face, .appLock]), ("실험", [.labs]),
    ]

    var title: String {
        switch self {
        case .general: return "일반"
        case .appearance: return "화면 모드"
        case .desk: return "데스크 브라우저"
        case .notch: return "노치"
        case .controlCenter: return "제어 센터"
        case .face: return "Face Unlock"
        case .appLock: return "앱 잠금"
        case .labs: return "실험실"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "circle.lefthalf.filled"
        case .desk: return "safari.fill"
        case .notch: return SettingsIcon.notch
        case .controlCenter: return "switch.2"
        case .face: return "faceid"
        case .appLock: return "lock.app.dashed"
        case .labs: return "flask.fill"
        }
    }

}

struct LockedApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
}

final class SettingsModel: ObservableObject {
    /// Every page change goes on the back stack, like System Settings' ‹ › buttons.
    @Published var page: SettingsPage? = .general {
        didSet { if let o = oldValue, o != page, !stepping { back.append(o); forward = [] } }
    }
    @Published var back: [SettingsPage] = []
    @Published var forward: [SettingsPage] = []
    private var stepping = false
    @Published var hasPassword = false
    @Published var consent: ConsentRecord?
    @Published var loginItem = false
    @Published var faceCount = 0
    @Published var lockedApps: [LockedApp] = []
    @Published var airpodsConnected = false

    func step(forward fwd: Bool) {
        guard let cur = page, let to = fwd ? forward.popLast() : back.popLast() else { return }
        if fwd { back.append(cur) } else { forward.append(cur) }
        stepping = true
        page = to
        stepping = false
    }
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

/// Keeps the settings' ordinary buttons neutral under the window's orange tint, which would otherwise colour every label.
struct NeutralButton: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Button(configuration).tint(nil) }
}

struct SettingsIcon: View {
    let symbol: String
    /// Not an SF Symbol (there is none for it): the MacBook's notch, drawn here.
    static let notch = "andeville.notch"

    /// One neutral tile for every page: orange is kept for the one thing on screen that answers, not a column of icons.
    var body: some View {
        Group {
            if symbol == Self.notch {
                // A MacBook's screen with its notch: the screen's outline, and hanging from its top edge the notch in
                // the notch's own shape (`IslandShape`: fillets where it meets the edge, rounded lower corners).
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(lineWidth: 1.4).frame(width: 17, height: 12.5)
                    IslandShape(width: 6.5, height: 3.6, radius: 1.5, ear: 0.9).frame(width: 17, height: 3.6).offset(y: 1.2)
                }
            } else {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
            }
        }
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Color(red: 0x3E / 255.0, green: 0x3E / 255.0, blue: 0x3B / 255.0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let actions: SettingsActions
    @State private var query = ""

    /// Bartender's sidebar: the first group bare, the ones below under a small header; a search narrows it to one flat list.
    private var groups: [(title: String, pages: [SettingsPage])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return SettingsPage.groups.enumerated().map { ($0.offset == 0 ? "" : $0.element.title, $0.element.pages) } }
        let hits = SettingsPage.allCases.filter { $0.title.localizedCaseInsensitiveContains(q) }
        return hits.isEmpty ? [] : [("", hits)]
    }

    var body: some View {
        NavigationSplitView {
            // ponytail: buttons, not List selection, for Bartender's gray pill (the sidebar highlight is always the accent
            // color); arrow keys no longer walk the pages.
            List {
                ForEach(groups, id: \.pages) { group in
                    Section {
                        ForEach(group.pages) { page in
                            Button { model.page = page } label: {
                                Label {
                                    Text(page.title).font(.system(size: 13, weight: .semibold))
                                } icon: {
                                    SettingsIcon(symbol: page.symbol)
                                }
                                .padding(.vertical, 4).padding(.horizontal, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.page == page ? Color.primary.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                        }
                    } header: {
                        if !group.title.isEmpty { Text(group.title) }
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "검색")
            .frame(minWidth: 190) // Room for "Face Unlock", the longest title, in full: the column's own width setting alone left it at 142pt.
            .navigationSplitViewColumnWidth(min: 190, ideal: 190, max: 190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let page = model.page ?? .general
            Group {
                switch page {
                case .general: GeneralPage(model: model, actions: actions)
                case .notch: NotchPage()
                case .controlCenter: ControlCenterPage()
                case .face: facePage
                case .appLock: AppLockPage(model: model, actions: actions)
                case .appearance: AppearancePage()
                case .desk: DeskBrowserPage()
                case .labs: LabsPage(model: model)
                }
            }
            .formStyle(.grouped)
            .buttonStyle(NeutralButton())
            .navigationTitle(page.title)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { model.step(forward: false) } label: { Image(systemName: "chevron.left") }
                        .disabled(model.back.isEmpty).help("뒤로")
                    Button { model.step(forward: true) } label: { Image(systemName: "chevron.right") }
                        .disabled(model.forward.isEmpty).help("앞으로")
                }
            }
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
            SensitivityPage() // Recognition settings, on the same Face ID page.
        }
    }
}

/// Where the live activity hides itself, as macOS offers for the menu bar.
enum LiveHide: String, CaseIterable {
    case always, desktop, fullScreen, never
    var title: String {
        switch self {
        case .always: return "항상"
        case .desktop: return "데스크탑에서만"
        case .fullScreen: return "전체 화면에서만"
        case .never: return "안 함"
        }
    }
}

/// A seconds slider, for the notch's and Control Center's timings.
func timeSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double> = 0.15...1.2, step: Double = 0.05) -> some View {
    LabeledContent(title) {
        HStack {
            Slider(value: value, in: range, step: step).frame(width: 190).labelsHidden()
            Text(String(format: "%.2f초", value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
        }
    }
}

/// Settings › 노치: the live activity beside the notch, and the notch's own look.
struct NotchPage: View {
    @AppStorage("liveActivity") private var liveActivity = true
    @AppStorage("liveHide") private var liveHide = LiveHide.never.rawValue
    @AppStorage("notchGestures") private var notchGestures = true
    @AppStorage("notchHUD") private var notchHUD = true
    @AppStorage("fullScreenHide") private var fullScreenHide = false
    @AppStorage("haptics") private var haptics = true
    @AppStorage("hoverSpeed") private var hoverSpeed = Store.hoverSpeedDefault
    @AppStorage("notchEar") private var notchEar = Store.notchEarDefault

    var body: some View {
        Form {
            Section {
                Toggle("라이브 활동 (재생 중인 곡 · 충전을 노치 옆에 표시)", isOn: $liveActivity)
                Picker("자동으로 가리기 및 보기", selection: $liveHide) {
                    ForEach(LiveHide.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .tint(nil) // A menu's value stays neutral, like the buttons.
                .disabled(!liveActivity)
                Toggle("전체 화면에서 메뉴 막대와 노치 숨기기", isOn: $fullScreenHide)
                Toggle("노치에서 두 손가락 스와이프로 이전 · 다음 곡", isOn: $notchGestures)
                Toggle("음량 · 밝기 키를 노치에 표시 (시스템 HUD 대신)", isOn: $notchHUD)
                Toggle("트랙패드 햅틱", isOn: $haptics)
            } header: {
                Text("라이브 활동")
            } footer: {
                Text("자동으로 가리면 그곳에서는 노치 옆 표시가 숨고 음악 막대를 위한 소리 읽기도 멈춥니다. 커서를 화면 맨 위로 올리면 다시 나타납니다. 음량 · 밝기 표시는 가리지 않습니다. '전체 화면에서 메뉴 막대와 노치 숨기기'를 켜면 전체 화면 앱에서는 커서를 맨 위로 올려도 메뉴 막대가 내려오지 않고, 노치도 라이브 활동 · 제어 센터 · Siri에 반응하지 않습니다. ⌘를 누른 채 올리면 메뉴 막대가 내려옵니다.")
            }
            Section {
                timeSlider("호버 반응 속도", value: $hoverSpeed, range: 0.1...1.2)
                LabeledContent("모서리 라운드") {
                    HStack {
                        Slider(value: $notchEar, in: Store.notchEarRange, step: 1).frame(width: 190).labelsHidden()
                        Text("\(Int(notchEar))pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    }
                }
            } header: {
                Text("모양")
            } footer: {
                Text("호버 반응 속도는 커서를 올렸을 때 노치가 살짝 커지는 데 걸리는 시간입니다. 모서리 라운드는 노치의 둥근 모서리 크기로, 화면 상단과 만나는 곳과 접힌 노치 아래쪽 모서리가 같은 값으로 둥글어집니다. 데스크톱과 잠금화면에서 항상 표시되며, 노치와 Face Unlock 표시에 같이 적용됩니다. 기본값이자 최소값은 7pt입니다.")
            }
        }
    }
}

/// Settings › 제어 센터: how the notch opens macOS's Control Center, and how it moves.
struct ControlCenterPage: View {
    @AppStorage("hubRealCC") private var realCC = true
    @AppStorage("hubLeave") private var hubLeave = Store.hubTimingDefault.leave

    var body: some View {
        Form {
            Section {
                Toggle("노치에서 macOS 제어 센터 열기", isOn: $realCC)
            } footer: {
                Text("켜면 노치를 클릭할 때 macOS의 실제 제어 센터가 노치 바로 아래에 열립니다(커서를 올리기만 해서는 열리지 않습니다). 노치를 꾹 누른 채 아래로 끌면 Siri가 따라 나옵니다. 모듈 추가·배치는 제어 센터 아래의 '컨트롤 편집'에서 macOS 그대로 합니다. 끄면 노치에서 아무것도 열리지 않습니다. 전체 화면 앱에서는 메뉴 막대가 내려온 뒤에 제어 센터가 열립니다. Andeville 설정은 노치를 오른쪽 클릭해 엽니다.")
            }
            Section {
                timeSlider("닫힘 감지 속도", value: $hubLeave, range: 0...0.6, step: 0.01)
                LabeledContent("기본값으로 되돌리기") {
                    Button("되돌리기") { hubLeave = Store.hubTimingDefault.leave }
                }
            } header: {
                Text("움직임")
            } footer: {
                Text("닫힘 감지 속도는 커서가 제어 센터 밖으로 나간 뒤 닫히기까지의 시간이고, 0초면 바로 닫힙니다. 제어 센터가 펼치고 접히는 움직임은 macOS가 정합니다.")
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
    @ObservedObject private var account = Account.shared
    @AppStorage(Account.autoKey) private var autoUpdate = true

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
                Toggle("잠금화면 해제", isOn: Binding(get: { model.hasPassword }, set: { _ in actions.togglePassword() }))
                LabeledContent("키체인 동의") {
                    HStack(spacing: 10) {
                        Text(consentStatus).font(.callout).foregroundStyle(Terms.isSigned(by: model.consent) ? Color.secondary : Color.red)
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
                LabeledContent("계정") {
                    HStack(spacing: 10) {
                        Text(account.email ?? "로그인 안 함").font(.callout).foregroundStyle(.secondary)
                        if account.email == nil { Button("로그인…", action: account.signIn) } else { Button("로그아웃", action: account.signOut) }
                    }
                }
                LabeledContent("앱 업데이트") {
                    HStack(spacing: 10) {
                        if !account.status.isEmpty {
                            Text(account.status).font(.callout).foregroundStyle(.secondary)
                        }
                        if Self.newerBuildOnDisk {
                            Button("업데이트", action: Self.relaunch)
                        } else if let v = account.latest {
                            Button("\(v)로 업데이트", action: account.update).disabled(account.busy)
                        } else {
                            Button("업데이트 확인") { account.check(install: false) }.disabled(account.busy || account.email == nil)
                        }
                    }
                }
                Toggle("새 버전 자동 설치", isOn: $autoUpdate).disabled(account.email == nil)
            } header: {
                Text("정보")
            } footer: {
                Text("Andeville을 구입한 계정으로 로그인하면 새 버전을 여기서 내려받아 설치하고 다시 실행합니다. 로그인은 브라우저의 andeville.app 계정 페이지에서 하며, 끝나면 이 앱으로 돌아옵니다. 자동 설치를 켜 두면 몇 시간마다 새 버전을 확인해 스스로 설치합니다(다시 실행은 잠금화면을 해제한 뒤). 받은 앱은 지금 앱과 같은 서명일 때만 설치합니다.")
            }
        }
        .onAppear { account.check(install: false) }
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

}

/// The Andeville account (andeville.app), which the app's updates come through. Signed in on the site's account page in
/// the browser, with whichever sign-in the site offers; the page hands a one-time code back over andeville://signin,
/// good only with the verifier this process kept (PKCE). The session it buys reads the account and downloads, no more.
final class Account: ObservableObject {
    static let shared = Account()
    static let autoKey = "autoUpdate"
    private static let tokenKey = "accountToken", emailKey = "accountEmail"
    /// ponytail: `defaults write com.ggear.faytai accountBaseURL https://andeville.gearservice.workers.dev` for the test site.
    private static var base: String { UserDefaults.standard.string(forKey: "accountBaseURL") ?? "https://andeville.app" }
    private static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    @Published private(set) var email = UserDefaults.standard.string(forKey: emailKey) // nil: signed out
    @Published private(set) var status = ""
    @Published private(set) var latest: String? // A newer version this account may download.
    @Published private(set) var busy = false
    private var verifier: String?
    /// ponytail: kept in the app's defaults, not the keychain, whose items macOS asks the password for after each
    /// update. It can only read the account and download the DMG; move it to the keychain if it ever does more.
    private var token: String? {
        get { UserDefaults.standard.string(forKey: Self.tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.tokenKey) }
    }

    /// Checks now and every six hours, installing what it finds when 새 버전 자동 설치 is on.
    func start() {
        let tick = { [weak self] in self?.check(install: UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true) }
        tick()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in tick() }
    }

    func signIn() {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return }
        let v = Self.base64url(Data(bytes))
        verifier = v
        status = "브라우저에서 로그인을 마쳐 주세요"
        NSWorkspace.shared.open(URL(string: "\(Self.base)/account.html?app=\(Self.challenge(v))")!)
    }

    /// andeville://signin?code=…, from the account page. A code this process did not ask for has no verifier to go with.
    func finish(_ url: URL) {
        guard let v = verifier, let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else { return }
        verifier = nil
        call("/api/app/token", post: ["code": code, "verifier": v]) { [weak self] code, json in
            guard let self else { return }
            guard code == 200, let t = json["token"] as? String else { self.status = "로그인하지 못했습니다"; return }
            self.token = t
            self.check(install: false)
        }
    }

    func signOut() {
        call("/api/auth/signout", post: [:]) { _, _ in }
        forget()
        status = ""
    }

    private func forget() {
        token = nil
        email = nil
        latest = nil
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
    }

    func check(install: Bool) {
        guard token != nil, !busy else { return }
        busy = true
        call("/api/me") { [weak self] code, json in
            guard let self else { return }
            self.busy = false
            if code == 401 { self.forget(); self.status = "다시 로그인해 주세요"; return }
            guard code == 200, let user = json["user"] as? [String: Any], let dl = json["download"] as? [String: Any] else {
                self.status = "확인할 수 없습니다"
                return
            }
            self.email = user["email"] as? String
            UserDefaults.standard.set(self.email, forKey: Self.emailKey)
            let v = dl["version"] as? String ?? ""
            guard dl["available"] as? Bool == true else { self.latest = nil; self.status = "이 계정에 라이선스가 없습니다"; return }
            guard Self.newer(v, than: Self.current) else { self.latest = nil; self.status = "최신 버전입니다"; return }
            self.latest = v
            self.status = "새 버전 \(v)"
            if install { self.update() }
        }
    }

    /// Downloads the DMG with the account's session, swaps the app in and relaunches into it.
    func update() {
        guard let token, !busy else { return }
        busy = true
        status = "내려받는 중…"
        var req = URLRequest(url: URL(string: Self.base + "/api/download")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.downloadTask(with: req) { file, resp, _ in
            let failed = (resp as? HTTPURLResponse)?.statusCode == 200 ? file.map(Self.install) ?? "내려받지 못했습니다" : "내려받지 못했습니다"
            DispatchQueue.main.async {
                self.busy = false
                if let failed { self.status = failed; return }
                self.latest = nil
                self.status = "다시 실행합니다"
                // Not while the screen is locked, where face unlock is at work.
                Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
                    guard !screenLocked() else { return }
                    t.invalidate()
                    GeneralPage.relaunch()
                }
            }
        }.resume()
    }

    /// Mounts the DMG, checks the app in it and puts it where this one is. Why it could not, or nil when it is in place.
    private static func install(_ file: URL) -> String? {
        let fm = FileManager.default, id = UUID().uuidString
        let dmg = fm.temporaryDirectory.appendingPathComponent("andeville-\(id).dmg"), mount = fm.temporaryDirectory.appendingPathComponent("andeville-\(id)")
        guard (try? fm.moveItem(at: file, to: dmg)) != nil else { return "내려받지 못했습니다" }
        defer { try? fm.removeItem(at: dmg) }
        guard run("/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path) else { return "디스크 이미지를 열 수 없습니다" }
        defer { _ = run("/usr/bin/hdiutil", "detach", mount.path, "-force") }
        let app = mount.appendingPathComponent("Andeville.app")
        guard sameSigner(app) else { return "서명이 달라 설치하지 않았습니다" }
        // The version is read off the app itself, not the server's word: never the same build again, never an older one.
        guard let v = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, newer(v, than: current) else { return "최신 버전입니다" }
        // Swapped in by renames, as build.sh does: rewriting a running app's files gets it killed.
        let dest = Bundle.main.bundleURL, tmp = dest.deletingLastPathComponent().appendingPathComponent(".Andeville-update-\(id)")
        guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: false)) != nil else { return "앱이 있는 폴더에 쓸 수 없습니다" }
        defer { try? fm.removeItem(at: tmp) }
        let new = tmp.appendingPathComponent("Andeville.app"), old = tmp.appendingPathComponent("old.app")
        guard run("/usr/bin/ditto", app.path, new.path), sameSigner(new), (try? fm.moveItem(at: dest, to: old)) != nil else { return "설치하지 못했습니다" }
        guard (try? fm.moveItem(at: new, to: dest)) != nil else { try? fm.moveItem(at: old, to: dest); return "설치하지 못했습니다" }
        return nil
    }

    /// Whether the app there is validly signed and meets this app's own designated requirement: the same identifier,
    /// signed by the same certificate. A download that is anyone else's, or tampered with, is not installed.
    /// ponytail: a move to another certificate (Developer ID) fails this check; that release goes out as a DMG to install by hand.
    static func sameSigner(_ app: URL) -> Bool {
        var me: SecCode?, mine: SecStaticCode?, req: SecRequirement?, theirs: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &req) == errSecSuccess, let req,
              SecStaticCodeCreateWithPath(app as CFURL, [], &theirs) == errSecSuccess, let theirs else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(theirs, flags, req) == errSecSuccess
    }

    static func newer(_ a: String, than b: String) -> Bool { a.compare(b, options: .numeric) == .orderedDescending }

    private static func run(_ tool: String, _ args: String...) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func challenge(_ verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    /// JSON in and out with the account's session; `done` on the main queue with the status (0: no answer) and the body.
    private func call(_ path: String, post: [String: String]? = nil, done: @escaping (Int, [String: Any]) -> Void) {
        var req = URLRequest(url: URL(string: Self.base + path)!)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let post {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: post)
        }
        req.httpShouldHandleCookies = false
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            DispatchQueue.main.async { done((resp as? HTTPURLResponse)?.statusCode ?? 0, json) }
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
                    .listRowBackground(selected == app.id ? Brand.orange.opacity(0.35) : nil)
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
                .tint(nil)
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
        Group {
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

/// Settings › 데스크 브라우저: the desktop as a browser, on every desktop of every screen.
/// Settings › 데스크 브라우저 › 단축어: the words that open an address when typed alone in the address bar
/// (`DeskBrowser.shortcut`). A row counts once it has both a word and an address.
struct DeskShortcutRows: View {
    struct Row: Identifiable, Equatable { let id = UUID(); var word = "", to = "" }
    @State private var rows = DeskBrowser.shortcuts.sorted { $0.key < $1.key }.map { Row(word: $0.key, to: $0.value) }

    var body: some View {
        Group {
            ForEach($rows) { $r in
                HStack {
                    TextField("단축어", text: $r.word, prompt: Text("단축어")).labelsHidden().frame(width: 130)
                    TextField("주소", text: $r.to, prompt: Text("주소 또는 검색어")).labelsHidden()
                    Button { rows.removeAll { $0.id == r.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("단축어 지우기")
                }
            }
            Button("단축어 추가") { rows.append(Row()) }
        }
        .onChange(of: rows) { _, rows in
            let kept = rows.map { ($0.word.trimmingCharacters(in: .whitespaces).lowercased(), $0.to.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.0.isEmpty && !$0.1.isEmpty }
            UserDefaults.standard.set(Dictionary(kept, uniquingKeysWith: { $1 }), forKey: DeskBrowser.shortcutsKey)
        }
    }
}

struct DeskBrowserPage: View {
    @AppStorage(DeskBrowser.onKey) private var desk = false
    @AppStorage(DeskBrowser.duoKey) private var duo = false
    @AppStorage(DeskBrowser.urlKey) private var deskURL = ""
    @AppStorage(DeskBrowser.throughKey) private var through = false
    @AppStorage(ShowDesktopVeil.coverKey) private var veilCover = true
    @AppStorage(DeskMenuShade.strengthKey) private var menuShade = DeskMenuShade.strengthDefault
    @State private var importing = false
    @State private var denied = false
    @State private var imported: String?

    var body: some View {
        Form {
            Section {
                // The Duo screen mode is the browser in another layout: on with it, whatever this says.
                Toggle(isOn: Binding(get: { desk || duo }, set: { desk = $0 })) {
                    Text("데스크 브라우저")
                    Text(duo ? "화면 모드가 아이폰 듀오인 동안은 항상 켜져 있습니다" : desk ? "켜짐" : "꺼짐")
                }
                .disabled(duo)
                TextField("홈 주소", text: $deskURL, prompt: Text("비어 있음"))
            } footer: {
                Text("바탕화면 전체를 클릭하고 입력할 수 있는 브라우저로 바꿉니다. 다른 창들 뒤에 깔려 있고, 창을 치우면(데스크톱 보기) 바로 쓸 수 있습니다. 트랙패드를 네 손가락으로 쓸어내리면 데스크톱이 보이고, 그 상태에서 한 번 더 쓸어내리면 주소창이 나옵니다. 네 손가락으로 쓸어올리면 주소창이 들어가고, 한 번 더 쓸어올리면 창들이 다시 돌아옵니다. 바탕화면 아이콘은 가려집니다. 처음에는 홈 주소로 열리고(홈 주소가 비어 있으면 배경화면이 보이는 빈 페이지), 그 뒤로는 데스크톱마다 마지막에 열어 둔 탭이 다시 열립니다. 새 탭도 홈 주소로 열립니다. 집 버튼을 누르면 홈 주소로 갑니다. 주소창에는 주소나 검색어를 넣고(북마크가 먼저, 빈 탭에서는 북마크 목록), ⌘L 주소창 · ⌘R 새로고침 · ⌘[ ⌘] 뒤로/앞으로 · ⌘T ⌘W 탭 · ⌘⇧T 닫은 탭 다시 열기 · ⌘D 북마크 · ⌘F 찾기 · ⌘P 프린트를 쓸 수 있습니다. ⌘를 누른 채 링크를 클릭하면 뒤쪽 새 탭에서 열립니다.")
            }
            Section {
                Toggle(isOn: $through) {
                    Text("브라우저를 메뉴 막대까지 뚫기")
                    Text("페이지가 메뉴 막대 아래에서 시작하지 않고 화면 맨 위부터 그려집니다")
                }
                Toggle(isOn: $veilCover) {
                    Text("데스크탑 보기 전환 중 가장자리 덮기")
                    Text("창이 물러나고 돌아오는 0.3초 동안 화면 가장자리를 데스크 화면으로 덮어 macOS의 테두리가 비치지 않게 합니다. 그 사이 창이 가장자리에서 잘려 보입니다")
                }
                LabeledContent {
                    HStack {
                        Slider(value: $menuShade, in: 0...1).frame(width: 190).labelsHidden()
                        Text("\(Int((menuShade * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    }
                } label: {
                    Text("메뉴 막대 받침 진하기")
                    Text("메뉴 막대가 내려왔을 때, 글자와 비슷한 밝기의 페이지 위에서 글자 뒤에 까는 받침의 진하기입니다. 0%면 깔지 않습니다. 조절하는 동안 데스크에 미리 보입니다")
                }
            } header: {
                Text("화면")
            }
            .disabled(!desk && !duo)
            Section {
                DeskShortcutRows()
            } header: {
                Text("단축어")
            } footer: {
                Text("주소창에 단축어만 넣고 Return을 누르면 그 주소가 열립니다. home(또는 홈)은 따로 넣지 않아도 홈 주소로 갑니다. 대소문자는 가리지 않습니다.")
            }
            Section {
                LabeledContent {
                    if importing {
                        ProgressView().controlSize(.small)
                    } else {
                        Menu("가져오기") {
                            ForEach(BrowserImport.sources, id: \.self) { s in Button(s.name) { bring(s) } }
                        }
                        .fixedSize()
                        .tint(nil)
                    }
                } label: {
                    Text("다른 브라우저에서 가져오기")
                    Text(imported ?? "방문 기록, 북마크, 로그인 정보")
                }
                if denied {
                    Button("전체 디스크 접근 권한 열기") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
            } header: {
                Text("가져오기")
            }
        }
    }

    private func bring(_ s: BrowserImport.Source) {
        importing = true
        denied = false
        BrowserImport.start(s) { r in
            importing = false
            switch r {
            case .success(let o): imported = (["\(s.name): 방문 기록 \(o.pages)개 · 북마크 \(o.bookmarks)개 · 로그인 쿠키 \(o.cookies)개"] + o.notes).joined(separator: " · ")
            case .failure(is BrowserImport.Denied):
                denied = true
                imported = "\(s.name) 기록을 읽으려면 Andeville에 전체 디스크 접근 권한이 필요합니다"
            case .failure(let e): imported = "\(s.name): \(e.localizedDescription)"
            }
        }
    }
}

/// Settings › 화면 모드: how the screen is laid out. macOS's own, or the iPhone Duo style (the desk browser filling the
/// screen, its address in the notch, a rail of controls down the right), and that style's own looks.
struct AppearancePage: View {
    @AppStorage(DeskBrowser.duoKey) private var duo = false

    var body: some View {
        Form {
            Section {
                Picker(selection: $duo) {
                    Text("기본").tag(false)
                    Text("아이폰 듀오").tag(true)
                } label: {
                    Text("화면 모드")
                    Text(duo ? "데스크 브라우저가 함께 켜집니다" : "macOS 그대로")
                }
                .tint(nil)
            } footer: {
                Text("아이폰 듀오: 페이지가 화면 전체를 채우고, 주소는 노치 안에 표시됩니다(눌러서 입력). 오른쪽에는 와이파이, 세로 독, 뒤로·앞으로·새로고침·홈 버튼이 놓입니다. 시계·와이파이와 버튼은 모든 앱 위에 떠 있고, 버튼은 앞에 있는 앱을 움직입니다(그 앱 메뉴의 뒤로·앞으로·새로고침·홈, 없는 버튼은 흐려짐). 앞에 창이 없거나 데스크톱을 보는 중이면 데스크 브라우저를 움직입니다. 데스크톱을 보는 동안 노치에 커서를 올리거나 네 손가락으로 한 번 더 쓸어내리면 노치가 아래로 펼쳐져 탭과 주소가 나오고, 커서가 벗어나거나 다른 곳을 누르면 다시 노치로 접힙니다. macOS 메뉴 막대는 숨겨지며, ⌘를 누른 채 커서를 화면 맨 위로 올리면 내려옵니다.")
            }
            if duo {
                Section {
                    DuoPadLookSettings()
                } header: {
                    Text("우측 컨트롤러")
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
                .fill(on ? AnyShapeStyle(Brand.orange.gradient) : AnyShapeStyle(.thinMaterial))
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

func makeSettingsWindow(_ view: SettingsView) -> NSWindow {
    let w = NSWindow(contentViewController: NSHostingController(rootView: view.tint(Brand.orange)))
    w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
    w.title = "Andeville 설정"
    w.toolbarStyle = .unified
    w.isReleasedWhenClosed = false
    w.setContentSize(NSSize(width: 763, height: 620)) // 48 wider with the sidebar, the pages as wide as they were.
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
    assert(DeskBrowser.address("naver.com")?.absoluteString == "https://naver.com", "a bare domain must open as a site")
    assert(DeskBrowser.address("맥 배경화면")?.host == "www.google.com", "words must become a search")
    assert(DeskBrowser.address("http://a.b/c")?.absoluteString == "http://a.b/c", "a full URL must stay as typed")
    assert(DeskBrowser.address("  ") == nil, "blank input must not navigate")
    let homeURL = URL(string: "https://h.me")
    assert(DeskBrowser.shortcut(" Home ", in: [:], home: homeURL) == homeURL, "home typed alone opens the home address")
    assert(DeskBrowser.shortcut("home", in: [:], home: nil) == nil, "home with no home address is a search")
    assert(DeskBrowser.shortcut("GH", in: ["gh": "github.com"], home: homeURL)?.absoluteString == "https://github.com", "a set shortcut opens its address, whatever the case typed")
    assert(DeskBrowser.shortcut("home", in: ["home": "a.com"], home: homeURL)?.host == "a.com", "a set shortcut wins over the built-in home")
    assert(DeskBrowser.shortcut("home page", in: ["gh": "github.com"], home: homeURL) == nil, "only the word alone is a shortcut")
    assert(DuoRing.image != nil, "the Duo status bar's Wi-Fi SVG must load")
    assert(DuoPad.action(named: "뒤로") == .back && DuoPad.action(named: "Go Forward") == .forward, "an app's Back and Forward must be found by name")
    assert(DuoPad.action(named: "페이지 다시 로드") == .reload && DuoPad.action(named: "Reload This Page") == .reload, "a browser's reload must be found")
    assert(DuoPad.action(named: "홈") == .home && DuoPad.action(named: "Bring All to Front") == nil, "only the commands the buttons name")
    assert(DuoPad.action(shortcut: "[", mods: 0) == .back && DuoPad.action(shortcut: "]", mods: 0) == .forward
           && DuoPad.action(shortcut: "]", mods: 1) == nil && DuoPad.action(shortcut: "r", mods: 0) == nil, "back and forward by ⌘[ ⌘] in any language")
    assert(DeskBrowser.address("localhost:3000")?.absoluteString == "http://localhost:3000", "a local dev server must open, not search")
    let visited = [DeskHistory.Entry(url: "https://blog.naver.com/x", title: "블로그"), DeskHistory.Entry(url: "https://www.naver.com/", title: "NAVER")]
    assert(DeskHistory.rank(visited, "naver").first?.title == "NAVER", "an address starting with what was typed must come first")
    assert(DeskHistory.rank(visited, "블로그").count == 1, "a title must match too")
    assert(DeskHistory.rank(visited, " ").isEmpty, "nothing typed, no suggestions")

    let key = Data(repeating: 7, count: 16), host = Data(SHA256.hash(data: Data("example.com".utf8)))
    let v10 = Data("v10".utf8) + BrowserImport.aes(host + Data("sid=1".utf8), key: key, op: kCCEncrypt)!
    assert(BrowserImport.chromiumValue(plain: "", encrypted: v10, key: key, hashed: true) == "sid=1", "a v24 Chromium cookie must lose its host hash")
    assert(BrowserImport.chromiumValue(plain: "old", encrypted: Data(), key: key, hashed: true) == "old", "an unencrypted row keeps its value")
    // One Safari cookie: page header, record with offsets 56.. for domain/name/path/value, flags 5, far-off expiry.
    func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(v >> ($0 * 8) & 0xff) } }
    let strings = Array(".a.com\0n\0/\0v\0".utf8)
    var record = le32(56 + strings.count) + le32(0) + le32(5) + le32(0) + le32(56) + le32(63) + le32(65) + le32(67) + [UInt8](repeating: 0, count: 8)
    record += withUnsafeBytes(of: Double(4e9).bitPattern.littleEndian, Array.init) + [UInt8](repeating: 0, count: 8) + strings
    let pageBytes = [0, 0, 1, 0] + le32(1) + le32(16) + [0, 0, 0, 0] + record
    let jar = Array("cook".utf8) + [0, 0, 0, 1] + [UInt8](withUnsafeBytes(of: UInt32(pageBytes.count).bigEndian, Array.init)) + pageBytes
    let c = BrowserImport.safariCookies(Data(jar)).first
    assert(c?.domain == ".a.com" && c?.name == "n" && c?.value == "v" && c?.isSecure == true && c?.isHTTPOnly == true, "a Safari cookie must parse")
    let chrome: [String: Any] = ["roots": ["bookmark_bar": ["children": [["type": "url", "name": "A", "url": "https://a.com"],
                                                                        ["type": "folder", "children": [["type": "url", "name": "B", "url": "https://b.com"]]]]]]]
    assert(BrowserImport.chromiumBookmarks(chrome).map(\.title) == ["A", "B"], "Chromium bookmarks in folders must come out in order")
    let safari: [String: Any] = ["Children": [["URLString": "https://a.com", "URIDictionary": ["title": "A"]],
                                              ["Title": "com.apple.ReadingList", "Children": [["URLString": "https://r.com"]]]]]
    assert(BrowserImport.safariBookmarks(safari).map(\.url) == ["https://a.com"], "Safari bookmarks without the Reading List")
    for m in Buds3D.models where Bundle.main.url(forResource: m, withExtension: "usdz") != nil {
        assert(Buds3D.load(m) != nil, "\(m).usdz must load with its buds found")
    }
    assert(AirPods.level(left: 80, right: 40, combined: 0) == 40, "the weaker bud must be shown")
    assert(AirPods.level(left: 0, right: 60, combined: 90) == 60, "a bud in the case must not count as empty")
    assert(AirPods.level(left: 0, right: 0, combined: 0) == nil, "no reading must stay unknown")
    assert(AirPods.isMax(productID: 8237) && !AirPods.isMax(productID: 8231), "AirPods Max must be told from buds by product ID")
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
    let islandOpen = DuoNotchTabs.Spring(from: 0, to: 1, speed: 0, response: 0.42, damping: 0.78), mid = islandOpen.at(0.1)
    let turned = DuoNotchTabs.Spring(from: mid.place, to: 0, speed: mid.speed, response: 0.24, damping: 1)
    assert(islandOpen.at(0).place == 0 && abs(islandOpen.at(0.9).place - 1) < 0.01 && mid.speed > 0
           && abs(turned.at(0).place - mid.place) < 1e-9 && abs(turned.at(0).speed - mid.speed) < 1e-6 && abs(turned.at(0.45).place) < 0.01,
           "the island's spring starts at rest, arrives, and a turn midway takes over its place and speed")
    if let media = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      subtype: 8, data1: (2 << 16) | (0xA << 8), data2: -1)?.cgEvent {
        assert(App.sysSubtype(media) == 8 && App.sysData1(media) == (2 << 16) | (0xA << 8), "a media key's subtype and data must read off the CGEvent as NSEvent has them")
    }
    assert(ShowDesktopVeil.lift(0) == 0 && abs(ShowDesktopVeil.lift(1) - 1) < 1e-9 && abs((1 - 0.25 * 0.5) * (1 + ShowDesktopVeil.lift(0.5) / 3) - 1) < 1e-9
           && ShowDesktopVeil.riseDim.first == 0 && ShowDesktopVeil.riseDim.last == 1 && ShowDesktopVeil.fallDim.first == 1 && ShowDesktopVeil.fallDim.last == 0
           && ShowDesktopVeil.riseReach.first == 0 && ShowDesktopVeil.riseReach.last == 1 && ShowDesktopVeil.fallReach.first == 1 && ShowDesktopVeil.fallReach.last == 0
           && ShowDesktopVeil.riseDim.count == ShowDesktopVeil.riseReach.count && ShowDesktopVeil.fallDim.count == ShowDesktopVeil.fallReach.count,
           "the lift undoes the frame's dim at every point of its way in and out")
    assert(DuoTone.groundCheck(), "the band takes the colour most of the page's top has, not its text mixed in")
    assert(Account.newer("0.10", than: "0.9") && !Account.newer("0.3", than: "0.3") && !Account.newer("0.2", than: "0.3"), "update only to a newer version")
    assert(Account.sameSigner(Bundle.main.bundleURL), "this app must pass its own update check")
    assert(!Account.sameSigner(URL(fileURLWithPath: "/System/Applications/Calculator.app")), "another signer's app must not pass the update check")
    assert(Account.challenge(String(repeating: "v", count: 43)) == "7w_YNF9DSfIdPf_pRjSq646_kPr-2-o9NAl16JGghdM", "the sign-in challenge is the verifier's SHA-256, base64url")

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
    assert(Spectrum.loudestBand(ofTone: 80) == 0 && Spectrum.loudestBand(ofTone: 700) == 1 && Spectrum.loudestBand(ofTone: 9000) == 3, "a tone lands in its band: bass left, treble right")
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
    assert(SiriGrip.Fit(hidden: -65, notch: 38, minY: -14, offset: 74, screen: 1169) != nil, "macOS 27.2's window limit (1pt of room, measured) still fits")
    assert(SiriGrip.lift(reach: 0, dy: -10, down: 0, held: true, carrying: true, room: 64).reach == 10, "with the orb in hand the drag does go up")
    let lift = { (reach: CGFloat, dy: CGFloat, down: CGFloat, held: Bool) in SiriGrip.lift(reach: reach, dy: dy, down: down, held: held, room: 64) }
    assert(lift(0, -10, 0, false).reach == 10 && lift(0, -10, 5, false).reach == 0 && lift(60, -20, 0, false).reach == 64, "pushed against the top edge the cursor goes on up, as far as the orb's top and no further")
    assert(lift(30, 10, 10, true) == (20, 0) && lift(3, 5, 5, true) == (0, 2) && lift(3, 5, 10, true).put == 7, "with the orb in hand the cursor covers the way back down before it moves on screen, and loses none of the move")
    assert(lift(30, 5, 5, false) == (0, nil) && lift(30, 1, 2, false) == (29, nil) && lift(0, -10, 0, true).reach == 0, "without a button held the cursor is never put back, and a drag from elsewhere does not go up")
    assert(Spectrum.gain(volume: 1, muted: false) == 1 && Spectrum.gain(volume: 0.25, muted: false) == 0.5 && Spectrum.gain(volume: 0.8, muted: true) == 0, "the bars reach full height at full volume, half at a quarter, and lie flat when muted")
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
    static let hubTimingDefault = (open: 0.4, close: 0.45, leave: 0.1)
    /// Overshoot of the Face ID island's opening spring (fixed). Spring damping is 1 - this.
    static let hubBounceDefault = 0.26
    /// How long the notch takes to swell under the cursor; Settings › 일반 › 노치 › 호버 반응 속도.
    static let hoverSpeedDefault = 0.5
    static let hubBounce = hubBounceDefault
    /// How long the cursor may be off Control Center before it closes; 0 closes on exit.
    static var hubLeave: Double {
        UserDefaults.standard.object(forKey: "hubLeave") == nil ? hubTimingDefault.leave : max(UserDefaults.standard.double(forKey: "hubLeave"), 0)
    }
    /// The notch opens macOS's own Control Center under it (on unless turned off).
    static var hubRealCC: Bool { UserDefaults.standard.object(forKey: "hubRealCC") as? Bool ?? true }
    /// Andeville's island behind macOS's Control Center, with the blur in and out (on unless turned off).
    /// The collapsed notch's live activity, swipe gestures and trackpad ticks (all on unless turned off).
    static var liveActivity: Bool { UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true }
    /// Settings › 노치 › 자동으로 가리기 및 보기: the live activity hides here (back while the cursor is at the top).
    static func liveHides(fullScreen: Bool) -> Bool {
        switch LiveHide(rawValue: UserDefaults.standard.string(forKey: "liveHide") ?? "") ?? .never {
        case .always: return true
        case .desktop: return !fullScreen
        case .fullScreen: return fullScreen
        case .never: return false
        }
    }
    /// Settings › 노치 › 전체 화면에서 메뉴 막대와 노치 숨기기 (off unless turned on).
    static var fullScreenHide: Bool { UserDefaults.standard.bool(forKey: "fullScreenHide") }
    static var notchGestures: Bool { UserDefaults.standard.object(forKey: "notchGestures") as? Bool ?? true }
    static var notchHUD: Bool { UserDefaults.standard.object(forKey: "notchHUD") as? Bool ?? true }
    /// Keeps the display and the Mac awake while the screen is locked (off unless turned on).
    static var lockAwake: Bool { UserDefaults.standard.bool(forKey: "lockAwake") }
    static var haptics: Bool { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }
    static let hubOpen = hubTimingDefault.open, hubClose = hubTimingDefault.close


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

/// The app in front shows a full-screen window on this screen (macOS's own full screen, read through Accessibility:
/// on a notched Mac the window sits below the notch, so its size alone looks like a zoomed one). Nil while Andeville
/// itself is in front, which says nothing about the space under it.
/// `area` is the screen's, in Accessibility coordinates (top-left based). Any thread.
func fullScreenApp(in area: CGRect) -> Bool? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return false }
    guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
    var list: CFTypeRef?
    let e = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(e, 0.2) // A busy app in front answers late or never (seen: the default 6 s, over and over).
    guard AXUIElementCopyAttributeValue(e, kAXWindowsAttribute as CFString, &list) == .success,
          let windows = list as? [AXUIElement] else { return false }
    return windows.contains { w in
        AXUIElementSetMessagingTimeout(w, 0.2)
        var full: CFTypeRef?, pos: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &full) == .success, full as? Bool == true else { return false }
        var p = CGPoint.zero
        if AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success, let pos {
            AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        }
        return area.contains(CGPoint(x: p.x + 1, y: p.y + 1))
    }
}

func notchScreen() -> NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main }

/// The run loop the always-on event taps answer on. A tap holds every event of its kind on the Mac until it answers,
/// and the main thread is busy with its 60 Hz watches and Accessibility calls that may take 0.2 s each. Every click
/// brings an NX_SYSDEFINED event along, so the HUD tap held the mouse too (seen: typing and clicks stuck, lag).
let tapLoop: CFRunLoop = {
    var loop: CFRunLoop?
    let ready = DispatchSemaphore(value: 0)
    let t = Thread {
        loop = CFRunLoopGetCurrent()
        RunLoop.current.add(Port(), forMode: .default) // Keeps the loop running with no tap in it yet.
        ready.signal()
        RunLoop.current.run()
    }
    t.qualityOfService = .userInteractive
    t.start()
    ready.wait()
    return loop!
}()

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
    private var notchArea = CGRect.null // The notch, kept by the notch timer for the right tap off the main thread.
    private var rightOnNotch = false // A right press that began on the notch: its release is kept too.
    private lazy var notchBase = NotchBase(model: live)
    private var nowPlayingStream: Process?
    private var swipeMonitors: [Any?] = []
    private var plugged: Bool?
    fileprivate var hudTap: CFMachPort?
    private var hudGeneration = 0
    private var btConnect: IOBluetoothUserNotification?
    /// The Apple headphones connected at the last look; one newly in this set is what the notch announces.
    private var headphones: Set<String>?
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
    /// When the notch was last pressed: a scroll that comes with the press is the click's, not a swipe.
    private var notchPressed = Date.distantPast
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
            case "signin": Account.shared.finish(url)
            default: break
            }
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Buds3D.preload()
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
        wc.addObserver(self, selector: #selector(checkFullScreen), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        wc.addObserver(self, selector: #selector(checkFullScreen), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(checkFullScreen), name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(checkFullScreen), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        checkFullScreen()
        // Hidden away, the live activity comes back while the cursor is at the top, as the menu bar does: watched.
        liveWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.updateLiveUp() }
        live.locked = screenLocked() // Launched on the lock screen; the notifications keep it from here.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenDidLock), name: .init("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenDidUnlock), name: .init("com.apple.screenIsUnlocked"), object: nil)
        checkConsent()
        airpodsTick(AirPods.connected() != nil) // checkHeadphones' half-second look keeps it from here.
        // A newer build of this bundle on disk (build.sh swaps one into /Applications): taken up on its own, the
        // keychain handed over first, and not while the screen is locked, where face unlock is at work.
        // ponytail: a stat every 2 s; a file watcher on the bundle's folder if that ever shows up.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
            guard GeneralPage.newerBuildOnDisk, !screenLocked() else { return }
            t.invalidate()
            GeneralPage.relaunch()
        }
        DeskBrowser.shared.start()
        Account.shared.start()
    }

    /// Auto mode: AirPods worn (connected) use the AirPods check, taken off (disconnected) go back to ultrasound.
    private func airpodsTick(_ on: Bool) {
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
        var awaySince: Date?, realTicks = 0
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
            guard !self.live.locked, !self.busy, !self.island.isShowing, !(self.live.fullScreen && Store.fullScreenHide), let screen = notchScreen() else { // Kept by screenDidLock/Unlock: no WindowServer call 60×/s.
                armed = false
                grab = nil
                hold = nil
                if self.live.hover { self.live.hover = false }
                self.grip?.release(out: false)
                return
            }
            let p = NSEvent.mouseLocation, now = Date()
            self.notchArea = notchRect(in: screen.frame, notch: notchSize(of: screen))
            let overNotch = cursor(p, isOver: self.notchArea)
            DuoMenu.shared.track(p, onNotch: overNotch)
            let hover = (overNotch || self.real != .idle) && self.grip == nil && self.siri == nil // Stays swollen while Control Center is open.
            if self.live.hover != hover { self.live.hover = hover }
            let down = NSEvent.pressedMouseButtons & 1 != 0
            let pressed = down && !wasDown
            wasDown = down
            let notch = notchSize(of: screen)
            // The bars wing: hovered it shows pause or play, a click sends the play/pause key to whichever app plays.
            let bare = notchRect(in: screen.frame, notch: notch)
            let song = self.live.nowPlaying
            let onBars = song != nil && (song!.playing || self.live.paused || self.live.barsHover) && self.live.hud == nil && self.live.charge == nil && self.live.accessory == nil
                && !self.live.locked && self.real == .idle && self.grip == nil && self.siri == nil
                && self.live.liveShown
                && p.x > bare.maxX && cursor(p, isOver: bare.insetBy(dx: -NotchLive.wing - NotchLive.swell, dy: 0))
            if self.live.barsHover != onBars { self.live.barsHover = onBars }
            if pressed, onBars, let s = song {
                Controls.mediaKey(16) // NX_KEYTYPE_PLAY
                Controls.haptic()
                // Shown at once; the now-playing stream confirms a moment later.
                self.live.nowPlaying = NowPlaying(title: s.title, artist: s.artist, playing: !s.playing, artwork: s.artwork)
            }
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
            if pressed, overNotch { grab = (p.x, cursorY); self.notchPressed = now }
            var tapped = false
            // Let go, it is a click (Control Center). Held a quarter second and pulled down, the orb is in hand: in the
            // notch where the cursor is, at the height the cursor has it. A click that slips a few points on its way
            // is still a click, not Siri.
            if let g = grab, !down || (cursorY - g.y >= 3 && now.timeIntervalSince(self.notchPressed) >= 0.25) {
                grab = nil
                tapped = !down
                if !tapped {
                    // Control Center makes way, also one that is still opening (the first time after launch that
                    // takes seconds, and the orb is not kept waiting for it): it is closed when it has opened.
                    if self.real == .open { self.closeReal() } else if self.real == .opening { self.real = .idle; self.backdrop.hide(blur: false) }
                    armed = false
                    let room = max((notch.width - SiriGrip.orb) / 2, 0), mid = screen.frame.midX
                    let middle = down ? min(max(g.x, mid - room), mid + room) : mid
                    self.takeSiri(on: screen, at: CGPoint(x: middle, y: hidden))
                    hold = CGPoint(x: g.x - middle, y: g.y - hidden)
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
            if self.mustLeave { self.mustLeave = false; armed = false }
            if !overNotch { armed = true }
            // A held grab is not a hover. A click is meant, so it opens even before the cursor has left the notch:
            // Control Center closed by a click outside it (on the notch) leaves `armed` off, and the next click was lost.
            guard overNotch, armed || tapped, grab == nil else { return }
            // Only a click opens Control Center, on release (so a press held and pulled can still become Siri): the
            // cursor resting on the notch opens nothing. A menu bar item ⌘-dragged onto the notch opens it too, to
            // drop the item in.
            if tapped || menuDrag {
                awaySince = nil
                self.openNotch(on: screen)
            }
        }
        // Every mouse move, for the cursor's way up into the notch. Global for the other apps', local for Andeville's own.
        let lift: (NSEvent) -> Void = { [weak self] e in self?.keepOffMenuBar(); self?.liftCursor(by: e.deltaY) }
        liftMonitors = [NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: lift),
                        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { lift($0); return $0 }]
    }

    /// Full screen with 전체 화면에서 메뉴 막대와 노치 숨기기 on, or the Duo style (its menu bar hidden, `DuoMenuBarPin`):
    /// the cursor is kept off the top edge, so macOS's menu bar never slides down. ⌘ held lets it through.
    private func keepOffMenuBar() {
        let duo = DuoMenu.shared.on
        guard duo || (live.fullScreen && Store.fullScreenHide), !NSEvent.modifierFlags.contains(.command), let screen = notchScreen() else { return }
        let p = NSEvent.mouseLocation, f = screen.frame
        guard p.x >= f.minX, p.x < f.maxX, f.maxY - p.y < 1 else { return }
        if duo, !live.fullScreen, abs(p.x - f.midX) <= notchSize(of: screen).width / 2 { return } // The notch's own way up (liftCursor).
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? f.maxY) - f.maxY + 2))
        CGAssociateMouseAndMouseCursorPosition(1) // A warp otherwise holds mouse moves back for a quarter of a second.
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
            self.updateSpectrum()
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

        // The connect notification is instant but has proved unreliable on reconnects; the half-second look catches those.
        btConnect = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(bluetoothConnected(_:device:)))
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkHeadphones() }

        var sum: CGFloat = 0, sumUp: CGFloat = 0, fired = false, wingSum: CGFloat = 0, clicked = false
        let swipe: (NSEvent) -> Void = { [weak self] e in
            guard e.momentumPhase.isEmpty, let screen = notchScreen() else { return }
            let wheel = e.phase.isEmpty // A mouse wheel has no phase: each tick stands alone.
            if wheel || e.phase == .began { sum = 0; sumUp = 0; fired = false; wingSum = 0; clicked = false }
            let bare = notchRect(in: screen.frame, notch: notchSize(of: screen))
            let rect = bare.insetBy(dx: -NotchLive.wing, dy: 0)
            let p = NSEvent.mouseLocation, ax = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
            // On the player's wings, up and down set the level: the artwork side brightness, the bars side volume.
            if let self, self.real == .idle, !self.live.locked, self.live.nowPlaying?.playing == true,
               self.live.liveShown,
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
            // Two fingers moving up while the notch is hovered and Control Center is closed: Settings. Not on the lock screen.
            // Not with the button down or just pressed: a click on the notch with a second finger resting on the
            // trackpad reads as a short scroll too, and brought Settings out along with Siri.
            if NSEvent.pressedMouseButtons != 0 { clicked = true }
            if !wheel, !clicked, sumUp >= travel, let self, self.live.hover, self.real == .idle, !self.live.locked,
               Date().timeIntervalSince(self.notchPressed) > 0.6 {
                fired = true
                self.openSettings()
                return Controls.haptic()
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
        CFRunLoopAddSource(tapLoop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    }

    /// True when the key was Andeville's to handle. Anything it cannot move itself (an output without a volume, a
    /// display that is not ours to dim, the lock screen, ⌥ for the settings pane) goes on to macOS untouched.
    /// ponytail: no volume feedback pop; play /System/Library/Sounds via NSSound here if it is missed.
    /// On tapLoop, not the main thread; cheapest checks first, every mouse click comes through here too.
    static func sysSubtype(_ e: CGEvent) -> Int { CGEventField(rawValue: 99).map { Int(e.getIntegerValueField($0)) } ?? -1 }
    static func sysData1(_ e: CGEvent) -> Int { CGEventField(rawValue: 149).map { Int(e.getIntegerValueField($0)) } ?? 0 }

    private func hudKey(_ event: CGEvent) -> Bool {
        // Read off the CGEvent itself (fields 99 and 149 are NSEvent's subtype and data1; `selfCheck` holds them to it).
        // An NSEvent made here crashed the app: for a Caps Lock press (the 한/영 key) AppKit asks the input sources,
        // which must be on the main thread, and this is not it.
        guard Self.sysSubtype(event) == 8, Store.notchHUD, !screenLocked() else { return false }
        let data1 = Self.sysData1(event), key = (data1 & 0xFFFF0000) >> 16, down = (data1 & 0xFF00) >> 8 == 0xA
        let flags = event.flags, fine = flags.contains([.maskAlternate, .maskShift])
        guard [0, 1, 2, 3, 7].contains(key), !flags.contains(.maskAlternate) || fine else { return false }
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
        DispatchQueue.main.async { self.showHUD(hud) }
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

    @objc private func bluetoothConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) { checkHeadphones() }

    /// AirPods connected: they spin in on the left wing at once, their battery fills the ring on the right as the buds
    /// report it, and both stay until the buds have turned (`Buds3D.spin`). Those already connected when the app starts are not news.
    private func checkHeadphones() {
        let now = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.isConnected() && AirPods.isApple($0) }
        let addresses = Set(now.compactMap(\.addressString))
        defer { headphones = addresses; airpodsTick(!now.isEmpty) }
        if let shown = live.accessory, !addresses.contains(shown.address) { live.accessory = nil } // Gone again.
        if let shown = live.accessory, shown.level == nil, let d = now.first(where: { $0.addressString == shown.address }) {
            live.accessory?.level = AirPods.level(of: d)
        }
        guard let before = headphones, let d = now.first(where: { !before.contains($0.addressString ?? "") }) else { return }
        let shown = AirPods.shown(d)
        live.accessory = shown
        DispatchQueue.main.asyncAfter(deadline: .now() + Buds3D.spin + 0.4) { [weak self] in // Closes once they have turned.
            if self?.live.accessory?.id == shown.id { self?.live.accessory = nil }
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

    /// Right button on the notch, kept from the menu bar (no "Menu Bar Settings…", no menu at all), and nothing else.
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
        CFRunLoopAddSource(tapLoop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    }

    /// True when the right-button event is kept from the apps: a press on the notch (two fingers on the trackpad) and
    /// its release, so the menu bar shows no menu.
    fileprivate func rightEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .rightMouseDown:
            guard cursor(NSEvent.mouseLocation, isOver: notchArea) else { // On tapLoop: no NSScreen here.
                rightOnNotch = false
                return false
            }
            rightOnNotch = true // Kept from the menu bar and does nothing: a tap read as two fingers dropped settings in.
            return true
        case .rightMouseUp:
            defer { rightOnNotch = false }
            return rightOnNotch
        default: return false
        }
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
        let w = settingsReady()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
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
        let wings = live.liveShown && live.nowPlaying?.playing == true
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
            if self.island.isShowing { self.island.follow() } // The lock screen may settle its screens without telling.
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

    /// Full screen in or out (a space change, an app brought forward, the setting flipped): the live activity and
    /// the sound it reads follow. Checked again once the space's slide has settled and its windows are listed.
    @objc private func checkFullScreen() {
        // Asked off the main thread: the app in front answers Accessibility when it can, and the notch must not wait for it.
        let check = { [weak self] in
            guard let self, let screen = notchScreen() else { return }
            let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY, f = screen.frame
            let area = CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height) // Read here: NSScreen is the main thread's.
            self.fullCheck += 1
            let n = self.fullCheck
            DispatchQueue.global(qos: .userInitiated).async {
                let full = fullScreenApp(in: area)
                DispatchQueue.main.async {
                    guard n == self.fullCheck else { return } // A later check has been asked: its answer counts.
                    guard let full else { return self.updateSpectrum() }
                    if self.live.fullScreen != full { self.live.fullScreen = full }
                    self.updateLiveUp()
                    self.updateSpectrum()
                }
            }
        }
        check()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: check)
    }

    private var fullCheck = 0
    private var liveWatch: Timer?
    private var liveAwaySince: Date?

    /// Whether the live activity shows: unless hidden away here, or while the cursor is in the menu bar's strip at the top.
    private func updateLiveUp() {
        guard let screen = notchScreen() else { return }
        let strip = max(screen.safeAreaInsets.top, 24)
        let up = !(live.fullScreen && Store.fullScreenHide)
            && (!Store.liveHides(fullScreen: live.fullScreen) || screen.frame.maxY - NSEvent.mouseLocation.y <= strip)
        // The menu bar waits a moment after the cursor leaves before it slides up; the wings wait with it.
        // ponytail: 0.2 s by eye against macOS's bar; raise if the wings still fold first.
        if up { liveAwaySince = nil } else if live.liveUp {
            if liveAwaySince == nil { liveAwaySince = Date() }
            guard Date().timeIntervalSince(liveAwaySince!) >= 0.2 else { return }
        }
        guard live.liveUp != up else { return }
        live.liveUp = up
        // After the wings have moved: tearing the audio tap down (or setting it up) blocks the main thread a moment,
        // which held the fold back behind the menu bar's.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.updateSpectrum() }
    }

    /// Sound is read only while a song plays and its bars can show: not with the live activity off or hidden in full screen.
    private func updateSpectrum() {
        if live.nowPlaying?.playing == true && live.liveShown { live.spectrum.start() } else { live.spectrum.stop() }
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

// MARK: - Desktop browser experiment

/// Settings › 데스크 브라우저: the desktop itself becomes a live browser, one per screen,
/// just above Finder's icons (so clicks land here) and below every normal window. Each desktop (Space) has its own,
/// made the first time that desktop is shown, so its pages stay with it.
final class DeskBrowser {
    static let shared = DeskBrowser()
    static let onKey = "deskBrowserOn", urlKey = "deskBrowserURL", duoKey = "deskDuoOn"
    /// The page starts at the screen's top edge, under the menu bar, instead of below it.
    static let throughKey = "deskThroughMenuBar"
    private var frames: [CGDirectDisplayID: [DeskFrame]] = [:]
    private var shownOn = false, shownDuo = false, shownThrough = false
    private let veil = ShowDesktopVeil()

    /// The address set in Settings › 실험실, or nil when none is set (then pages start blank, as in Safari).
    static var home: URL? { address(UserDefaults.standard.string(forKey: urlKey) ?? "") }

    /// Settings › 데스크 브라우저 › 단축어: a word (kept in lower case) and the address it opens.
    static let shortcutsKey = "deskShortcuts"
    static var shortcuts: [String: String] { UserDefaults.standard.dictionary(forKey: shortcutsKey) as? [String: String] ?? [:] }

    /// A word typed alone in the address bar that stands for an address: one set in Settings, else "home" (or "홈")
    /// for the home address. Nil for anything else, and for "home" with no home address, which then searches.
    static func shortcut(_ word: String, in set: [String: String], home: URL?) -> URL? {
        let w = word.trimmingCharacters(in: .whitespaces).lowercased()
        if let to = set[w], let u = address(to) { return u }
        return ["home", "홈"].contains(w) ? home : nil
    }

    /// What the address bar opens for what was typed: a shortcut first, then as `address`.
    static func normalize(_ input: String) -> URL? { shortcut(input, in: shortcuts, home: home) ?? address(input) }

    /// "naver.com" opens the site, "맥 배경화면" searches, a full URL stays as typed.
    static func address(_ input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s.contains("://") { return URL(string: s) }
        if s.hasPrefix("localhost"), !s.contains(" ") { return URL(string: "http://" + s) }
        if s.contains("."), !s.contains(" ") { return URL(string: "https://" + s) }
        var q = URLComponents(string: "https://www.google.com/search")!
        q.queryItems = [URLQueryItem(name: "q", value: s)]
        return q.url
    }

    func start() {
        // macOS's menu bar showing or not on each screen's desktop, looked at 10 times a second (it takes a quarter
        // second to slide down). The top of the page is read when that changes, and every second besides (0.2 s while
        // the bar shows), for a page that has scrolled or changed since (`DeskFrame.readTop`).
        var looks = 0, strength = DeskMenuShade.strength, preview = Date.distantPast
        var desktops: [CGDirectDisplayID: UInt64] = [:] // Each screen's desktop on show: asked once a second, and when it changes.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in desktops = [:] }
        let bar = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.shownOn else { return }
            looks += 1
            // The strength being set in Settings: the shade shows meanwhile, and a second and a half after, whatever
            // the menu bar and the page, so it is seen as it is set.
            if DeskMenuShade.strength != strength { (strength, preview) = (DeskMenuShade.strength, Date().addingTimeInterval(1.5)) }
            let trying = Date() < preview
            // A desktop added (Mission Control's +) has no desk window until it is looked for: once a second, so it
            // has one before it is slid to, not the wallpaper all the way in and a third of a second after.
            if looks % 10 == 0, NSScreen.screens.contains(where: { s in
                let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
                return Set(Desktops.of(s).filter(\.desktop).map(\.id)) != Set((self.frames[id] ?? []).compactMap(\.space))
            }) { self.rebuild(true) }
            if looks % 10 == 0 { desktops = [:] }
            for s in NSScreen.screens {
                let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
                if desktops[id] == nil { desktops[id] = Desktops.current(s) }
                guard let space = desktops[id] else { continue }
                // Asked only where it can have changed (the call costs this app over a millisecond): a hidden menu
                // bar comes down with the cursor at the top of the screen, and one that shows is asked about every
                // other look.
                let was = self.frames[id]?.first { $0.space == space }?.menuBarShown ?? false
                let near = NSEvent.mouseLocation.y > s.frame.maxY - 60 && s.frame.contains(NSEvent.mouseLocation)
                guard trying || near || (was && looks % 2 == 0) || looks % 10 == 0 else { continue }
                let shows = Desktops.menuBarShows(on: space)
                for f in self.frames[id] ?? [] where f.space == space {
                    if trying || shows != f.menuBarShown || looks % (shows ? 2 : 10) == 0 {
                        f.readTop(menuBar: shows || trying, lightText: Desktops.menuBarTextIsLight(on: space), whatever: trying)
                    }
                    f.menuBarShown = shows || trying // Read again when the try is over.
                }
            }
        }
        RunLoop.main.add(bar, forMode: .common)
        veil.warm()
        veil.desk = { [weak self] screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return self?.frames[id]?.first { $0.window.isOnActiveSpace }?.window
        }
        DuoDockPin.set(UserDefaults.standard.bool(forKey: Self.duoKey)) // Also puts the Dock back after a crash.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            DuoDockPin.set(false)
        }
        sync()
        FourFingerSwipe.start { [weak self] way in
            switch way {
            case .down: self?.fourFingersDown()
            case .up: self?.fourFingersUp()
            case .left, .right: self?.fourFingersAcross(toRight: way == .right) // The way the fingers went.
            }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.sync() }
        holdEscape()
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] _ in self?.missionControl = false }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.missionControl = false
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.shownOn else { return }
            self.rebuild(true)
        }
        // Show Desktop (F11, a hot corner, a click on the desk) leaves the keyboard with the app in front, or hands it
        // to Finder; the desk browser takes it, as the desktop it now is, and the dimmed frame is lifted in step with
        // it. macOS posts nothing for it, so the window list is watched: the frame's window comes up as it starts, and
        // on the way back the windows are seen to move, a third of a second before that window goes.
        // The lift is timed off these looks (`ShowDesktopVeil.set`): the frame's window is in the list 50 ms before
        // it starts to dim, and on the way back WindowManager's shield window is, 30 ms before the dim starts to go.
        // The window server says when a window has come or gone (`ShowDesktop.onChange`), and the list is read then:
        // nothing is asked of it meanwhile. Asking 60 or 120 times a second cost this app up to an eighth of a core
        // (a millisecond a look here, whatever is asked). ponytail: its word is private and may stop coming, so the
        // count of windows is still asked 5×/s; and while the desktop is shown the list is read 20×/s, for the
        // windows' moves. A look after its word is 12 ms behind the frame's window on the way in and 2 ms behind the
        // shield on the way back (measured); a timed look, half its wait.
        var wasOn = false, lifted = false, still = 0, spots: [CGRect] = [], tick = 0, beat = 0, count: Int32 = -1
        var frames = Set<Int>(), shields = 0 // As last seen: a frame window not among them is the desktop shown (again), a shield more the way back.
        var look: (_ told: Bool) -> Void = { _ in }
        look = { [weak self] told in
            guard let self, self.shownOn || wasOn else { return }
            let seen = CACurrentMediaTime()
            if !told {
                beat += 1
                if wasOn { if beat % 3 != 0 { return } } else {
                    if beat % 12 != 0 { return }
                    let n = ShowDesktop.count()
                    if n == count, n >= 0 { return }
                    count = n
                }
            }
            let behind = (in: told ? 0.012 : 0.1, back: told ? 0.002 : 0.025)
            let now = ShowDesktop.read(), on = self.shownOn && now.on
            let fresh = on && !now.frames.isSubset(of: frames), back = on && now.shields > shields
            defer { wasOn = on; frames = now.frames; shields = now.shields }
            // The windows' moves are told by the timed looks alone, a twentieth of a second apart: looks after the
            // window server's word come in bursts, which read as windows at rest and then moving (the way back) while
            // they were still on their way out, and took the lift off as it came up.
            let rested = !told && still > 5 // The windows had come to rest (a quarter second of looks): the way out is over.
            if !told {
                tick += 1
                still = now.spots == spots ? still + 1 : 0
                spots = now.spots
            }
            self.deskOn = on
            if fresh {
                // A frame window that was not there at the last look: the desktop is shown, for the first time or
                // again while the last frame is still on its way out (its own lift sees that one out, `set`).
                (lifted, still) = (true, 0)
                self.veil.set(true, began: seen - ShowDesktopVeil.lag("deskVeilShowLag", behind.in))
            } else if on != wasOn { // Gone without having been seen on its way back.
                lifted = false
                self.veil.set(false, began: seen - 1)
            } else if lifted, back { // One more shield: the windows are sent back, none has moved yet. Also when sent back before they were all out.
                lifted = false
                self.veil.set(false, began: seen - ShowDesktopVeil.lag("deskVeilHideLag", behind.back))
            } else if !told, on, lifted, rested, still == 0 { // At rest and moving again: the way back, the shield not seen (16 ms on by now).
                lifted = false
                self.veil.set(false, began: seen - 0.016 - ShowDesktopVeil.lag("deskVeilHideLag", behind.back))
            } else if !told, on, !lifted, still > 10 { // Not the way back after all (a window moved under the frame).
                lifted = true
                self.veil.set(true, began: seen - 1)
            }
            // The windows on their way back: the keyboard, taken for the desk as they left, goes back to the app whose
            // window is on top, and the Duo's notch and buttons follow at once instead of at the next click on an app.
            if DuoPad.shared.desktopShown != lifted {
                DuoPad.shared.desktopShown = lifted
                if !lifted, NSApp.isActive, let app = ShowDesktop.topWindowOwner().flatMap({ NSRunningApplication(processIdentifier: $0) }) {
                    NSApp.yieldActivation(to: app) // Without it macOS may refuse the hand-over.
                    app.activate()
                }
            }
            guard on, !wasOn || tick % 3 == 0 && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
            let p = NSEvent.mouseLocation, here = self.frames.values.joined().filter { $0.window.isOnActiveSpace }
            guard let f = here.first(where: { $0.window.frame.contains(p) }) ?? here.first else { return }
            NSApp.activate(ignoringOtherApps: true)
            f.window.makeKeyAndOrderFront(nil)
        }
        ShowDesktop.onChange { look(true) }
        let watch = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in look(false) }
        RunLoop.main.add(watch, forMode: .common)
        // A new wallpaper: the home is cut from it again. macOS posts nothing for it.
        // ponytail: asks for each screen's wallpaper once a second.
        var paper: [CGDirectDisplayID: URL] = [:]
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            var now: [CGDirectDisplayID: URL] = [:]
            let id = { (s: NSScreen) in s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }
            for s in NSScreen.screens { now[id(s)] = NSWorkspace.shared.desktopImageURL(for: s) }
            guard now != paper else { return }
            let first = paper.isEmpty
            paper = now
            if first { return }
            for s in NSScreen.screens { self?.frames[id(s)]?.forEach { $0.loadHome(s) } }
        }
        // Waits out the slide, so the full-screen check sees the new front app.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self, self.shownOn else { return }
                self.rebuild(true)
            }
        }
    }

    private func sync() {
        let duo = UserDefaults.standard.bool(forKey: Self.duoKey)
        let on = UserDefaults.standard.bool(forKey: Self.onKey) || duo // The Duo style is the browser in another layout.
        let through = UserDefaults.standard.bool(forKey: Self.throughKey)
        guard on != shownOn || duo != shownDuo || through != shownThrough else { return }
        if duo != shownDuo || through != shownThrough { frames.values.joined().forEach { $0.window.close() }; frames = [:] } // Other layout: new windows.
        shownDuo = duo
        shownThrough = through
        rebuild(on)
        DuoDockPin.set(on && duo)
    }

    /// macOS reports "screen changed" for the Dock hiding, waking from sleep and the like, so a screen that is still
    /// there keeps its windows and pages and is only resized; only a screen plugged in or out gains or loses them.
    /// Every desktop of a screen has its own window, put there ahead of time so it slides in with the desktop (not a
    /// full-screen app's Space, which has no desktop). A removed desktop's window goes with it.
    private func rebuild(_ on: Bool) {
        shownOn = on
        var next: [CGDirectDisplayID: [DeskFrame]] = [:]
        for s in on ? NSScreen.screens : [] {
            let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let r = s.frame // Up to the notch, behind the menu bar.
            let old = frames.removeValue(forKey: id) ?? []
            next[id] = Desktops.of(s).filter(\.desktop).enumerated().map { n, space in
                if let f = old.first(where: { $0.space == space.id }) {
                    if f.window.frame != r { f.window.setFrame(r, display: true) }
                    return f
                }
                let f = DeskFrame(screen: s, duo: shownDuo)
                Desktops.put(f.window, on: space.id)
                f.space = space.id
                f.sessionKey = "deskSession.\(id).\(n)"
                return f
            }
            old.filter { f in next[id]?.contains { $0 === f } != true }.forEach { $0.window.close() }
        }
        frames.values.joined().forEach { $0.window.close() }
        frames = next
        // The page the bar's ink reads, and whose address sits in the bar: the notch screen's, on the Space on show. Each desktop
        // has its own window, and the last one made used to win, often a blank tab on another Space.
        let notch = notchScreen()?.frame
        DuoMenu.shared.page = frames.values.joined().first { $0.window.isOnActiveSpace && $0.window.frame == notch && $0.onNotchScreen }
        DuoMenu.shared.set(on: on && shownDuo)
        DuoPad.shared.set(on: on && shownDuo)
        for sc in NSScreen.screens {
            let id = sc.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0, here = Desktops.current(sc)
            for f in frames[id] ?? [] {
                f.onShow = f.space == here // By the desktop's number: a window put on another desktop still says it is on the one in view.
                f.keepDrawing() // Also for tabs made since.
            }
        }
    }

    /// Show Desktop on or off, asked for by Andeville: the band's cover goes up first (`ShowDesktopVeil.arm`). On the
    /// way back macOS is asked 24 ms later, by when the cover is on the screen (the frame starts to go 30 ms after
    /// it is asked); on the way in at once (the frame takes 55 to dim).
    fileprivate func toggleDesktop() {
        let leaving = ShowDesktop.isOn
        if shownOn, veil.arm(leaving: leaving), leaving {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.024) { ShowDesktop.toggle() }
        } else {
            ShowDesktop.toggle()
        }
    }

    /// One of the Duo buttons, for the desk page on show on that screen.
    func press(_ a: DuoPad.Action, on display: CGDirectDisplayID) {
        frames[display]?.first { $0.window.isOnActiveSpace }?.press(a)
    }

    /// Four fingers moving down: with windows over the desk, Show Desktop clears them away (as F11 does) and the desk
    /// is all there is to see, the notch as it was; once the desk is clear, four fingers down again bring the address
    /// of the screen under the cursor into the notch, ready for typing.
    private func fourFingersDown() {
        if missionControl { missionControl = false; return } // macOS's: it closes Mission Control.
        guard shownOn else { return }
        let p = NSEvent.mouseLocation
        guard let f = frames.values.joined().first(where: { $0.window.isOnActiveSpace && $0.window.frame.contains(p) }) else { return }
        if !ShowDesktop.isOn, ShowDesktop.windowsCover(f.window.frame) { toggleDesktop() } else { f.revealAddress() }
    }

    /// Four fingers sideways with the desktop shown: the next desktop, still shown. macOS lets the swipe go while Show
    /// Desktop holds the windows aside, so it is lifted, the move made as ⌃← / ⌃→ make it (the desktops slide), and
    /// the desk shown again once the next desktop is in (or, at the last one, where it was).
    private func fourFingersAcross(toRight: Bool) {
        guard shownOn, ShowDesktop.isOn, let s = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else { return }
        let before = Desktops.current(s)
        ShowDesktop.toggle()
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: toRight ? 124 : 123, keyDown: down) // → / ←
            e?.flags = [.maskControl, .maskSecondaryFn] // Arrow keys carry fn.
            e?.post(tap: .cghidEventTap)
        }
        // ponytail: looks every 50 ms for up to 2 s; 0.35 s after it changes the slide is over.
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            tries += 1
            guard Desktops.current(s) != before || tries > 40 else { return }
            t.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if !ShowDesktop.isOn, ShowDesktop.windowsCover(s.frame) { ShowDesktop.toggle() }
            }
        }
    }

    private var escTap: CFMachPort?
    /// The desktop is shown with the browser on (the watch in start() keeps it); the Escape tap is on only then.
    fileprivate var deskOn = false { didSet { if let t = escTap, deskOn != oldValue { CGEvent.tapEnable(tap: t, enable: deskOn) } } }
    /// Four fingers up opened Mission Control (macOS's), so the next four fingers down are its, closing it.
    /// ponytail: known from the swipe alone (it shows in no window list or Accessibility); a click or a key ends it,
    /// and Mission Control opened another way (F3, a hot corner) is not known.
    private var missionControl = false

    /// While the desktop is shown only four fingers up bring the windows back: Escape, which macOS ends it with, is
    /// kept from macOS then. Andeville in front still gets it (the address bar's suggestions, a video's full screen).
    private func holdEscape() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        escTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, e, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // Back on only if it should be: turning it off here again would bring this call back, round and round.
                if let t = DeskBrowser.shared.escTap, DeskBrowser.shared.deskOn { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(e)
            }
            guard e.getIntegerValueField(.keyboardEventKeycode) == 53, DeskBrowser.shared.deskOn else { return Unmanaged.passUnretained(e) }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), let ns = NSEvent(cgEvent: e) {
                DispatchQueue.main.async { NSApp.keyWindow?.sendEvent(ns) }
            }
            return nil
        }, userInfo: nil)
        guard let t = escTap else { return log("desk: no Escape tap") }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        // Off until the desktop is shown: on, every key on the Mac waits for this main thread (seen: typing stuck).
        CGEvent.tapEnable(tap: t, enable: false)
    }

    /// Four fingers moving up: the notch's address, if it is out, goes back in; with it in, the windows Show Desktop
    /// moved aside come back. (Without the desktop shown the swipe is macOS's as well, for Mission Control.)
    private func fourFingersUp() {
        let shown = shownOn && ShowDesktop.isOn
        if DuoMenu.shared.tabsShown {
            DuoMenu.shared.fold()
            if shown { return }
        }
        if shown { toggleDesktop() } else { missionControl = true }
    }
}

/// Four fingers moving across the trackpad (down, up, or sideways), from its raw touches (MultitouchSupport, private: scroll
/// events don't say how many fingers there are). Called on the main thread, once per swipe.
/// ponytail: the 96-byte touch layout every macOS so far uses; check it first if swipes stop registering.
enum FourFingerSwipe {
    /// Which way the fingers moved.
    enum Way { case up, down, left, right }
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private static var onSwipe: ((Way) -> Void)?
    private static var start: (x: Float, y: Float)?, fired = false

    static func start(_ action: @escaping (Way) -> Void) {
        onSwipe = action
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let list = dlsym(h, "MTDeviceCreateList"), let reg = dlsym(h, "MTRegisterContactFrameCallback"),
              let run = dlsym(h, "MTDeviceStart") else { return }
        typealias List = @convention(c) () -> Unmanaged<CFArray>?
        typealias Reg = @convention(c) (UnsafeMutableRawPointer?, Callback) -> Void
        typealias Run = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
        guard let devices = unsafeBitCast(list, to: List.self)()?.takeRetainedValue() as? [AnyObject] else { return }
        for d in devices {
            let dev = Unmanaged.passUnretained(d).toOpaque()
            unsafeBitCast(reg, to: Reg.self)(dev, frame)
            unsafeBitCast(run, to: Run.self)(dev, 0)
        }
    }

    /// One frame of touches, on MultitouchSupport's own thread.
    private static let frame: Callback = { _, touches, count, _, _ in
        guard count == 4, let touches else {
            if count == 0 { DispatchQueue.main.async { start = nil; fired = false } }
            return 0
        }
        // Average place on the pad, 0...1 from the bottom left (normalized.pos, bytes 32 and 36).
        var x: Float = 0, y: Float = 0
        for i in 0..<4 {
            x += touches.load(fromByteOffset: i * 96 + 32, as: Float.self) / 4
            y += touches.load(fromByteOffset: i * 96 + 36, as: Float.self) / 4
        }
        DispatchQueue.main.async {
            guard !fired else { return }
            guard let s = start else { start = (x, y); return }
            let dx = x - s.x, dy = y - s.y
            // The way it moved most: a sideways swipe (macOS's to the next desktop) drifting up or down is not a vertical one.
            guard max(abs(dx), abs(dy)) > 0.12 else { return } // ponytail: 12% of the pad; lower for a shorter swipe.
            fired = true
            onSwipe?(abs(dy) >= abs(dx) ? (dy < 0 ? .down : .up) : (dx < 0 ? .left : .right))
        }
        return 0
    }
}

private final class DeskWindow: NSWindow {
    /// A ⌘ shortcut (key as typed, with or without ⇧); true when it was used.
    var onCommand: ((String, Bool) -> Bool)?

    /// Where a press that may clear the way went down (window-list coordinates).
    private var clearing: CGPoint?

    /// The browser is the desktop, so a click on it with other windows in the way shows the desktop as a click on the
    /// wallpaper does (macOS's own Show Desktop, `ShowDesktop`). That click only clears the way; it doesn't also press
    /// a link under it. Only a click: a press that moves (a window's edge missed by a hair while dragging it) or that lands at another
    /// window's edge, in the resize margin just outside it, leaves everything where it is.
    override func sendEvent(_ e: NSEvent) {
        let at = e.cgEvent?.location ?? .zero
        if e.type == .leftMouseDown, !ShowDesktop.isOn, ShowDesktop.windowsCover(frame) { // Shown: the windows peek in at the edges, and clicks are the page's.
            clearing = ShowDesktop.nearWindowEdge(at) ? nil : at
            return
        }
        if let from = clearing, e.type == .leftMouseDragged || e.type == .leftMouseUp {
            if e.type == .leftMouseUp { clearing = nil }
            if hypot(at.x - from.x, at.y - from.y) > 4 { clearing = nil } else if e.type == .leftMouseUp, !ShowDesktop.isOn { DeskBrowser.shared.toggleDesktop() }
            return
        }
        super.sendEvent(e)
    }
    override var canBecomeKey: Bool { true } // Borderless windows refuse typing otherwise.
    override var canBecomeMain: Bool { true }

    /// Andeville has no Edit or browser menus, so the usual shortcuts are wired here.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        Self.keyEquivalent(e, from: self, onCommand) ?? super.performKeyEquivalent(with: e)
    }

    /// The edit keys, then the browser's; nil when it is neither. Also the notch island's, whose field is the page's address.
    static func keyEquivalent(_ e: NSEvent, from sender: Any?, _ onCommand: ((String, Bool) -> Bool)?) -> Bool? {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.subtracting(.shift) == .command, let k = e.charactersIgnoringModifiers?.lowercased() else { return nil }
        let shift = flags.contains(.shift)
        let edit = ["c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)), "x": #selector(NSText.cut(_:)),
                    "a": #selector(NSText.selectAll(_:)), "z": Selector(shift ? "redo:" : "undo:")]
        if let s = edit[k], !shift || k == "z" { return NSApp.sendAction(s, to: nil, from: sender) }
        return onCommand?(k, shift)
    }
}

/// macOS's own Show Desktop (F11, a hot corner, a click on the desk): the Dock moves every window out to the edges.
enum ShowDesktop {
    /// Private CoreDock call (ApplicationServices); toggles, as F11 does.
    static func toggle() {
        typealias Send = @convention(c) (CFString, Int32) -> Void
        guard let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
              let f = dlsym(h, "CoreDockSendNotification") else { return }
        unsafeBitCast(f, to: Send.self)("com.apple.showdesktop.awake" as CFString, 0)
    }

    /// WindowManager puts its ShowDesktopOverlay (level 18, the dimmed frame) on screen only while the desktop is
    /// shown; otherwise its "Event Shield Window" stands in, down at the desktop icons' level.
    /// ponytail: read from the window list as macOS 26 has it; recheck here if the frame cover stops following it.
    static var isOn: Bool { read().on }

    /// Calls `changed`, on the main thread, whenever the window server says a window has been made or has gone
    /// (SkyLight's notices 1325 and 1326, private: they come within a frame of it, and nothing is asked meanwhile).
    static func onChange(_ changed: @escaping () -> Void) {
        typealias Proc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
        guard let c = counter, let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLSRegisterConnectionNotifyProc") else { return }
        told = changed
        let register = unsafeBitCast(f, to: (@convention(c) (Int32, Proc, UInt32, UnsafeMutableRawPointer?) -> Int32).self)
        let proc: Proc = { _, _, _, _, _ in if Thread.isMainThread { ShowDesktop.told() } else { DispatchQueue.main.async { ShowDesktop.told() } } }
        for event: UInt32 in [1325, 1326] { _ = register(c.cid, proc, event, nil) }
    }
    private static var told: () -> Void = {}

    /// How many windows are on screen (SkyLight, private; -1 without it, and the list is read every look instead).
    static func count() -> Int32 {
        guard let c = counter else { return -1 }
        var n: Int32 = -1
        _ = c.ask(c.cid, 0, &n) // What it returns is not an error code (it was read as one, and the list was read every look).
        return n
    }
    private static let counter: (cid: Int32, ask: @convention(c) (Int32, Int32, UnsafeMutablePointer<Int32>) -> Int32)? = {
        guard let main = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLSMainConnectionID"),
              let ask = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLSGetOnScreenWindowCount") else { return nil }
        return (unsafeBitCast(main, to: (@convention(c) () -> Int32).self)(),
                unsafeBitCast(ask, to: (@convention(c) (Int32, Int32, UnsafeMutablePointer<Int32>) -> Int32).self))
    }()

    /// One reading of the window list: whether the desktop is shown, WindowManager's frame windows (one for each time
    /// the desktop is shown: shown again while the last frame is still fading, there are two), how many shield
    /// windows it has out (one goes a third of a second after the desktop is shown; one more comes the moment
    /// the windows are sent back, before any of them has moved), and where every ordinary window is.
    static func read() -> (on: Bool, frames: Set<Int>, shields: Int, spots: [CGRect]) {
        var frames = Set<Int>(), shields = 0, spots: [CGRect] = []
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [] {
            let layer = w[kCGWindowLayer as String] as? Int
            if layer == 18 || layer == icons, w[kCGWindowOwnerName as String] as? String == "WindowManager" {
                if layer == 18 { frames.insert(w[kCGWindowNumber as String] as? Int ?? 0) } else { shields += 1 }
            }
            if layer == 0, let d = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d) { spots.append(b) }
        }
        return (!frames.isEmpty, frames, shields, spots)
    }

    /// The point (window-list coordinates) is in the resize margin just outside another app's window.
    static func nearWindowEdge(_ p: CGPoint, margin: CGFloat = 12) -> Bool {
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        return windows.contains { w in
            guard w[kCGWindowLayer as String] as? Int == 0, w[kCGWindowOwnerPID as String] as? Int != me,
                  let d = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d) else { return false }
            return b.insetBy(dx: -margin, dy: -margin).contains(p)
        }
    }

    /// The app has an ordinary window out.
    static func hasWindow(of pid: pid_t) -> Bool {
        windows.contains { $0[kCGWindowLayer as String] as? Int == 0 && $0[kCGWindowOwnerPID as String] as? Int == Int(pid) }
    }

    /// The other app whose ordinary window is in front of the rest.
    static func topWindowOwner() -> pid_t? {
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        return windows.first { $0[kCGWindowLayer as String] as? Int == 0 && $0[kCGWindowOwnerPID as String] as? Int != me
            && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }.flatMap { $0[kCGWindowOwnerPID as String] as? Int }.map(pid_t.init)
    }

    /// Another app's ordinary window is on this screen (frame in AppKit coordinates).
    static func windowsCover(_ frame: NSRect) -> Bool {
        let top = NSScreen.screens.first?.frame.maxY ?? 0 // The window list counts down from the main screen's top.
        let r = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        return windows.contains { w in
            guard w[kCGWindowLayer as String] as? Int == 0, w[kCGWindowOwnerPID as String] as? Int != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let d = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d) else { return false }
            return b.intersects(r)
        }
    }

    private static var windows: [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }
}

/// While the desktop is shown, WindowManager dims a rounded frame around each screen (its ShowDesktopOverlay, 25% black,
/// over every window). The desk browser is the desktop, so the frame is lifted: a window just above it brightens what
/// is behind it, in that band only, by exactly what the frame took away. It never takes the mouse.
final class ShowDesktopVeil {
    private var panels: [NSPanel] = []
    private var screens: [NSScreen] = [] // Each panel's.
    private var on = false
    /// Settings › 데스크 브라우저 › 데스크탑 보기 전환 중 가장자리 덮기: on unless turned off.
    static let coverKey = "deskVeilCover"
    /// The desk window on show on that screen, whose picture covers the band while the frame is on its way (`cover`).
    var desk: (NSScreen) -> NSWindow? = { _ in nil }

    /// The frame on its way in and out, every 120th of a second, as measured on macOS 27 off the screen itself. It
    /// does not only fade: it grows in from the screen's edges and shrinks back to them. `Dim` is how dark it is (0
    /// not at all, 1 its full quarter black), `Reach` how far in its inner edge has come (0 the screen's edge, 1 where
    /// it rests). `rise` from the moment its window is in the window list (nothing for 40 ms, most of the way by 150,
    /// there by 300), `fall` from the moment the shield window is back in it (nothing for 20 ms, gone by 200).
    /// ponytail: measured (the median of eight runs each way); remeasure if the rim flashes dark or bright.
    static let riseDim: [Double] = [0, 0, 0, 0.01, 0.03, 0.05, 0.15, 0.23, 0.29, 0.39, 0.47, 0.52, 0.57, 0.63, 0.69, 0.72, 0.75, 0.82, 0.85, 0.86, 0.87, 0.89, 0.9, 0.91, 0.94, 0.96, 0.96, 0.98, 0.98, 0.98, 0.98, 0.99, 1, 1, 1, 1, 1]
    static let riseReach: [Double] = [0, 0, 0, 0, 0, 0.02, 0.155, 0.289, 0.361, 0.404, 0.499, 0.566, 0.624, 0.679, 0.723, 0.762, 0.796, 0.826, 0.853, 0.876, 0.894, 0.911, 0.926, 0.938, 0.947, 0.957, 0.964, 0.971, 0.974, 0.979, 0.983, 0.986, 0.989, 0.992, 0.994, 0.996, 1]
    static let fallDim: [Double] = [1, 1, 1, 0.99, 0.97, 0.92, 0.84, 0.79, 0.69, 0.61, 0.53, 0.48, 0.43, 0.36, 0.3, 0.27, 0.22, 0.18, 0.17, 0.15, 0.13, 0.11, 0.1, 0.06, 0.04, 0]
    static let fallReach: [Double] = [1, 1, 0.993, 0.961, 0.915, 0.848, 0.773, 0.696, 0.62, 0.53, 0.466, 0.408, 0.358, 0.308, 0.265, 0.229, 0.197, 0.168, 0.141, 0.117, 0.099, 0.084, 0.067, 0.026, 0, 0]
    /// How much of the lift undoes that much of the dim: the lift is 4/3 at full, the dim takes a quarter at full.
    static func lift(_ dim: Double) -> Double { 0.75 * dim / (1 - 0.25 * dim) }
    /// How long before a look at the window list the thing it saw happened (`DeskBrowser.start`: 12 ms on the way in
    /// and 2 on the way back when the window server said so). What is left of the difference is under the cover
    /// while the frame is on its way (`cover`).
    /// ponytail: `defaults write com.ggear.faytai deskVeilShowLag -float <s>` (and deskVeilHideLag) move the lift
    /// against the frame: more is earlier.
    static func lag(_ key: String, _ standard: Double) -> Double { UserDefaults.standard.object(forKey: key) as? Double ?? standard }

    /// In and out in step with the frame: the lift takes the frame's own shape and darkness at every point of its way
    /// from `began`, when macOS started (on CACurrentMediaTime's clock; in the past by the time it is seen, which
    /// Core Animation makes up for).
    func set(_ on: Bool, began: CFTimeInterval) {
        guard on != self.on else { return }
        self.on = on
        let ready = armed.flatMap { $0.leaving != on ? $0 : nil } // The cover is up already, for this very way (`arm`).
        armed = nil
        if on {
            // The last panels are left be: shown again while the last frame is still fading, they go on undoing that
            // one to its end (the two lifts multiply, as the two frames' dims do), and stand by again after.
            if let ready { (panels, screens) = (ready.panels, ready.screens) } else {
                warm()
                screens = NSScreen.screens
                panels = spare.popLast() ?? screens.map(Self.panel)
                panels.forEach { $0.orderFrontRegardless() }
            }
        }
        let dim = on ? Self.riseDim : Self.fallDim, reach = on ? Self.riseReach : Self.fallReach, length = Double(dim.count - 1) / 120
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Unhidden here, with no action of its own: a layer shown again fades in over a quarter second otherwise,
        // and the lift and the cover came up that far behind the frame.
        if on { panels.forEach { $0.contentView?.layer?.sublayers?.forEach { $0.isHidden = false } } }
        for (panel, screen) in zip(panels, screens) {
            guard let l = panel.contentView?.layer?.sublayers?.first, let mask = l.mask as? CAShapeLayer else { continue }
            let fade = CAKeyframeAnimation(keyPath: "opacity"), grow = CAKeyframeAnimation(keyPath: "path")
            fade.values = dim.map { NSNumber(value: Self.lift($0)) }
            grow.values = reach.map { Self.band(screen, reach: $0) }
            for a in [fade, grow] {
                a.duration = length
                a.beginTime = l.convertTime(began, from: nil)
                a.fillMode = .backwards
            }
            l.opacity = on ? 1 : 0
            mask.path = Self.band(screen, reach: on ? 1 : 0)
            l.add(fade, forKey: "fade")
            mask.add(grow, forKey: "grow")
            if ready != nil { cover(panel, nil, on: on, up: true, dim: dim, began: began) }
        }
        CATransaction.commit()
        if ready == nil, UserDefaults.standard.object(forKey: Self.coverKey) as? Bool ?? true {
            // Not asked for by Andeville (F11, a hot corner, a click on the Dock): the lift goes first, then the
            // desks' pictures are taken (8 to 16 ms a screen coming up, 1 going) and the cover follows. Between a
            // look at the window list and the screen there are 30 ms, so a frame or two of the frame's start is
            // under the lift alone.
            CATransaction.flush()
            let pictures = screens.map { desk($0).flatMap { Self.picture(of: CGWindowID($0.windowNumber)) } }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (panel, picture) in zip(panels, pictures) { cover(panel, picture, on: on, up: false, dim: dim, began: began) }
            CATransaction.commit()
        }
        if !on {
            // After the cover has gone too (`cover`: 0.13 s past the frame's own end).
            DispatchQueue.main.asyncAfter(deadline: .now() + max(began + length - CACurrentMediaTime(), 0) + 0.2) { [weak self, panels] in
                // Unless they are the ones in use again (which does not happen: on takes others).
                guard let self, !self.on || self.panels.first !== panels.first else { return }
                self.rest(panels)
            }
        }
    }

    /// The cover put up ahead, and for which way: taken up by `set` when macOS goes that way.
    private var armed: (leaving: Bool, panels: [NSPanel], screens: [NSScreen], at: CFTimeInterval)?

    /// Ahead of a way in or out of Show Desktop that Andeville itself is about to ask macOS for: the cover goes up
    /// now, so it is on the screen before the frame makes its first move (from a look at the window list to the
    /// screen there are 30 ms, in which the frame has started). True when it is up.
    @discardableResult func arm(leaving: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: Self.coverKey) as? Bool ?? true, armed == nil, leaving == on else { return false }
        let targets: [NSPanel], on: [NSScreen]
        if leaving { (targets, on) = (panels, screens) } else {
            warm()
            on = NSScreen.screens
            targets = spare.popLast() ?? on.map(Self.panel)
            targets.forEach { $0.orderFrontRegardless() }
        }
        let pictures = on.compactMap { desk($0).flatMap { Self.picture(of: CGWindowID($0.windowNumber)) } }
        guard pictures.count == on.count else { if !leaving { rest(targets) }; return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (p, picture) in zip(targets, pictures) {
            guard let cover = p.contentView?.layer?.sublayers?.last else { continue }
            cover.isHidden = false
            cover.removeAnimation(forKey: "cover")
            cover.contents = picture
            cover.opacity = 1
        }
        CATransaction.commit()
        CATransaction.flush()
        let at = CACurrentMediaTime()
        armed = (leaving, targets, on, at)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let a = self.armed, a.at == at else { return } // Not taken up: macOS did not go that way after all.
            self.armed = nil
            if a.leaving { a.panels.forEach { $0.contentView?.layer?.sublayers?.last?.opacity = 0 } } else { self.rest(a.panels) }
        }
        return true
    }

    /// Panels standing by: in the window list, showing nothing. Made ahead, because a window made as the frame comes
    /// up is on screen 30 to 50 ms later, by when the frame has started without its lift. Two sets at most (the
    /// desktop shown again while the last frame fades).
    private var spare: [[NSPanel]] = []
    private var madeFor: [NSRect] = [] // The screens they were made for.

    /// A set of panels ready for the screens as they are now.
    func warm() {
        let frames = NSScreen.screens.map(\.frame)
        if frames != madeFor {
            spare.joined().forEach { $0.orderOut(nil) }
            (spare, madeFor) = ([], frames)
        }
        guard spare.isEmpty else { return }
        let set = NSScreen.screens.map(Self.panel)
        spare.append(set)
        rest(set, keep: false)
    }

    /// Done with: back to standing by, or away if the screens have changed since or two sets stand by already.
    private func rest(_ panels: [NSPanel], keep: Bool = true) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for p in panels {
            p.contentView?.layer?.sublayers?.forEach { $0.isHidden = true; $0.removeAllAnimations() }
            p.contentView?.layer?.sublayers?.last?.contents = nil
            p.contentView?.layer?.sublayers?.last?.opacity = 0
        }
        CATransaction.commit()
        guard keep else { return panels.forEach { $0.orderFrontRegardless() } }
        if panels.map(\.frame) == madeFor, spare.count < 2 { spare.append(panels) } else { panels.forEach { $0.orderOut(nil) } }
    }

    /// The lift follows the frame to within a few milliseconds, which at the speed the frame's edge moves still leaves
    /// a strip a point or two wide, too bright or too dark, for a frame or two: macOS starts the frame up to 5 ms
    /// sooner or later after anything that can be seen of it. So while the frame is on its way the band is covered
    /// with a picture of the desk itself, taken as it starts: whatever the frame and the lift do under it is not
    /// seen. It stays until the frame is at rest, then fades to the lift, which is exact at rest; on the way back it
    /// is off once the frame has gone. Asked for by Andeville itself (a click on the desk, four fingers), it is up
    /// before macOS is asked (`arm`); otherwise it follows the first look at the window list, a frame or two late. Under it the windows are cut off at the band while they slide, and the slivers they leave at the
    /// edges come in with the fade; a page that moves stands still in the band meanwhile.
    /// ponytail: a still, not the page live (its layers cannot be shown in a second window); the desk is read with
    /// CGWindowListCreateImage (gone from the SDK's headers, still in CoreGraphics; without it there is no cover),
    /// on the main thread, which it holds for 8 to 16 ms a screen as the windows start to move (`set`).
    private func cover(_ panel: NSPanel, _ picture: CGImage?, on: Bool, up: Bool, dim: [Double], began: CFTimeInterval) {
        guard let layers = panel.contentView?.layer?.sublayers, layers.count > 1, let cover = layers.last, up || picture != nil else { return }
        // Opacity every 120th of a second. Up already (`arm`), or on the way back: on throughout. Else on from 24 to
        // 40 ms (the frame starts to dim at 40 to 50). Held to the frame's end and 50 ms more, then let go.
        var steps = on && !up ? dim.indices.map { min(1, max(0, (Double($0) / 120 - 0.024) / 0.016)) } : dim.map { _ in 1 }
        steps += Array(repeating: 1, count: 6)
        let out = on ? 18 : 10 // 0.15 s to the lift, 0.08 s to nothing.
        steps += (1...out).map { 1 - Double($0) / Double(out) }
        let show = CAKeyframeAnimation(keyPath: "opacity")
        show.values = steps.map { NSNumber(value: $0) }
        show.duration = Double(steps.count - 1) / 120
        show.beginTime = cover.convertTime(began, from: nil)
        show.fillMode = .backwards
        if let picture { cover.contents = picture }
        cover.opacity = 0
        cover.add(show, forKey: "cover")
    }

    /// That window alone, as the window server has it, whatever is over it.
    static func picture(of window: CGWindowID) -> CGImage? {
        typealias Shot = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        // optionIncludingWindow, boundsIgnoreFraming
        return unsafeBitCast(f, to: Shot.self)(.null, 1 << 3, window, 1 << 0)?.takeRetainedValue()
    }

    /// The frame as measured on macOS 27: 16pt in from the sides and bottom, just under the menu bar at the top, inner
    /// corners of 20pt, continuous. `reach` is how far in it has come on its way from the screen's edges (0) to there
    /// (1); the corners round as it comes (as the root of it, which is what the corner measured closest to).
    /// ponytail: measured, not read from WindowManager; remeasure if a rim shows again.
    static func band(_ screen: NSScreen, reach: Double = 1) -> CGPath {
        let k = CGFloat(min(max(reach, 0), 1))
        let b = CGRect(origin: .zero, size: screen.frame.size)
        // On the notch screen the frame's top edge is 3pt under the notch (35pt), whether the menu bar shows or hides:
        // the bar's own height (33pt shown, 32pt hidden) left a dimmed line across the top and round the corners.
        // ponytail: without a notch it is taken as 2pt under the menu bar, not measured.
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        let top = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top + 3 : bar > 0 ? bar + 2 : 16
        let inner = CGRect(x: 16 * k, y: 16 * k, width: b.width - 32 * k, height: b.height - (16 + top) * k)
        let p = CGMutablePath()
        p.addRect(b)
        p.addPath(Path(roundedRect: inner, cornerRadius: 20 * k.squareRoot(), style: .continuous).cgPath)
        return p
    }

    private static func panel(_ screen: NSScreen) -> NSPanel {
        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        p.level = NSWindow.Level(rawValue: 19) // Just over the frame (ShowDesktopOverlay, level 18), under the menu bar.
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.setFrame(screen.frame, display: false)
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        if let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type,
           let filters = NSClassFromString("CAFilter") as? NSObject.Type,
           let lift = filters.perform(NSSelectorFromString("filterWithType:"), with: "colorMatrix")?.takeUnretainedValue() as? NSObject {
            let l = cls.init()
            l.setValue(true, forKey: "windowServerAware")
            l.frame = v.bounds
            l.opacity = 0 // Comes up with the frame (`set`).
            // ponytail: 1/0.75 undoes the 25% black; `defaults write com.ggear.faytai deskVeilGain -float <k>` tunes it.
            let k = Float(UserDefaults.standard.object(forKey: "deskVeilGain") as? Double ?? 4.0 / 3.0)
            var m: [Float] = [k, 0, 0, 0, 0, 0, k, 0, 0, 0, 0, 0, k, 0, 0, 0, 0, 0, 1, 0]
            lift.setValue(NSValue(bytes: &m, objCType: "{CAColorMatrix=ffffffffffffffffffff}"), forKey: "inputColorMatrix")
            l.filters = [lift]
            let mask = CAShapeLayer()
            mask.path = band(screen)
            mask.fillRule = .evenOdd
            l.mask = mask
            v.layer?.addSublayer(l)
        }
        // Over the lift: the desk's own picture in the band, while the frame is on its way (`cover`).
        let cover = CALayer(), shape = CAShapeLayer()
        cover.frame = v.bounds
        cover.contentsGravity = .resize
        cover.opacity = 0
        shape.path = band(screen)
        shape.fillRule = .evenOdd
        cover.mask = shape
        v.layer?.addSublayer(cover)
        p.contentView = v
        return p
    }
}

/// Across the top of the desk page: the band above the page in the page's own colour (`DeskFrame.readTop`), and over
/// it a shade behind macOS's menu bar, deepest at the screen's edge and gone by 84pt down (as tall as the window
/// server's own shade for the menu bar, which lies under the desk and is drawn for the wallpaper). Clicks pass
/// through it to the page.
final class DeskMenuShade: NSView {
    static let height: CGFloat = 84
    /// Settings › 데스크 브라우저 › 메뉴 막대 받침 진하기: how much of the page the shade takes at the screen's edge, 0...1.
    static let strengthKey = "deskMenuShade", strengthDefault = 0.5
    static var strength: Double { min(max(UserDefaults.standard.object(forKey: strengthKey) as? Double ?? strengthDefault, 0), 1) }
    private let fade = CAGradientLayer(), band = CALayer()
    private var shown: (CGFloat, Bool, Double) = (0, true, strengthDefault)
    private var bandHeight: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fade.startPoint = CGPoint(x: 0.5, y: 1) // From the top edge down.
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        fade.locations = [0, 0.4, 0.7, 1]
        fade.opacity = 0
        band.isHidden = true
        layer?.addSublayer(band)
        layer?.addSublayer(fade)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        band.frame = CGRect(x: 0, y: bounds.height - bandHeight, width: bounds.width, height: bandHeight)
        CATransaction.commit()
    }

    /// The band above the page, in that colour (nil: none). A change of colour eases over a fifth of a second.
    func setBand(_ colour: CGColor?, height: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bandHeight = height
        band.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        if band.isHidden || colour == nil { band.backgroundColor = colour } // Shown anew: in its colour at once.
        band.isHidden = colour == nil
        CATransaction.commit()
        guard let colour, band.backgroundColor != colour else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        band.backgroundColor = colour
        CATransaction.commit()
    }

    /// How much of it (0 none, 1 all), dark for light titles or light for dark ones. Eases over a fifth of a second.
    func set(_ amount: CGFloat, dark: Bool) {
        let strength = Self.strength
        guard amount != shown.0 || dark != shown.1 || strength != shown.2 else { return }
        shown = (amount, dark, strength)
        let tone: CGFloat = dark ? 0 : 1
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        // As set at the top edge (half, unless changed: enough for the titles, and the page still shows through),
        // less on the way down.
        fade.colors = [1, 0.72, 0.28, 0].map { CGColor(gray: tone, alpha: $0 * strength) }
        fade.opacity = Float(amount)
        CATransaction.commit()
    }
}

/// The desktop browser sits under every window, so the click that brings it forward must also press the button.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Pages visited in the desk browser, newest first, for the address bar's suggestions.
enum DeskHistory {
    struct Entry: Equatable { let url: String, title: String }
    static let key = "deskHistory"

    static func all() -> [Entry] { load(key) }

    /// A list of pages as kept in the defaults: [[url, title]].
    static func load(_ key: String) -> [Entry] {
        (UserDefaults.standard.array(forKey: key) as? [[String]] ?? []).compactMap { $0.count == 2 ? Entry(url: $0[0], title: $0[1]) : nil }
    }
    static func store(_ list: [Entry], _ key: String) { UserDefaults.standard.set(list.map { [$0.url, $0.title] }, forKey: key) }

    /// What the address bar offers for what was typed: bookmarks first, then pages visited; with nothing typed, the bookmarks.
    static func suggest(_ typed: String) -> [Entry] {
        let marks = DeskBookmarks.all(), urls = Set(marks.map(\.url))
        if typed.trimmingCharacters(in: .whitespaces).isEmpty { return Array(marks.prefix(10)) }
        return rank(marks + all().filter { !urls.contains($0.url) }, typed)
    }

    static func add(url: String, title: String) {
        let list = [Entry(url: url, title: title)] + all().filter { $0.url != url }
        save(list)
    }

    /// Pages brought over from another browser go after the ones visited here; an address already listed keeps its place.
    /// Returns how many were kept: the list holds 500, so a full one takes none.
    @discardableResult static func merge(_ more: [Entry]) -> Int {
        let mine = all(), seen = Set(mine.map(\.url))
        var added = Set<String>()
        let new = more.filter { !seen.contains($0.url) && added.insert($0.url).inserted }
        save(mine + new)
        return max(0, min(new.count, 500 - mine.count))
    }

    private static func save(_ list: [Entry]) {
        store(Array(list.prefix(500)), key) // ponytail: 500 newest; trim by age if it grows.
    }

    /// Entries whose address starts with what was typed come first (scheme and www. ignored), then any containing it.
    static func rank(_ entries: [Entry], _ typed: String, limit: Int = 6) -> [Entry] {
        let q = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        func bare(_ u: String) -> String {
            var s = u.lowercased()
            for p in ["https://", "http://", "www."] where s.hasPrefix(p) { s.removeFirst(p.count) }
            return s
        }
        let starts = entries.filter { bare($0.url).hasPrefix(bare(q)) }
        let contains = entries.filter { !starts.contains($0) && ($0.url.lowercased().contains(q) || $0.title.lowercased().contains(q)) }
        return Array((starts + contains).prefix(limit))
    }
}

/// Pages kept with ⌘D or the star, and those brought over from other browsers, in the order added.
/// ponytail: one flat list, folders flattened on import; add folders when the list grows past a glance.
enum DeskBookmarks {
    typealias Entry = DeskHistory.Entry
    static let key = "deskBookmarks"
    static func all() -> [Entry] { DeskHistory.load(key) }
    static func has(_ url: String) -> Bool { all().contains { $0.url == url } }

    /// Keeps the page, or lets it go when it is already kept. Returns whether it is kept now.
    @discardableResult static func toggle(url: String, title: String) -> Bool {
        let list = all(), kept = list.contains { $0.url == url }
        DeskHistory.store(kept ? list.filter { $0.url != url } : list + [Entry(url: url, title: title)], key)
        return !kept
    }

    /// Imported bookmarks go after the ones kept here; one already kept is not added twice.
    static func merge(_ more: [Entry]) {
        var seen = Set(all().map(\.url))
        DeskHistory.store(all() + more.filter { seen.insert($0.url).inserted }, key)
    }
}

/// Settings › 데스크 브라우저 › 다른 브라우저에서 가져오기: visited pages and sign-ins (cookies) from Safari, Chromium browsers
/// and Firefox move into the desk browser. Reads copies of their files, so those browsers can stay open.
enum BrowserImport {
    /// A Chromium browser's keychain items (service, account) its cookie key may sit under.
    enum Kind { case safari, chromium(keys: [(String, String)]), firefox }
    struct Source: Hashable {
        let name: String, dir: URL, kind: Kind
        static func == (a: Source, b: Source) -> Bool { a.name == b.name }
        func hash(into h: inout Hasher) { h.combine(name) }
    }
    struct Outcome { var pages = 0, bookmarks = 0, cookies = 0, notes: [String] = [] }
    struct Denied: Error {}

    /// The browsers found on this Mac. Safari's folder is always there; reading it needs Full Disk Access.
    static var sources: [Source] {
        let home = FileManager.default.homeDirectoryForCurrentUser, app = home.appendingPathComponent("Library/Application Support")
        // Profile folder, then the keychain item its cookies are encrypted with.
        let chromium: [(String, String, [(String, String)])] = [
            ("Chrome", "Google/Chrome/Default", [("Chrome Safe Storage", "Chrome")]),
            ("Arc", "Arc/User Data/Default", [("Arc Safe Storage", "Arc")]),
            ("Edge", "Microsoft Edge/Default", [("Microsoft Edge Safe Storage", "Microsoft Edge")]),
            ("Brave", "BraveSoftware/Brave-Browser/Default", [("Brave Browser Safe Storage", "Brave Browser"), ("Brave Safe Storage", "Brave")]),
            ("Vivaldi", "Vivaldi/Default", [("Vivaldi Safe Storage", "Vivaldi")]),
            ("Chromium", "Chromium/Default", [("Chromium Safe Storage", "Chromium")]),
        ]
        let found = chromium.map { Source(name: $0.0, dir: app.appendingPathComponent($0.1), kind: .chromium(keys: $0.2)) }
        // Firefox's profile in use is the one whose history changed last.
        let profiles = (try? FileManager.default.contentsOfDirectory(at: app.appendingPathComponent("Firefox/Profiles"), includingPropertiesForKeys: nil)) ?? []
        func touched(_ p: URL) -> Date { (try? p.appendingPathComponent("places.sqlite").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        let firefox = profiles.filter { touched($0) > .distantPast }.max { touched($0) < touched($1) }.map { Source(name: "Firefox", dir: $0, kind: .firefox) }
        return ([Source(name: "Safari", dir: home.appendingPathComponent("Library/Safari"), kind: .safari)] + found + [firefox].compactMap { $0 })
            .filter { FileManager.default.fileExists(atPath: $0.dir.path) }
    }

    /// Off the main thread: it reads databases and may wait on the keychain prompt.
    static func run(_ s: Source) throws -> (pages: [DeskHistory.Entry], bookmarks: [DeskHistory.Entry], cookies: [HTTPCookie], notes: [String]) {
        var notes: [String] = []
        let pages: [DeskHistory.Entry], marks: [DeskHistory.Entry]
        var cookies: [HTTPCookie] = []
        switch s.kind {
        case .safari:
            pages = try history(s.dir.appendingPathComponent("History.db"), """
                SELECT i.url, COALESCE(v.title, ''), MAX(v.visit_time) AS t FROM history_items i
                JOIN history_visits v ON v.history_item = i.id GROUP BY i.id ORDER BY t DESC LIMIT 1000
                """)
            let plist = (try? Data(contentsOf: s.dir.appendingPathComponent("Bookmarks.plist"))).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
            marks = safariBookmarks(plist)
            let jar = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
            if let d = try? Data(contentsOf: jar) { cookies = safariCookies(d) } else { notes.append("Safari 로그인 정보는 읽지 못했습니다") }
        case .chromium(let keys):
            pages = try history(s.dir.appendingPathComponent("History"), "SELECT url, title FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT 1000")
            let json = (try? Data(contentsOf: s.dir.appendingPathComponent("Bookmarks"))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            marks = chromiumBookmarks(json)
            if let key = keys.lazy.compactMap(chromiumKey).first {
                cookies = (try? chromiumCookies(s.dir.appendingPathComponent("Network/Cookies"), key: key)) // Chrome 96 on.
                    ?? (try? chromiumCookies(s.dir.appendingPathComponent("Cookies"), key: key)) ?? []
            } else { notes.append("키체인의 \(keys[0].0)를 허용하지 않아 로그인 정보는 건너뛰었습니다") }
        case .firefox:
            pages = try history(s.dir.appendingPathComponent("places.sqlite"), """
                SELECT url, COALESCE(title, '') FROM moz_places WHERE hidden = 0 AND last_visit_date IS NOT NULL
                ORDER BY last_visit_date DESC LIMIT 1000
                """)
            marks = (try? history(s.dir.appendingPathComponent("places.sqlite"), """
                SELECT p.url, COALESCE(b.title, p.title, '') FROM moz_bookmarks b JOIN moz_places p ON p.id = b.fk
                WHERE b.type = 1 ORDER BY b.parent, b.position
                """)) ?? []
            cookies = (try? firefoxCookies(s.dir.appendingPathComponent("cookies.sqlite"))) ?? []
        }
        return (pages, marks.filter { $0.url.hasPrefix("http://") || $0.url.hasPrefix("https://") }, cookies, notes)
    }

    /// Brings `s` over: pages into the address bar's suggestions, cookies into the desk browser's store.
    static func start(_ s: Source, done: @escaping (Result<Outcome, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try run(s)
                DispatchQueue.main.async {
                    let pages = DeskHistory.merge(r.pages)
                    DeskBookmarks.merge(r.bookmarks)
                    let store = WKWebsiteDataStore.default().httpCookieStore, group = DispatchGroup()
                    for c in r.cookies { group.enter(); store.setCookie(c) { group.leave() } }
                    group.notify(queue: .main) { done(.success(Outcome(pages: pages, bookmarks: r.bookmarks.count, cookies: r.cookies.count, notes: r.notes))) }
                }
            } catch { DispatchQueue.main.async { done(.failure(error)) } }
        }
    }

    // MARK: Databases

    /// Runs `sql` on a copy of the database and its journal, so a browser holding it open doesn't block the read.
    static func rows(_ db: URL, _ sql: String, _ each: (OpaquePointer) -> Void) throws {
        let fm = FileManager.default, tmp = fm.temporaryDirectory.appendingPathComponent("import-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent(db.lastPathComponent)
        // Safari's files exist but can't be read without Full Disk Access ("stat" is allowed, reading is not).
        do { try fm.copyItem(at: db, to: copy) } catch let e as NSError where e.code == NSFileReadNoPermissionError { throw Denied() }
        for ext in ["-wal", "-shm"] { try? fm.copyItem(atPath: db.path + ext, toPath: copy.path + ext) }
        var h: OpaquePointer?, st: OpaquePointer?
        defer { sqlite3_finalize(st); sqlite3_close(h) }
        guard sqlite3_open_v2(copy.path, &h, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw NSError(domain: "BrowserImport", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(h))])
        }
        while sqlite3_step(st) == SQLITE_ROW { each(st) }
    }

    static func text(_ st: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
    static func blob(_ st: OpaquePointer, _ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(st, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(st, i)))
    }

    static func history(_ db: URL, _ sql: String) throws -> [DeskHistory.Entry] {
        var out: [DeskHistory.Entry] = []
        try rows(db, sql) { st in
            let url = text(st, 0)
            if url.hasPrefix("http://") || url.hasPrefix("https://") { out.append(.init(url: url, title: text(st, 1))) }
        }
        return out
    }

    static func cookie(domain: String, name: String, value: String, path: String, expires: Date?, secure: Bool, httpOnly: Bool, sameSite: HTTPCookieStringPolicy?) -> HTTPCookie? {
        if let expires, expires < Date() { return nil }
        var p: [HTTPCookiePropertyKey: Any] = [.domain: domain, .name: name, .value: value, .path: path.isEmpty ? "/" : path]
        if let expires { p[.expires] = expires }
        if secure { p[.secure] = "TRUE" }
        if httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite { p[.sameSitePolicy] = sameSite }
        return HTTPCookie(properties: p)
    }

    // MARK: Bookmark files

    /// Safari's Bookmarks.plist: folders hold "Children", a bookmark has "URLString" and its title in "URIDictionary".
    /// The Reading List is left out.
    static func safariBookmarks(_ node: Any?) -> [DeskHistory.Entry] {
        guard let d = node as? [String: Any], d["Title"] as? String != "com.apple.ReadingList" else { return [] }
        if let u = d["URLString"] as? String { return [.init(url: u, title: (d["URIDictionary"] as? [String: Any])?["title"] as? String ?? "")] }
        return (d["Children"] as? [Any] ?? []).flatMap(safariBookmarks)
    }

    /// Chromium's Bookmarks JSON: "roots" › bar, other, synced; folders hold "children", a bookmark is type "url".
    static func chromiumBookmarks(_ json: Any?) -> [DeskHistory.Entry] {
        func walk(_ n: Any?) -> [DeskHistory.Entry] {
            guard let d = n as? [String: Any] else { return [] }
            if d["type"] as? String == "url", let u = d["url"] as? String { return [.init(url: u, title: d["name"] as? String ?? "")] }
            return (d["children"] as? [Any] ?? []).flatMap(walk)
        }
        let roots = (json as? [String: Any])?["roots"] as? [String: Any]
        return ["bookmark_bar", "other", "synced"].flatMap { walk(roots?[$0]) }
    }

    // MARK: Chromium

    /// The password Chromium keeps its cookie key in. Asking for it shows the keychain's allow prompt.
    static func chromiumKey(service: String, account: String) -> Data? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnData: true]
        var r: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let password = r as? Data else { return nil }
        var key = Data(count: 16)
        let ok = key.withUnsafeMutableBytes { k in
            password.withUnsafeBytes { pw in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                     "saltysalt", 9, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, k.baseAddress!.assumingMemoryBound(to: UInt8.self), 16)
            }
        }
        return ok == kCCSuccess ? key : nil
    }

    /// AES-128-CBC with a 16-space IV, PKCS#7 padded. `op` is kCCDecrypt (or kCCEncrypt, for the self-check).
    static func aes(_ data: Data, key: Data, op: Int) -> Data? {
        let iv = Data(repeating: 0x20, count: 16)
        var out = Data(count: data.count + 16), moved = 0
        let status = out.withUnsafeMutableBytes { o in data.withUnsafeBytes { d in key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
            CCCrypt(CCOperation(op), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count, v.baseAddress,
                    d.baseAddress, data.count, o.baseAddress, o.count, &moved)
        } } } }
        return status == kCCSuccess ? out.prefix(moved) : nil
    }

    /// One cookie value: "v10" + AES, or plain in `value` for old rows. From database version 24 on, the plaintext
    /// starts with SHA-256 of the host, which is dropped.
    static func chromiumValue(plain: String, encrypted: Data, key: Data, hashed: Bool) -> String? {
        guard encrypted.count > 3 else { return plain }
        guard encrypted.prefix(3) == Data("v10".utf8), let d = aes(encrypted.dropFirst(3), key: key, op: kCCDecrypt) else { return nil }
        return String(data: hashed ? d.dropFirst(32) : d, encoding: .utf8)
    }

    static func chromiumCookies(_ db: URL, key: Data) throws -> [HTTPCookie] {
        var version = 0
        try rows(db, "SELECT value FROM meta WHERE key = 'version'") { version = Int(text($0, 0)) ?? 0 }
        var out: [HTTPCookie] = []
        try rows(db, "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite FROM cookies") { st in
            guard let value = chromiumValue(plain: text(st, 2), encrypted: blob(st, 3), key: key, hashed: version >= 24) else { return }
            let t = sqlite3_column_int64(st, 5) // Microseconds since 1601; 0 for a session cookie.
            let same: [Int32: HTTPCookieStringPolicy] = [1: .sameSiteLax, 2: .sameSiteStrict]
            if let c = cookie(domain: text(st, 0), name: text(st, 1), value: value, path: text(st, 4),
                              expires: t == 0 ? nil : Date(timeIntervalSince1970: Double(t) / 1e6 - 11_644_473_600),
                              secure: sqlite3_column_int(st, 6) != 0, httpOnly: sqlite3_column_int(st, 7) != 0, sameSite: same[sqlite3_column_int(st, 8)]) { out.append(c) }
        }
        return out
    }

    // MARK: Firefox

    static func firefoxCookies(_ db: URL) throws -> [HTTPCookie] {
        var out: [HTTPCookie] = []
        try rows(db, "SELECT host, name, value, path, expiry, isSecure, isHttpOnly, sameSite FROM moz_cookies") { st in
            var t = Double(sqlite3_column_int64(st, 4))
            if t > 1e11 { t /= 1000 } // Seconds before Firefox 136, milliseconds after.
            let same: [Int32: HTTPCookieStringPolicy] = [1: .sameSiteLax, 2: .sameSiteStrict]
            if let c = cookie(domain: text(st, 0), name: text(st, 1), value: text(st, 2), path: text(st, 3), expires: Date(timeIntervalSince1970: t),
                              secure: sqlite3_column_int(st, 5) != 0, httpOnly: sqlite3_column_int(st, 6) != 0, sameSite: same[sqlite3_column_int(st, 7)]) { out.append(c) }
        }
        return out
    }

    // MARK: Safari

    /// Cookies.binarycookies: "cook", page count and page sizes (big-endian), then pages of little-endian records
    /// holding offsets to the domain, name, path and value, flags (1 secure, 4 HttpOnly) and expiry in seconds since 2001.
    static func safariCookies(_ d: Data) -> [HTTPCookie] {
        let b = [UInt8](d)
        func be(_ o: Int) -> Int { o + 4 <= b.count ? b[o..<o + 4].reduce(0) { $0 << 8 | Int($1) } : 0 }
        func le(_ o: Int) -> Int { o + 4 <= b.count ? b[o..<o + 4].reversed().reduce(0) { $0 << 8 | Int($1) } : 0 }
        func double(_ o: Int) -> Double { o + 8 <= b.count ? Double(bitPattern: b[o..<o + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }) : 0 }
        func str(_ o: Int) -> String {
            guard o < b.count, let end = b[o...].firstIndex(of: 0) else { return "" }
            return String(decoding: b[o..<end], as: UTF8.self)
        }
        guard b.count > 8, Array(b.prefix(4)) == Array("cook".utf8) else { return [] }
        let pages = min(be(4), b.count / 4) // Counts read from the file, kept to what it can hold.
        var page = 8 + pages * 4, out: [HTTPCookie] = []
        for p in 0..<pages {
            let size = be(8 + p * 4)
            for i in 0..<min(le(page + 4), size / 4) {
                let r = page + le(page + 8 + i * 4), flags = le(r + 8)
                if let c = cookie(domain: str(r + le(r + 16)), name: str(r + le(r + 20)), value: str(r + le(r + 28)), path: str(r + le(r + 24)),
                                  expires: Date(timeIntervalSinceReferenceDate: double(r + 40)), secure: flags & 1 != 0, httpOnly: flags & 4 != 0, sameSite: nil) { out.append(c) }
            }
            page += size
        }
        return out
    }
}

/// The desk browser's sidebar, as Safari's: the tabs, then the bookmarks.
struct DeskSidebar: View {
    var tabs: [(title: String, icon: NSImage?)] = []
    var current = 0
    var bookmarks: [DeskHistory.Entry] = []
    var pick: (Int) -> Void = { _ in }
    var close: (Int) -> Void = { _ in }
    var open: (String) -> Void = { _ in }

    var body: some View {
        List {
            Section("탭") {
                ForEach(tabs.indices, id: \.self) { i in
                    HStack {
                        Button { pick(i) } label: {
                            Label { Text(tabs[i].title).lineLimit(1) } icon: {
                                if let icon = tabs[i].icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) } else { Image(systemName: "globe") }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        Button { close(i) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }.help("탭 닫기")
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(i == current ? 0.12 : 0)))
                }
            }
            Section("북마크") {
                if bookmarks.isEmpty { Text("⌘D로 북마크를 추가합니다").foregroundStyle(.secondary) }
                ForEach(bookmarks, id: \.url) { b in
                    Button { open(b.url) } label: {
                        Label(b.title.isEmpty ? b.url : b.title, systemImage: "book").lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(b.url)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

private final class DeskTab {
    let web: WKWebView
    var icon: NSImage?
    var watches: [NSKeyValueObservation] = []
    init(web: WKWebView) { self.web = web }
}

private final class DeskFrame: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSTextFieldDelegate {
    let window: DeskWindow
    /// The desktop (Space) the window was put on.
    var space: UInt64?
    /// This desk is the one on show on its screen (`DeskBrowser.rebuild`). The notch screen's page is read for the
    /// Duo bar's ink under other windows, so it is kept drawing there (WebKit stops a page it takes to be covered:
    /// its own switch, not public API). Only the desk on show, and a page still loading: kept drawing on every
    /// desktop, each desktop's page ran its animations all day behind the others, a fifth of a core between them.
    var onShow = false { didSet { if onShow != oldValue { keepDrawing() } } }
    fileprivate func keepDrawing() {
        let key = Selector(("_setWindowOcclusionDetectionEnabled:"))
        for t in tabs where t.web.responds(to: key) {
            t.web.setValue(!(onNotchScreen && (onShow || t.web.isLoading)), forKey: "windowOcclusionDetectionEnabled") // KVC finds the _set… setter.
        }
    }
    /// macOS's menu bar was showing over this desk at the last look (`DeskBrowser.start`).
    var menuBarShown = false
    let field = NSTextField()
    private var tabs: [DeskTab] = []
    private var current = 0
    var web: WKWebView { tabs[current].web }
    /// Holds the current tab's page.
    private let pageHost = NSView()
    /// The browser's home: the screen's wallpaper, blurred toward the right, over a blank tab.
    private let homeView = NSImageView()
    /// The band's colour and the page it was read from (`readTop`).
    private var bandColour: (r: CGFloat, g: CGFloat, b: CGFloat)?
    private var bandPage: URL?
    /// Behind macOS's menu bar when it shows: a shade the menu's titles read against (`readTop`).
    private let menuShade = DeskMenuShade()
    /// The pull-down bar (four fingers down, ⌘L): the address, then the tabs, or suggestions while typing.
    private let addressBar = NSVisualEffectView()
    private var barRow = NSView()
    private let tabStrip = NSView()
    private let suggestionBox = NSView()
    private var suggestions: [DeskHistory.Entry] = []
    private var picked = -1
    /// ⌘F: the bar's field searches the page instead.
    private var finding = false
    private let progress = NSView()
    private let toast = NSTextField(labelWithString: "")
    private var toastTimer: Timer?
    private var downloads: [WKDownload: URL] = [:]
    /// ⌘⇧T brings these back, last closed first.
    private var closed: [URL] = []
    private var star: NSButton?
    /// Safari's sidebar: this desktop's tabs, then the bookmarks. ⌘⇧L, the bar's sidebar button or the tabs button.
    private let sidebar = NSVisualEffectView()
    private let sidebarHost = NSHostingView(rootView: DeskSidebar())
    /// The field is in the notch island, not in the pull-down bar (`DuoMenu.page`): the bar only drops the suggestions.
    private var docked: Bool { field.window != nil && field.window !== window }
    /// Where this desktop's tabs are kept between launches: its screen, and the desktop's place among that screen's.
    var sessionKey: String? { didSet { restore() } }
    /// The band at the top the page scrolls under (the notch's, or the menu bar's).
    private let topInset: CGFloat
    /// Where the page itself starts: below the band, or (메뉴 막대까지 뚫기) at the very top, under the menu bar.
    private var pageInset: CGFloat { UserDefaults.standard.bool(forKey: DeskBrowser.throughKey) ? 0 : topInset }
    let onNotchScreen: Bool
    /// The page's prefers-color-scheme follows the system theme, live (a desktop-level window misses the change otherwise).
    private var theme: NSKeyValueObservation?
    private var tintColor: () -> Void = {}

    init(screen: NSScreen, duo: Bool = false) {
        let r = screen.frame // The whole screen, up to the notch.
        window = DeskWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
        topInset = screen.safeAreaInsets.top > 0 ? notchSize(of: screen).height : screen.frame.maxY - screen.visibleFrame.maxY
        onNotchScreen = duo && screen == notchScreen()
        super.init()
        window.isReleasedWhenClosed = false
        // Two over the desktop icons, not one: at one the window server's own strip for the menu bar (its "underbelly"
        // window, 83pt at the top of every desktop) lies over the desk, and while the desktops slide it shows the
        // wallpaper there, across the top of the page.
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
        window.collectionBehavior = [.stationary, .ignoresCycle] // Stays on the desktop it was made on.
        window.setFrame(r, display: true)
        window.onCommand = { [weak self] k, shift in self?.command(k, shift: shift) ?? false }
        theme = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.window.appearance = NSAppearance(named: app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua)
                self.window.appearance?.performAsCurrentDrawingAppearance { self.tintColor() } // Resolved in the new theme.
            }
        }

        field.placeholderString = "주소 또는 검색어"
        field.usesSingleLineMode = true // One line, scrolling sideways: a long address never wraps.
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.target = self
        field.action = #selector(go)
        field.delegate = self

        let root = NSView(frame: NSRect(origin: .zero, size: r.size))
        pageHost.frame = root.bounds
        // Before macOS 26 the page can't scroll under the band, so it stops below it.
        if #unavailable(macOS 26.0) { pageHost.frame.size.height -= pageInset }
        pageHost.autoresizingMask = [.width, .height]
        homeView.frame = root.bounds
        homeView.autoresizingMask = [.width, .height]
        homeView.imageScaling = .scaleAxesIndependently // Already cut to the screen's shape.
        progress.frame = NSRect(x: 0, y: r.height - topInset - 2, width: 0, height: 2)
        progress.autoresizingMask = [.minYMargin]
        progress.wantsLayer = true
        progress.layer?.backgroundColor = Brand.orangeNS.cgColor
        menuShade.frame = NSRect(x: 0, y: r.height - DeskMenuShade.height, width: r.width, height: DeskMenuShade.height)
        menuShade.autoresizingMask = [.width, .minYMargin]
        [pageHost, homeView, menuShade, progress].forEach(root.addSubview)

        if duo {
            // Duo: the page fills the screen, the address in the pull-down bar. The rail on the right (wifi, a vertical
            // dock, the buttons) is not the page's: it floats over every app (`DuoPad`).
            field.isBordered = false // Just the text; the buttons are in `DuoPad`.
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .systemFont(ofSize: 15)
            field.frame = NSRect(x: 16, y: 12, width: 0, height: 20)
            field.autoresizingMask = [.width]
            barRow.addSubview(field)
        } else {
            let row = NSStackView(views: [
                button("chevron.left", #selector(back)), button("chevron.right", #selector(forward)),
                button("arrow.clockwise", #selector(reload)), field, button("star", #selector(toggleBookmark)), button("house", #selector(home)),
            ])
            star = row.views[4] as? NSButton
            row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
            barRow = row
        }
        addressBar.material = .hudWindow
        addressBar.blendingMode = .withinWindow
        addressBar.state = .active
        addressBar.wantsLayer = true
        addressBar.layer?.cornerRadius = 14
        addressBar.layer?.masksToBounds = true
        addressBar.isHidden = true
        addressBar.frame.size.width = min(720, r.width - 80)
        addressBar.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        // A tint in the theme's own background colour, so the text reads over a bright page as well as a dark one.
        let tint = NSView()
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        tintColor = { [weak tint] in tint?.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor }
        [tint, barRow, tabStrip, suggestionBox].forEach(addressBar.addSubview)
        root.addSubview(addressBar)

        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .active
        sidebar.isHidden = true
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: r.height - topInset)
        sidebar.autoresizingMask = [.height]
        sidebarHost.frame = sidebar.bounds
        sidebarHost.autoresizingMask = [.width, .height]
        sidebar.addSubview(sidebarHost)
        root.addSubview(sidebar)

        toast.font = .systemFont(ofSize: 13, weight: .medium)
        toast.alignment = .center
        toast.wantsLayer = true
        toast.drawsBackground = true
        toast.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92)
        toast.layer?.cornerRadius = 10
        toast.isHidden = true
        toast.autoresizingMask = [.minXMargin, .maxXMargin]
        root.addSubview(toast)
        window.contentView = root
        if duo { field.frame.size.width = addressBar.frame.width - 32 }

        loadHome(screen)
        newTab()
        layoutBar()
        window.orderFront(nil)
        // Starts blank. Focusing the field here would force this desktop-level window to become key, which macOS
        // keeps undoing — the window flickers. Four fingers (or a click) bring the address bar instead.
    }

    /// The top of the page is read, for two things. The band above the page (the menu bar's height: the page starts
    /// under it) is filled with the colour the page has just under it: WebKit fills it with the page's canvas colour,
    /// which a page that turns dark by itself leaves light (seen: a light band over a page turned black, and setting
    /// the web view's under-page colour does not reach it). And while
    /// macOS's menu bar shows, a shade is laid behind it: its titles are drawn for the wallpaper (light, in Dark Mode
    /// or over a dark wallpaper), not for the page that stands in for it, so over a page as light as they are they
    /// cannot be read. The shade is of the other tone and as deep as the page is close to the titles: none over a
    /// page they read against already.
    func readTop(menuBar shows: Bool, lightText: Bool, whatever: Bool = false) {
        let w = web.bounds.width
        // With a band, the strip of page just under it; with the page drawn through to the top, the top of the page.
        let strip = pageInset > 0 ? CGRect(x: 0, y: pageInset, width: w, height: 8) : CGRect(x: 0, y: 0, width: w, height: topInset)
        let web = self.web
        DuoTone.ground(of: web, in: strip) { [weak self] found, share in
            guard let self, web === self.web else { return } // Another tab since.
            // A clear ground (most of the strip one colour) is taken. Pictures under the band have none: the band
            // keeps the colour it had rather than follow them about, and has the strip's first colour if it had none.
            if web.url != self.bandPage { (self.bandPage, self.bandColour) = (web.url, nil) }
            if share >= 0.6 || self.bandColour == nil { self.bandColour = found }
            let c = self.bandColour ?? found
            // No band over the home (the wallpaper shows there, up to the top) or a page drawn through to the top.
            self.menuShade.setBand(self.pageInset > 0 && web.url != nil ? CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) : nil, height: self.pageInset)
            guard shows else { return self.menuShade.set(0, dark: lightText) }
            // Light titles: nothing under 0.45, all of it from 0.8. Dark titles: the other way round.
            let l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
            let need = lightText ? (l - 0.45) / 0.35 : (0.55 - l) / 0.35
            self.menuShade.set(whatever ? 1 : min(max(need, 0), 1), dark: lightText) // `whatever`: all of it, for a look at it (Settings).
        }
    }

    /// The home from the screen's wallpaper; again whenever the wallpaper changes.
    func loadHome(_ screen: NSScreen) {
        let size = screen.frame.size, scale = screen.backingScaleFactor
        let wallpaper = NSWorkspace.shared.desktopImageURL(for: screen)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let img = wallpaper.flatMap { Self.homeBackground($0, size: size, scale: scale) }
            DispatchQueue.main.async { self?.homeView.image = img }
        }
    }

    // MARK: Shortcuts

    private func command(_ k: String, shift: Bool) -> Bool {
        switch (k, shift) {
        case ("l", false): revealAddress()
        case ("l", true): toggleSidebar()
        case ("t", false): openHome(in: newTab()); revealAddress()
        case ("w", false): closeTab(current)
        case ("r", false): web.reload()
        case ("[", false): web.goBack()
        case ("]", false): web.goForward()
        case ("{", true), ("[", true): select((current + tabs.count - 1) % tabs.count)
        case ("}", true), ("]", true): select((current + 1) % tabs.count)
        case ("f", false): startFind()
        case ("d", false): toggleBookmark()
        case ("t", true): reopenTab()
        case ("p", false):
            let op = web.printOperation(with: .shared)
            op.view?.frame = web.bounds // Without a frame WebKit's print view lays out nothing: blank pages.
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        case ("g", _): find(backwards: shift)
        case ("=", _), ("+", _): web.pageZoom = min(3, web.pageZoom + 0.1)
        case ("-", false): web.pageZoom = max(0.5, web.pageZoom - 0.1)
        case ("0", false): web.pageZoom = 1
        default:
            guard !shift, let n = Int(k), (1...9).contains(n) else { return false }
            select(n == 9 ? tabs.count - 1 : min(n - 1, tabs.count - 1)) // ⌘9 is the last tab, as in Safari.
        }
        return true
    }

    // MARK: Tabs

    /// A bare WKWebView is not Safari: sites see no "Safari" in its user agent and serve cut-down pages, video can't go
    /// full screen and waits for a click. This one looks and behaves like Safari, so pages load in full.
    /// (Pop-ups get WebKit's copy of their opener's configuration, so they keep all of this.)
    static func fullConfig() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        let v = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "26.0"
        c.applicationNameForUserAgent = "Version/\(v) Safari/605.1.15"
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = true
        c.mediaTypesRequiringUserActionForPlayback = []
        c.allowsAirPlayForMediaPlayback = true
        return c
    }

    /// `front: false` opens it behind the current tab (⌘-click on a link).
    @discardableResult private func newTab(config: WKWebViewConfiguration? = nil, front: Bool = true) -> WKWebView {
        let w = WKWebView(frame: pageHost.bounds, configuration: config ?? Self.fullConfig())
        w.autoresizingMask = [.width, .height]
        w.navigationDelegate = self
        w.uiDelegate = self
        w.allowsBackForwardNavigationGestures = true
        w.allowsMagnification = true
        if #available(macOS 13.3, *) { w.isInspectable = true } // Safari › 개발 can inspect it.
        if #available(macOS 26.0, *) { w.obscuredContentInsets = NSEdgeInsets(top: pageInset, left: 0, bottom: 0, right: 0) }
        // WebKit's own strip over the band (NSScrollPocket: a blur of the page under it, which smeared a page's top into
        // stripes behind the menu bar, and a hairline along its edge) is taken off: the page shows in the band as it is,
        // as a wallpaper would. ponytail: private, reason 1 is WebKit's "full screen" (never lifted here); without the
        // method the strip simply stays.
        let hidePocket = NSSelectorFromString("_addReasonToHideTopScrollPocket:")
        if w.responds(to: hidePocket) {
            unsafeBitCast(w.method(for: hidePocket), to: (@convention(c) (AnyObject, Selector, UInt8) -> Void).self)(w, hidePocket, 1)
        }
        let tab = DeskTab(web: w)
        tab.watches = [
            w.observe(\.title) { [weak self] _, _ in self?.refreshTabs() },
            w.observe(\.url) { [weak self] w, _ in if w === self?.web { self?.refreshTabs() } }, // A restored page commits no navigation.
            w.observe(\.estimatedProgress) { [weak self] w, _ in if w === self?.web { self?.updateProgress() } },
            w.observe(\.isLoading) { [weak self] w, _ in if w === self?.web { self?.updateProgress() } },
        ]
        tabs.append(tab)
        if front { select(tabs.count - 1) } else { refreshTabs() }
        return w
    }

    fileprivate func select(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        current = i
        pageHost.subviews.forEach { $0.removeFromSuperview() }
        web.frame = pageHost.bounds
        pageHost.addSubview(web)
        homeView.isHidden = web.url != nil
        if onNotchScreen, window.isOnActiveSpace { DuoMenu.shared.page = self } // Not another Space's (see rebuild).
        if field.currentEditor() == nil || !finding { field.stringValue = web.url?.absoluteString ?? "" }
        if addressBar.isHidden { window.makeFirstResponder(web) }
        updateProgress()
        refreshTabs()
        refreshStar()
        saveSession()
    }

    fileprivate func closeTab(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        let t = tabs.remove(at: i)
        if let u = t.web.url { closed.append(u) }
        t.watches = []
        t.web.stopLoading()
        t.web.removeFromSuperview()
        if tabs.isEmpty { openHome(in: newTab()); return } // The last tab closed leaves the home, not an empty desk.
        select(i < current ? current - 1 : min(current, tabs.count - 1))
    }

    private func reopenTab() {
        guard let u = closed.popLast() else { return NSSound.beep() }
        newTab().load(URLRequest(url: u))
    }

    // MARK: Bookmarks and the session

    @objc private func toggleBookmark() {
        guard let u = web.url, ["http", "https"].contains(u.scheme) else { return NSSound.beep() }
        showToast(DeskBookmarks.toggle(url: u.absoluteString, title: web.title ?? "") ? "북마크에 추가했습니다" : "북마크에서 뺐습니다")
        refreshStar()
    }

    private func refreshStar() {
        let kept = web.url.map { DeskBookmarks.has($0.absoluteString) } ?? false
        star?.image = NSImage(systemSymbolName: kept ? "star.fill" : "star", accessibilityDescription: "북마크")
        refreshSidebar()
    }

    func toggleSidebar() {
        let show = sidebar.isHidden
        if show { refreshSidebar(force: true); sidebar.alphaValue = 0; sidebar.isHidden = false }
        let w = sidebar.frame.width
        sidebar.frame.origin.x = show ? -w : 0
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25
            sidebar.animator().frame.origin.x = show ? 0 : -w
            sidebar.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in if !show { self?.sidebar.isHidden = true } })
    }

    private func refreshSidebar(force: Bool = false) {
        guard force || !sidebar.isHidden else { return }
        sidebarHost.rootView = DeskSidebar(
            tabs: tabList, current: current, bookmarks: DeskBookmarks.all(),
            pick: { [weak self] in self?.select($0) }, close: { [weak self] in self?.closeTab($0) },
            open: { [weak self] u in if let u = URL(string: u) { self?.web.load(URLRequest(url: u)) } })
    }

    private func saveSession() {
        guard let k = sessionKey else { return }
        let urls = tabs.compactMap { $0.web.url?.absoluteString }
        UserDefaults.standard.set(["tabs": urls, "current": web.url == nil ? urls.count - 1 : tabs[..<current].filter { $0.web.url != nil }.count], forKey: k)
    }

    /// The tabs this desktop had open last time, put back while it still holds only its first blank tab.
    private func restore() {
        guard let k = sessionKey, tabs.count == 1, web.url == nil else { return }
        guard let s = UserDefaults.standard.dictionary(forKey: k),
              let urls = (s["tabs"] as? [String])?.compactMap(URL.init(string:)), !urls.isEmpty else { return openHome(in: web) }
        for (i, u) in urls.enumerated() { (i == 0 ? web : newTab(front: false)).load(URLRequest(url: u)) }
        select(max(0, min(s["current"] as? Int ?? 0, tabs.count - 1)))
    }

    /// A tab with nothing in it opens the home address. Blank, it shows the wallpaper (the home), and a desktop left
    /// that way had the wallpaper across the menu bar's strip over every window, and coming in with it when the
    /// desktops slide. Without a home address it stays blank.
    private func openHome(in w: WKWebView) {
        if let u = DeskBrowser.home { w.load(URLRequest(url: u)) }
    }

    @objc private func pickTab(_ b: NSButton) { select(b.tag) }
    @objc private func closeTabButton(_ b: NSButton) { closeTab(b.tag) }
    @objc fileprivate func plusTab() { openHome(in: newTab()); revealAddress() }

    /// The tabs as the bar and the sidebar name them.
    fileprivate var tabList: [(title: String, icon: NSImage?)] {
        tabs.map { t in (t.web.title.flatMap { $0.isEmpty ? nil : $0 } ?? t.web.url?.host ?? "새 탭", t.icon) }
    }
    fileprivate var currentTab: Int { current }

    private func refreshTabs() {
        if DuoMenu.shared.page === self { DuoMenu.shared.tabStrip.show(tabList, current: current) }
        // Not typed in: the site's name, as Safari's compact tab shows it; the whole address once it is (revealAddress).
        if !finding, field.currentEditor() == nil { field.stringValue = web.url?.host ?? "" }
        tabStrip.subviews.forEach { $0.removeFromSuperview() }
        let gap: CGFloat = 4, plus: CGFloat = 26, n = CGFloat(tabs.count)
        let w = max(60, min(200, (tabStrip.bounds.width - plus - gap * n) / n))
        for (i, t) in tabs.enumerated() {
            let chip = NSView(frame: NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: 26))
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 7
            if i == current { chip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor }
            let title = t.web.title.flatMap { $0.isEmpty ? nil : $0 } ?? t.web.url?.host ?? "새 탭"
            let icon = (t.icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!).copy() as! NSImage
            icon.size = NSSize(width: 14, height: 14)
            let b = FirstClickButton(title: title, image: icon, target: self, action: #selector(pickTab(_:)))
            b.tag = i
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.alignment = .left
            b.font = .systemFont(ofSize: 12)
            b.cell?.lineBreakMode = .byTruncatingTail
            b.frame = NSRect(x: 6, y: 0, width: w - 28, height: 26)
            let x = FirstClickButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "탭 닫기")!, target: self, action: #selector(closeTabButton(_:)))
            x.tag = i
            x.isBordered = false
            x.frame = NSRect(x: w - 22, y: 5, width: 16, height: 16)
            chip.addSubview(b)
            chip.addSubview(x)
            tabStrip.addSubview(chip)
        }
        let p = FirstClickButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "새 탭")!, target: self, action: #selector(plusTab))
        p.isBordered = false
        p.frame = NSRect(x: min(n * (w + gap), tabStrip.bounds.width - plus), y: 0, width: plus, height: 26)
        tabStrip.addSubview(p)
        refreshSidebar()
    }

    // MARK: The pull-down bar

    /// Sizes the bar: the address row on top, then the tabs, or the suggestions while there are any.
    private func layoutBar() {
        guard let root = window.contentView else { return }
        if docked, let slot = field.superview?.superview, let cover = slot.window {
            // Just the suggestions, dropped from under the address in the notch island.
            let s = cover.convertToScreen(slot.convert(slot.bounds, to: nil))
            let w = max(s.width, 360), list = CGFloat(suggestions.count) * 28 + 4, h = list + 8
            addressBar.frame = NSRect(x: s.midX - w / 2 - window.frame.minX, y: s.minY - window.frame.minY - 16 - h, width: w, height: h)
            addressBar.subviews.first?.frame = addressBar.bounds // The tint.
            suggestionBox.frame = NSRect(x: 8, y: 6, width: w - 16, height: list - 4)
            (barRow.isHidden, tabStrip.isHidden, suggestionBox.isHidden) = (true, true, false)
            addressBar.alphaValue = 1
            addressBar.isHidden = suggestions.isEmpty
            return
        }
        barRow.isHidden = false
        let w = addressBar.frame.width
        let list: CGFloat = suggestions.isEmpty ? 30 : CGFloat(suggestions.count) * 28 + 4
        let h = 44 + list + 6
        addressBar.frame = NSRect(x: (root.bounds.width - w) / 2, y: root.bounds.height - topInset - 12 - h, width: w, height: h)
        addressBar.subviews.first?.frame = addressBar.bounds // The tint.
        barRow.frame = NSRect(x: 0, y: h - 44, width: w, height: 44)
        tabStrip.frame = NSRect(x: 8, y: 6, width: w - 16, height: 26)
        suggestionBox.frame = NSRect(x: 8, y: 6, width: w - 16, height: list - 4)
        tabStrip.isHidden = !suggestions.isEmpty
        suggestionBox.isHidden = suggestions.isEmpty
        refreshTabs()
    }

    private func refreshSuggestions() {
        suggestionBox.subviews.forEach { $0.removeFromSuperview() }
        let w = suggestionBox.bounds.width, kept = Set(DeskBookmarks.all().map(\.url))
        for (i, s) in suggestions.enumerated() {
            let b = FirstClickButton(title: "", target: self, action: #selector(pickSuggestion(_:)))
            b.tag = i
            b.isBordered = false
            b.alignment = .left
            b.cell?.lineBreakMode = .byTruncatingTail
            let t = NSMutableAttributedString(string: s.title.isEmpty ? s.url : s.title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
            if !s.title.isEmpty { t.append(NSAttributedString(string: "  " + s.url, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])) }
            t.insert(NSAttributedString(string: kept.contains(s.url) ? " ★ " : "  ", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemYellow]), at: 0) // Level with the address above.
            b.attributedTitle = t
            b.frame = NSRect(x: 0, y: suggestionBox.bounds.height - CGFloat(i + 1) * 28, width: w, height: 26)
            b.wantsLayer = true
            b.layer?.cornerRadius = 6
            if i == picked { b.layer?.backgroundColor = Brand.orangeNS.withAlphaComponent(0.35).cgColor }
            suggestionBox.addSubview(b)
        }
    }

    private func setSuggestions(_ list: [DeskHistory.Entry]) {
        suggestions = list
        picked = -1
        layoutBar()
        refreshSuggestions()
    }

    /// Whether that view is one of the suggestions dropped under the address.
    fileprivate func suggests(in v: NSView) -> Bool { v.isDescendant(of: suggestionBox) }

    @objc private func pickSuggestion(_ b: NSButton) {
        field.stringValue = suggestions[b.tag].url
        go(field)
    }

    /// Slides the address bar down into view and puts the cursor in it, the address selected.
    func revealAddress() {
        finding = false
        field.placeholderString = "주소 또는 검색어"
        field.stringValue = web.url?.absoluteString ?? ""
        showBar()
        if web.url == nil { setSuggestions(DeskHistory.suggest("")) } // A blank tab offers the bookmarks.
    }

    private func showBar() {
        NSApp.activate(ignoringOtherApps: true) // Andeville is an accessory app: typing needs it in front.
        if docked, let cover = field.window {
            DuoMenu.shared.typing = true // First: the bar's panel takes the keyboard only while typed in.
            cover.makeKeyAndOrderFront(nil)
            cover.makeFirstResponder(field)
            field.selectText(nil)
            setSuggestions([])
            return
        }
        window.makeKeyAndOrderFront(nil)
        setSuggestions([])
        if addressBar.isHidden {
            addressBar.alphaValue = 0
            addressBar.isHidden = false
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; addressBar.animator().alphaValue = 1 }
        }
        window.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func hideAddress() {
        finding = false
        setSuggestions([])
        if docked {
            field.window?.makeFirstResponder(nil) // The cover's own: the field stops editing there, not only here.
            DuoMenu.shared.typing = false
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(web)
            return
        }
        guard !addressBar.isHidden else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; addressBar.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.addressBar.isHidden = true })
        window.makeFirstResponder(web)
    }

    @objc private func go(_ sender: NSTextField) {
        if finding { return find(backwards: NSEvent.modifierFlags.contains(.shift)) }
        guard let u = DeskBrowser.normalize(sender.stringValue) else { return }
        web.load(URLRequest(url: u))
        hideAddress()
    }

    func controlTextDidChange(_ n: Notification) {
        guard !finding else { return }
        setSuggestions(DeskHistory.suggest(field.stringValue))
    }

    /// The bar's field left for the page or another app: its suggestions go too (after a click on one has landed).
    func controlTextDidEndEditing(_ n: Notification) {
        guard docked else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.field.currentEditor() == nil else { return }
            self.setSuggestions([])
            self.field.stringValue = self.web.url?.host ?? ""
            DuoMenu.shared.typing = false
        }
    }

    /// ↑/↓ walk the suggestions (the field takes the one picked), Escape folds the bar away.
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)): hideAddress()
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !suggestions.isEmpty else { return false }
            let down = sel == #selector(NSResponder.moveDown(_:))
            picked = max(0, min(suggestions.count - 1, picked + (down ? 1 : -1)))
            textView.string = suggestions[picked].url
            refreshSuggestions()
        default: return false
        }
        return true
    }

    // MARK: Find in page

    private var lastFind = ""

    private func startFind() {
        finding = true
        field.placeholderString = "페이지에서 찾기"
        field.stringValue = lastFind
        showBar()
        finding = true // showBar clears suggestions, not the mode.
    }

    /// The next (⇧: previous) match, wrapping; the page scrolls to it and selects it. A beep when there is none.
    private func find(backwards: Bool) {
        if finding { lastFind = field.stringValue }
        guard !lastFind.isEmpty else { return startFind() }
        let c = WKFindConfiguration()
        c.backwards = backwards
        c.wraps = true
        web.find(lastFind, configuration: c) { r in if !r.matchFound { NSSound.beep() } }
    }

    // MARK: Buttons

    private func button(_ symbol: String, _ action: Selector) -> NSButton {
        let b = FirstClickButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: action)
        b.bezelStyle = .texturedRounded
        return b
    }

    func press(_ a: DuoPad.Action) {
        switch a {
        case .back: back()
        case .forward: forward()
        case .reload: reload()
        case .home: home()
        case .downloads: NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
        case .share: share()
        case .newTab: plusTab()
        case .tabs: toggleSidebar()
        }
    }

    /// The share sheet for the page, opened by the rail's button (at the window's right, by its foot).
    private func share() {
        guard let u = web.url, let root = window.contentView else { return NSSound.beep() }
        NSSharingServicePicker(items: [u]).show(relativeTo: NSRect(x: root.bounds.maxX - DuoRail.width, y: 150, width: 1, height: 1),
                                                of: root, preferredEdge: .minX)
    }
    @objc private func back() { web.goBack() }
    @objc private func forward() { web.goForward() }
    @objc private func reload() { web.reload() }
    @objc private func home() {
        if let u = DeskBrowser.home { web.load(URLRequest(url: u)) } else { homeView.isHidden = false; field.stringValue = "" }
    }

    /// The wallpaper cut to fill `size` (points).
    static func homeBackground(_ url: URL, size points: CGSize, scale: CGFloat) -> NSImage? {
        let size = CGSize(width: points.width * scale, height: points.height * scale) // Worked in pixels.
        guard var img = CIImage(contentsOf: url), size.width > 0, size.height > 0 else { return nil }
        let k = max(size.width / img.extent.width, size.height / img.extent.height) // Aspect fill, then centre crop.
        img = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let crop = CGRect(x: img.extent.midX - size.width / 2, y: img.extent.midY - size.height / 2, width: size.width, height: size.height)
        img = img.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        guard let cg = CIContext().createCGImage(img, from: CGRect(origin: .zero, size: size)) else { return nil }
        return NSImage(cgImage: cg, size: points)
    }

    // MARK: Loading

    /// The accent line under the band, as wide as the load is far along; gone once it is done.
    private func updateProgress() {
        let w = window.contentView?.bounds.width ?? 0
        progress.isHidden = !web.isLoading
        progress.frame.size.width = w * web.estimatedProgress
    }

    private func showToast(_ text: String) {
        guard let root = window.contentView else { return }
        toast.stringValue = text
        let w = min(root.bounds.width - 40, toast.intrinsicContentSize.width + 32)
        toast.frame = NSRect(x: (root.bounds.width - w) / 2, y: 40, width: w, height: 30)
        toast.isHidden = false
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.toast.isHidden = true }
    }

    func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
        guard w === web else { return }
        if !finding, field.currentEditor() == nil { field.stringValue = w.url?.host ?? "" } // The site's name, as Safari's compact tab.
        homeView.isHidden = true
        refreshStar()
        saveSession()
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        // Loaded and drawn: a page on a desktop not on show need not go on drawing (`keepDrawing`).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.keepDrawing() }
        guard let url = w.url, ["http", "https"].contains(url.scheme) else { return }
        DeskHistory.add(url: url.absoluteString, title: w.title ?? "")
        // The page's own icon, or the site's /favicon.ico.
        w.evaluateJavaScript("(document.querySelector('link[rel~=\"icon\"]') || {}).href || ''") { [weak self] r, _ in
            let s = r as? String ?? ""
            guard let icon = URL(string: s.isEmpty ? "\(url.scheme!)://\(url.host ?? "")/favicon.ico" : s) else { return }
            URLSession.shared.dataTask(with: icon) { d, _, _ in
                guard let img = d.flatMap(NSImage.init(data:)) else { return }
                DispatchQueue.main.async {
                    guard let self, let t = self.tabs.first(where: { $0.web === w }) else { return }
                    t.icon = img
                    self.refreshTabs()
                }
            }.resume()
        }
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { showError(w, e) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { showError(w, e) }

    /// A page saying what went wrong, with a button to try again. Not for loads that were cancelled or became downloads.
    private func showError(_ w: WKWebView, _ e: Error) {
        let ns = e as NSError
        if ns.code == NSURLErrorCancelled || (ns.domain == "WebKitErrorDomain" && ns.code == 102) { return } // 102: turned into a download.
        let url = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String ?? w.url?.absoluteString ?? ""
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let html = """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>페이지를 열 수 없음</title>
        <style>body{font:15px -apple-system,sans-serif;display:grid;place-items:center;height:90vh;margin:0;text-align:center}
        h1{font-size:22px;margin:0 0 8px}p{color:GrayText;max-width:520px;margin:0 auto 18px;word-break:break-all}
        button{font:inherit;padding:7px 18px;border-radius:8px;border:0;background:AccentColor;color:white}</style>
        <div><h1>페이지를 열 수 없습니다</h1><p>\(esc(ns.localizedDescription))<br>\(esc(url))</p>
        <button data-u="\(esc(url))" onclick="location.href=this.dataset.u">다시 시도</button></div>
        """
        w.loadHTMLString(html, baseURL: URL(string: url))
    }

    /// target=_blank links and window.open open in a new tab.
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        newTab(config: c)
    }

    /// window.close() from a page closes its tab.
    func webViewDidClose(_ w: WKWebView) {
        if let i = tabs.firstIndex(where: { $0.web === w }) { closeTab(i) }
    }

    // MARK: Page dialogs (without these WKWebView drops alert/confirm/prompt and <input type=file> does nothing)

    private func panel(_ text: String, buttons: [String], field: String? = nil) -> (Bool, String?) {
        let a = NSAlert()
        a.messageText = text
        buttons.forEach { a.addButton(withTitle: $0) }
        let input = field.map { v -> NSTextField in let f = NSTextField(string: v); f.frame.size.width = 260; return f }
        a.accessoryView = input
        let ok = a.runModal() == .alertFirstButtonReturn
        return (ok, input?.stringValue)
    }

    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        _ = panel(m, buttons: ["확인"]); completionHandler()
    }

    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(panel(m, buttons: ["확인", "취소"]).0)
    }

    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText d: String?, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let (ok, s) = panel(p, buttons: ["확인", "취소"], field: d ?? "")
        completionHandler(ok ? s : nil)
    }

    func webView(_ w: WKWebView, runOpenPanelWith p: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let o = NSOpenPanel()
        o.allowsMultipleSelection = p.allowsMultipleSelection
        o.canChooseDirectories = p.allowsDirectories
        o.begin { completionHandler($0 == .OK ? o.urls : nil) }
    }

    /// Camera and microphone: macOS asks once for Andeville itself; each site is then asked like in Safari.
    func webView(_ w: WKWebView, requestMediaCapturePermissionFor o: WKSecurityOrigin, initiatedByFrame f: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(panel("\(o.host)에서 카메라/마이크를 사용하려고 합니다.", buttons: ["허용", "허용 안 함"]).0 ? .grant : .deny)
    }

    // MARK: Downloads

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // ⌘-click or a middle click on a link opens it in a tab behind this one, as in Safari.
        if a.navigationType == .linkActivated, a.modifierFlags.contains(.command) || a.buttonNumber == 4, a.targetFrame?.isMainFrame != false {
            newTab(front: false).load(a.request)
            return decisionHandler(.cancel)
        }
        decisionHandler(a.shouldPerformDownload ? .download : .allow)
    }

    /// Anything the page can't show, or the server marks as an attachment, is saved instead.
    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = (r.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        decisionHandler(r.canShowMIMEType && !attachment ? .allow : .download)
    }

    func webView(_ w: WKWebView, navigationAction a: WKNavigationAction, didBecome d: WKDownload) { d.delegate = self }
    func webView(_ w: WKWebView, navigationResponse r: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self }

    /// Into ~/Downloads under the server's name, numbered when that name is taken.
    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename name: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var u = dir.appendingPathComponent(name), n = 1
        while FileManager.default.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        downloads[d] = u
        showToast("다운로드 중: \(u.lastPathComponent)")
        completionHandler(u)
    }

    func downloadDidFinish(_ d: WKDownload) {
        guard let u = downloads.removeValue(forKey: d) else { return }
        // Bounces the Downloads stack in the Dock, as Safari's do.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: u.path)
        showToast("다운로드 완료: \(u.lastPathComponent)")
    }

    func download(_ d: WKDownload, didFailWithError e: Error, resumeData: Data?) {
        let name = downloads.removeValue(forKey: d)?.lastPathComponent ?? ""
        showToast("다운로드 실패: \(name)")
    }
}

// MARK: - Duo style (화면 모드 › 아이폰 듀오)

/// Which ink the Duo layout's bare text and symbols take, part by part: the kit's Primary for a light background
/// (#1a1a1a) over a light page, its Primary for a dark one (#f5f5f5) over a dark page, and the system theme's when
/// the page there is in between. So nothing goes the same colour as what is behind it.
/// ponytail: one for every screen, read from the notch screen's page; per screen if pages on other screens differ.
final class DuoTone: ObservableObject {
    static let shared = DuoTone()
    /// True: dark ink (the page is light there).
    @Published var status = false
    @Published var controls = false
    @Published var nav = false
    static func ink(_ dark: Bool) -> Color { Color(nsColor: nsInk(dark)) }
    static func nsInk(_ dark: Bool) -> NSColor { dark ? NSColor(white: 0x1a / 255, alpha: 1) : NSColor(white: 0xf5 / 255, alpha: 1) }

    /// Light page, dark ink; dark page, light ink; in between, the system theme (dark theme, light ink).
    static func darkInk(luminance l: CGFloat) -> Bool {
        if l > 0.62 { return true }
        if l < 0.38 { return false }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
    }

    private static let ci = CIContext()

    /// The page's average brightness in `rect` (web view points, from its top left), 0...1.
    static func luminance(of web: WKWebView, in rect: CGRect, done: @escaping (CGFloat) -> Void) {
        colour(of: web, in: rect) { done(0.2126 * $0.r + 0.7152 * $0.g + 0.0722 * $0.b) }
    }

    /// The page's average colour in `rect` (web view points, from its top left), sRGB 0...1.
    static func colour(of web: WKWebView, in rect: CGRect, done: @escaping ((r: CGFloat, g: CGFloat, b: CGFloat)) -> Void) {
        picture(of: web, in: rect) { done(average($0)) }
    }

    /// The page's ground in `rect`: the colour most of it has (not its text and lines mixed in, as the average is),
    /// and how much of it has that colour, 0...1.
    static func ground(of web: WKWebView, in rect: CGRect, done: @escaping ((r: CGFloat, g: CGFloat, b: CGFloat), CGFloat) -> Void) {
        picture(of: web, in: rect) { let m = most($0); done(m.colour, m.share) }
    }

    /// A small picture of the page in `rect` (web view points, from its top left).
    private static func picture(of web: WKWebView, in rect: CGRect, done: @escaping (CGImage) -> Void) {
        // A blank tab shows the home (the wallpaper, over the web view); the web view itself is blank white there,
        // which read as a light page and put dark ink on a dark wallpaper.
        // Only the home view, not the rail and bar drawn over it.
        if web.url == nil, let home = web.window?.contentView?.subviews.first(where: { $0 is NSImageView && !$0.isHidden }) {
            let r = web.convert(rect, to: home).intersection(home.bounds)
            guard !r.isEmpty, let rep = home.bitmapImageRepForCachingDisplay(in: r) else { return }
            home.cacheDisplay(in: r, to: rep)
            return rep.cgImage.map(done) ?? ()
        }
        let c = WKSnapshotConfiguration()
        c.rect = rect
        c.snapshotWidth = NSNumber(value: Double(max(rect.width / 4, 1))) // Small: only its colours are wanted.
        c.afterScreenUpdates = false
        web.takeSnapshot(with: c) { img, _ in
            guard let cg = img?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            done(cg)
        }
    }

    /// The colour most of the picture has: its pixels sorted into 32 steps a channel, and the fullest lot's own mean.
    private static func most(_ cg: CGImage) -> (colour: (r: CGFloat, g: CGFloat, b: CGFloat), share: CGFloat) {
        let w = min(cg.width, 256), h = min(cg.height, 16)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (average(cg), 0) }
        c.interpolationQuality = .none
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lots: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
        for i in 0..<(w * h) {
            let (r, g, b) = (Int(px[i * 4]), Int(px[i * 4 + 1]), Int(px[i * 4 + 2]))
            let key = (r >> 3) << 10 | (g >> 3) << 5 | b >> 3
            let lot = lots[key] ?? (0, 0, 0, 0)
            lots[key] = (lot.n + 1, lot.r + r, lot.g + g, lot.b + b)
        }
        guard let top = lots.values.max(by: { $0.n < $1.n }) else { return (average(cg), 0) }
        let n = CGFloat(top.n) * 255
        return ((CGFloat(top.r) / n, CGFloat(top.g) / n, CGFloat(top.b) / n), CGFloat(top.n) / CGFloat(w * h))
    }

    /// For the self-check: a dark strip with a quarter of it white (text) has the dark as its ground, not their mix.
    static func groundCheck() -> Bool {
        var px = [UInt8](repeating: 0, count: 40 * 8 * 4)
        for i in 0..<(40 * 8) { let v: UInt8 = i % 4 == 0 ? 255 : 16; (px[i * 4], px[i * 4 + 1], px[i * 4 + 2], px[i * 4 + 3]) = (v, v, v, 255) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: &px, width: 40, height: 8, bitsPerComponent: 8, bytesPerRow: 160, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let img = c.makeImage() else { return false }
        let g = most(img)
        return abs(g.colour.r - 16 / 255) < 0.01 && abs(g.colour.b - 16 / 255) < 0.01 && abs(g.share - 0.75) < 0.01
    }

    private static func average(_ cg: CGImage) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let src = CIImage(cgImage: cg)
        let avg = src.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: src.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        ci.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (CGFloat(px[0]) / 255, CGFloat(px[1]) / 255, CGFloat(px[2]) / 255)
    }

    /// Reads the page behind the bar, the status bar and the buttons. `bar` is the bar's height.
    func sample(_ web: WKWebView, bar h: CGFloat) {
        let w = web.bounds.width, tall = web.bounds.height, rail = DuoRail.width
        let parts: [(CGRect, ReferenceWritableKeyPath<DuoTone, Bool>)] = [
            (CGRect(x: w - rail, y: h, width: rail, height: 110), \.status),
            (CGRect(x: w - rail, y: h + DuoRail.navTop, width: rail, height: 102), \.nav),
            (CGRect(x: w - rail, y: tall - 260, width: rail, height: 260), \.controls), // The four buttons and their margin.
        ]
        for (rect, key) in parts {
            Self.luminance(of: web, in: rect) { [weak self] l in
                guard let self else { return }
                let dark = Self.darkInk(luminance: l)
                if self[keyPath: key] != dark { withAnimation(.easeInOut(duration: 0.3)) { self[keyPath: key] = dark } }
            }
        }
    }
}

/// The Duo style's notch: while the desk page is in front it grows down into an island holding the page's tabs,
/// Safari's own, the address in the front one. macOS's menu bar stays hidden meanwhile (`DuoMenuBarPin`).
final class DuoMenu: ObservableObject {
    static let shared = DuoMenu()
    private(set) var on = false
    /// Out of the notch: while the desk page is in front, the notch grows down into an island holding its tabs (`tabStrip`).
    private var bottom: NSPanel?
    /// The notch island is open (`DuoNotchTabs` follows it).
    @Published private(set) var tabsShown = false
    /// The notch screen's Duo page on show; its address field sits in the front tab of the notch island (`slot`).
    fileprivate weak var page: DeskFrame? { didSet { dock(); if let page { tabStrip.show(page.tabList, current: page.currentTab) } } }
    var pageWeb: WKWebView? { page?.web }
    let slot = DuoAddressSlot()
    /// The page's tabs in Safari's own tab bar, compact: the address (`slot`) is the tab in front, as in Safari.
    let tabStrip = DuoTabStrip()
    /// The address is being typed in (`DeskFrame.showBar` until its field lets go).
    var typing = false { didSet { updateSlot() } }
    private var toner: Timer?, deskWatch: AnyCancellable?
    private var letGo: [Any] = []
    private weak var islandShape: DuoNotchTabs?
    /// The island is folded: as the desk comes in front, and after a press elsewhere or the cursor leaving it. The
    /// cursor on the notch opens it; typing the address (four fingers down with the desk on show, ⌘L) has it open meanwhile.
    private var letGone = true { didSet { if letGone != oldValue { updateSlot() } } }
    /// The island goes back into the notch: the address stops being typed in. (A press elsewhere, four fingers up.)
    func fold() {
        bottom?.makeFirstResponder(nil)
        typing = false
        (letGone, visited, sent) = (true, false, true)
    }

    /// Where the cursor is, 60 times a second: on the notch or the open island it opens an island that was let go, and
    /// once it has been on it, the island folds back 0.05 s after it is off it (a brush past the edge is let by),
    /// without waiting for a press elsewhere. Not while the address is typed in.
    func track(_ p: NSPoint, onNotch: Bool) {
        if !onNotch { sent = false } else if sent { return } // Sent back with the cursor on the notch: not out again until it has left.
        if onNotch || (tabsShown && bottom.map { $0.frame.contains(p) && p.y >= $0.frame.minY + DuoNotchTabs.bounce } == true) {
            (visited, leftAt) = (true, nil)
            if letGone { letGone = false }
        } else if visited, tabsShown, !typing {
            let now = CACurrentMediaTime()
            if let t = leftAt { if now - t >= 0.05 { (letGone, visited, leftAt) = (true, false, nil) } } else { leftAt = now }
        } else {
            leftAt = nil
        }
    }
    private var visited = false, leftAt: CFTimeInterval?, sent = false

    init() {
        // The main queue, not RunLoop.main, which waits out a click or a scroll being tracked: the island trailed it.
        deskWatch = DuoPad.shared.$desk.receive(on: DispatchQueue.main).sink { [weak self] desk in
            // The desk in front: only the desk, the notch as it is. Its tabs come when asked for: the cursor on the
            // notch, or four fingers down once more (`DeskBrowser.fourFingersDown`, the address ready for typing).
            if desk { self?.letGone = true }
            self?.updateSlot()
        }
        // Another app in front: typing ends there and then, so the notch folds back at once instead of staying open for it.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier != getpid() else { return }
            self.bottom?.makeFirstResponder(nil)
            self.typing = false
        }
        // A press anywhere but the island and the suggestions under it lets the island go: the address stops being
        // typed in and the notch folds back, on the page, the rail, the Dock, none of which bring another app in front.
        let away: (NSEvent) -> Void = { [weak self] e in
            guard let self, self.tabsShown, e.window !== self.bottom else { return }
            if let hit = e.window?.contentView?.hitTest(e.locationInWindow), self.page?.suggests(in: hit) == true { return }
            self.fold()
        }
        letGo = [NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: away) as Any,
                 NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { away($0); return $0 } as Any]
    }

    /// Lends the page's field to the bar. A page on another desktop gets it back when it is on show again.
    private func dock() {
        guard let f = page?.field, f.superview !== slot.fieldHost else { return }
        slot.fieldHost.subviews.forEach { $0.removeFromSuperview() }
        f.removeFromSuperview()
        f.autoresizingMask = []
        slot.fieldHost.addSubview(f)
        slot.needsLayout = true
    }

    /// The notch opens into its tabs while the desk page is in front (or its address is typed in).
    func updateSlot() {
        // Only once asked for: a field that took the keyboard on its own (the island's first key view) gives it back.
        if !typing, let f = page?.field, f.currentEditor() != nil, f.window === bottom { bottom?.makeFirstResponder(nil) }
        guard let bottom else { return }
        let tabs = on && (typing || (DuoPad.shared.desk && !letGone))
        guard tabs != tabsShown else { return }
        tabsShown = tabs
        islandShape?.set(open: tabs)
        bottom.ignoresMouseEvents = !tabs
    }

    func set(on: Bool) {
        self.on = on
        bottom?.orderOut(nil)
        bottom = nil
        toner?.invalidate()
        toner = nil
        guard on, let screen = notchScreen() else { return }
        let f = screen.frame, notch = notchRect(in: f, notch: notchSize(of: screen))
        let bar = notch.height // The band the rail starts under (`DuoTone.sample`).
        // The notch island: the notch grown down round the tabs, its top fillets on the screen's edge as the notch's.
        let ear = Store.notchEar, open = DuoNotchTabs.size(notch: notch.size, screen: f.width)
        let b = DuoNotchBar(contentRect: NSRect(x: f.midX - open.width / 2 - ear, y: f.maxY - open.height - DuoNotchTabs.bounce,
                                                width: open.width + ear * 2, height: open.height + DuoNotchTabs.bounce),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        b.animationBehavior = .none
        b.isOpaque = false
        b.backgroundColor = .clear
        b.hasShadow = false
        b.ignoresMouseEvents = true
        b.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2) // Over the menu bar, under the notch's own shape (NotchBase).
        b.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let island = DuoNotchTabs(notch: notch.size, open: open)
        island.tabs = tabStrip
        islandShape = island
        let content = NSView(frame: NSRect(origin: .zero, size: b.frame.size)) // Not the hosting view: it is flipped.
        island.frame = content.bounds
        tabStrip.frame = NSRect(x: ear + DuoNotchTabs.inset, y: DuoNotchTabs.inset + DuoNotchTabs.bounce, width: open.width - DuoNotchTabs.inset * 2, height: DuoTabStrip.height)
        tabStrip.alphaValue = 0
        content.addSubview(island)
        content.addSubview(tabStrip)
        b.contentView = content
        b.orderFrontRegardless()
        bottom = b
        tabsShown = false
        if let page { tabStrip.show(page.tabList, current: page.currentTab) } // The bar is in a window now: its buttons can be made.
        updateSlot()
        // Under other windows WebKit stops drawing the page and the ink would read it stale; keep it drawing (WebKit's
        // own switch, not public API, hence the check).
        let keepDrawing = Selector(("_setWindowOcclusionDetectionEnabled:"))
        if let web = pageWeb, web.responds(to: keepDrawing) { web.setValue(false, forKey: "windowOcclusionDetectionEnabled") } // KVC finds the _set… setter.
        toner = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            if let web = self?.pageWeb, web.window?.occlusionState.contains(.visible) == true { DuoTone.shared.sample(web, bar: bar) }
        }
    }
}

/// The notch island's panel: key only while its address is typed in, so Andeville coming forward does not put the
/// cursor in the field on its own (it is the panel's first key view). Borderless, so it must be told it may take typing.
final class DuoNotchBar: NSPanel {
    override var canBecomeKey: Bool { DuoMenu.shared.typing }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        DeskWindow.keyEquivalent(e, from: self) { DuoMenu.shared.page?.window.onCommand?($0, $1) ?? false } ?? super.performKeyEquivalent(with: e)
    }
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { r } // Up in the menu bar, where it is put.
}

/// The notch island's shape: the notch grown down round the tabs. On a layer, its spring worked out ahead into
/// keyframes that Core Animation plays in the render server: drawn frame by frame on the main thread (SwiftUI), it
/// came out in jumps, the main thread being busy just as the desk comes forward (the window list, the keyboard taken).
final class DuoNotchTabs: NSView {
    /// Room round the tabs, inside the island.
    static let inset: CGFloat = 8

    /// The open island: under the notch the tabs, at most Safari's compact width.
    static func size(notch: CGSize, screen: CGFloat) -> CGSize {
        CGSize(width: max(notch.width, min(300, screen * 0.25)), height: notch.height + DuoTabStrip.height + inset * 2)
    }

    /// Room under the open island for its spring to overshoot into, instead of being cut off at the window's edge.
    static let bounce: CGFloat = 10

    private let shape = CAShapeLayer()
    private let notch: CGSize, open: CGSize
    /// What the island holds (the tabs): it comes out of the notch with the shape, on the same spring.
    weak var tabs: NSView?
    /// The spring under way: where it started, how fast it was going there, and when. Nil at rest.
    private var run: (spring: Spring, start: CFTimeInterval)?
    /// How far open the island is at rest, 0 the notch and 1 the island.
    private var at: Double = 0

    /// A spring as SwiftUI's spring(response:dampingFraction:), from `from` moving at `speed` (per second) to `to`.
    struct Spring {
        let from: Double, to: Double, speed: Double, response: Double, damping: Double

        /// Where it is and how fast it moves, `t` seconds in.
        func at(_ t: Double) -> (place: Double, speed: Double) {
            let w = 2 * Double.pi / response, z = min(damping, 1), y0 = from - to
            if z >= 1 {
                let c = speed + w * y0, e = exp(-w * t)
                return (to + e * (y0 + c * t), e * (c - w * (y0 + c * t)))
            }
            let wd = w * (1 - z * z).squareRoot(), b = (speed + z * w * y0) / wd, e = exp(-z * w * t)
            return (to + e * (y0 * cos(wd * t) + b * sin(wd * t)), e * ((b * wd - z * w * y0) * cos(wd * t) - (y0 * wd + z * w * b) * sin(wd * t)))
        }
    }

    init(notch: CGSize, open: CGSize) {
        (self.notch, self.open) = (notch, open)
        super.init(frame: .zero)
        wantsLayer = true
        shape.fillColor = NSColor.black.cgColor
        shape.isGeometryFlipped = true // The shape hangs from the top edge.
        layer?.addSublayer(shape)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        shape.frame = bounds
        if run == nil { shape.path = path(at) }
    }

    private func path(_ k: Double) -> CGPath {
        let ear = Store.notchEar, k = CGFloat(k)
        return IslandShape(width: notch.width + (open.width - notch.width) * k, height: notch.height + (open.height - notch.height) * k,
                           radius: ear + (24 - ear) * min(max(k, 0), 1), ear: ear, minWidth: notch.width, maxWidth: open.width).path(in: bounds).cgPath
    }

    /// The tabs at that point of the way: they fade in over the second half, small and tucked up toward the notch at
    /// first, so they read as coming out of it rather than appearing in place.
    private func look(_ k: Double, of v: NSView) -> (opacity: Float, transform: CATransform3D) {
        let scale = CGFloat(0.86 + 0.14 * min(max(k, 0), 1.08)), up = CGFloat(1 - min(max(k, 0), 1)) * 14
        let x = v.bounds.midX, y = v.isFlipped ? 0 : v.bounds.height // Grown from the middle of their top edge.
        var t = CATransform3DMakeTranslation(-x, -y, 0)
        t = CATransform3DConcat(t, CATransform3DMakeScale(scale, scale, 1))
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(x, y + (v.isFlipped ? -up : up), 0))
        return (Float(min(max((k - 0.4) / 0.5, 0), 1)), t)
    }

    /// Opens with a little bounce, folds back at once. A run still under way is taken over where it is and at the
    /// speed it has, so turning round midway (the cursor off the notch and back) has no jump and no stop in it.
    func set(open on: Bool) {
        let now = CACurrentMediaTime()
        var speed = 0.0
        if let r = run { (at, speed) = r.spring.at(now - r.start) }
        let spring = Spring(from: at, to: on ? 1 : 0, speed: speed, response: on ? 0.42 : 0.24, damping: on ? 0.78 : 1)
        let length = on ? 0.9 : 0.45, steps = (0...Int(length * 60)).map { spring.at(Double($0) / 60).place }
        run = (spring, now)
        at = spring.to
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let grow = CAKeyframeAnimation(keyPath: "path")
        grow.values = steps.map(path)
        grow.duration = length
        shape.path = path(spring.to)
        shape.add(grow, forKey: "island")
        if let tabs, let l = tabs.layer {
            let looks = steps.map { look($0, of: tabs) }
            let fade = CAKeyframeAnimation(keyPath: "opacity"), move = CAKeyframeAnimation(keyPath: "transform")
            fade.values = looks.map { NSNumber(value: $0.opacity) }
            move.values = looks.map { NSValue(caTransform3D: $0.transform) }
            (fade.duration, move.duration) = (length, length)
            tabs.alphaValue = on ? 1 : 0
            l.add(fade, forKey: "island.fade")
            l.add(move, forKey: "island.move")
        }
        CATransaction.commit()
        // At rest once the run is over, unless another has taken it over since.
        DispatchQueue.main.asyncAfter(deadline: .now() + length) { [weak self] in
            if let self, let r = self.run, r.start == now { self.run = nil }
        }
    }
}

/// The front tab in the notch island, as Safari's compact tab: the notch page's address, a magnifier before it and
/// reload at its end, on the tab's own glass. The field itself is the page's own (`DeskFrame.field`), lent to the bar
/// (`DuoMenu.page`), so typing, suggestions, ⌘F and Escape work as in the pull-down bar.
final class DuoAddressSlot: NSView {
    let fieldHost = NSView()
    private let glyph = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
    private let reload = NSButton()

    init() {
        super.init(frame: .zero)
        glyph.contentTintColor = .secondaryLabelColor
        reload.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "새로고침")
        reload.isBordered = false
        reload.contentTintColor = .secondaryLabelColor
        reload.target = self
        reload.action = #selector(reloadPage)
        reload.toolTip = "새로고침"
        [glyph, fieldHost, reload].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        glyph.frame = NSRect(x: 10, y: (h - 16) / 2, width: 16, height: 16)
        reload.frame = NSRect(x: bounds.width - 30, y: (h - 20) / 2, width: 20, height: 20)
        fieldHost.frame = NSRect(x: 32, y: (h - 20) / 2, width: max(bounds.width - 32 - 34, 0), height: 20)
        fieldHost.subviews.forEach { $0.frame = fieldHost.bounds }
    }

    /// Not typed in yet: a click anywhere but reload starts typing (`revealAddress`), as on Safari's compact tab. The
    /// field cannot take it itself: its panel is key only while typed in (`DuoNotchBar`).
    override func hitTest(_ p: NSPoint) -> NSView? {
        guard let hit = super.hitTest(p) else { return nil }
        return DuoMenu.shared.typing || hit === reload ? hit : self
    }
    override func mouseDown(with e: NSEvent) { DuoMenu.shared.page?.revealAddress() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true } // The first click types; the panel is never key before.

    @objc private func reloadPage() { DuoMenu.shared.page?.press(.reload) }
}

/// In the notch island: the notch page's tabs in Safari's own tab bar (`UnifiedTabBar` from Safari.framework, compact,
/// as Safari's "Compact" tab layout), clicked and closed (its ✕ on hover) there; new tabs come from the rail's +. The tab in front holds
/// the address (`DuoAddressSlot`), as Safari's compact tab does. Not public API: loaded and looked up by name, and
/// without it the bar stays empty.
final class DuoTabStrip: NSView {
    static let height: CGFloat = 44
    private static let safari: Void = { dlopen("/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari", RTLD_NOW) }()
    private let bar: NSView? = {
        _ = DuoTabStrip.safari
        guard let c = NSClassFromString("UnifiedTabBar") as? NSView.Type else { return nil }
        typealias Init = @convention(c) (AnyObject, Selector, Int) -> NSView
        let sel = NSSelectorFromString("initWithStyle:")
        guard let imp = class_getMethodImplementation(c, sel) else { return nil }
        // 0 compact, 2 separate (UnifiedTabBarLayout); passed as a plain integer, not boxed by perform(_:with:).
        return unsafeBitCast(imp, to: Init.self)(c.perform(NSSelectorFromString("alloc")).takeUnretainedValue(), sel, 0)
    }()
    private var items: [NSObject] = []

    init() {
        super.init(frame: .zero)
        guard let bar else { return }
        bar.setValue(self, forKey: "delegate")
        addSubview(bar)
        appearance = NSAppearance(named: .darkAqua) // On the island's black.
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        bar?.frame = bounds
    }

    func show(_ tabs: [(title: String, icon: NSImage?)], current: Int) {
        guard let bar, bar.window != nil, let itemClass = NSClassFromString("UnifiedTabBarItem") as? NSObject.Type,
              let listClass = NSClassFromString("UnifiedTabBarItemList") as? NSObject.Type else { return }
        while items.count > tabs.count { items.removeLast() }
        while items.count < tabs.count { items.append(itemClass.init()) }
        for (item, tab) in zip(items, tabs) {
            if item.value(forKey: "label") as? String != tab.title { item.setValue(tab.title, forKey: "label") }
            item.setValue(tab.icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil), forKey: "image")
        }
        // The one in front first (read only: its ivar), then the list, whose setter lays the buttons out with it.
        if items.indices.contains(current) { bar.setValue(items[current], forKey: "activeTabBarItem") }
        let list = listClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
            .perform(NSSelectorFromString("initWithTabBarItems:"), with: items).takeUnretainedValue()
        bar.perform(NSSelectorFromString("setTabBarItemList:"), with: list)
    }

    private func index(_ item: Any?) -> Int? { items.firstIndex { $0 === item as AnyObject } }

    // UnifiedTabBarDelegate (Safari's private protocol; every required method is here, or a call to a missing one throws).
    @objc(unifiedTabBar:activateTabBarViewItem:) func activate(_ b: Any, _ item: Any) {
        guard let i = index(item), let page = DuoMenu.shared.page else { return }
        if i == page.currentTab { page.revealAddress() } else { page.select(i) }
    }
    @objc(unifiedTabBar:canCloseTabBarItem:) func canClose(_ b: Any, _ item: Any) -> Bool { true }
    @objc(unifiedTabBar:closeTabBarItem:) func close(_ b: Any, _ item: Any) { if let i = index(item) { DuoMenu.shared.page?.closeTab(i) } }
    @objc(unifiedTabBar:unifiedFieldForUnifiedTabBarItem:) func field(_ b: Any, _ item: Any) -> Any? {
        return DuoMenu.shared.slot
    }
    @objc(unifiedTabBar:unifiedFieldIconForUnifiedTabBarItem:) func fieldIcon(_ b: Any, _ item: Any) -> Any? { nil }
    @objc(unifiedTabBar:unifiedFieldApplyFaviconBacking:insets:) func favicon(_ b: Any, _ c: Any?, _ e: NSEdgeInsets) {}
    @objc(selectedTabBarViewItemAfterClosingCurrentTabInUnifiedTabBar:) func afterClose(_ b: Any) -> Any? { nil } // The page picks (`closeTab`).
    @objc(unifiedTabBarIsInFrontmostWindow:) func frontmost(_ b: Any) -> Bool { true } // Drawn as in a key window, though the bar never is.
    @objc(unifiedTabBarShouldOnlyShowActiveTab:) func onlyActive(_ b: Any) -> Bool { false }
    @objc(unifiedTabBarShouldAnimateTabSelection:) func animateSelection(_ b: Any) -> Bool { true }
    @objc(canShowTabHoverPreviewForUnifiedTabBar:) func hoverPreview(_ b: Any) -> Bool { false }
    @objc(unifiedTabBar:browserTabIconIsMonogramForUnifiedTabBarViewItem:) func monogram(_ b: Any, _ i: Any) -> Bool { false }
    @objc(unifiedTabBar:backgroundColorForActiveTab:isVibrant:) func activeColor(_ b: Any, _ a: Bool, _ v: Bool) -> Any? { nil }
    @objc(dragBackgroundColorForUnifiedTabBar:) func dragColor(_ b: Any) -> Any? { NSColor.clear }
    @objc(highlightBackgroundColorForUnifiedTabBar:) func highlightColor(_ b: Any) -> Any? { NSColor.quaternaryLabelColor }
    @objc(unifiedTabBar:menuForTabBarViewItem:event:) func menu(_ b: Any, _ i: Any, _ e: Any) -> Any? { nil }
    @objc(unifiedTabBar:tabPreviewDataSourceForTabBarViewItem:) func preview(_ b: Any, _ i: Any) -> Any? { nil }
    @objc(unifiedTabBar:acceptDrop:index:) func acceptDrop(_ b: Any, _ i: Any, _ x: UInt) -> Bool { false }
    @objc(unifiedTabBar:acceptTabDrop:index:targetClusterID:) func acceptTabDrop(_ b: Any, _ i: Any, _ x: UInt, _ c: Any?) -> Bool { false }
    @objc(unifiedTabBar:validateDrop:) func validateDrop(_ b: Any, _ i: Any) -> UInt { 0 }
    @objc(unifiedTabBar:validateTabDrop:) func validateTabDrop(_ b: Any, _ i: Any) -> UInt { 0 }
    @objc(unifiedTabBar:canDetachTabBarViewItem:) func canDetach(_ b: Any, _ i: Any) -> Bool { false }
    @objc(unifiedTabBar:canDragToPinTab:) func canPin(_ b: Any, _ i: Any) -> Bool { false }
    @objc(unifiedTabBar:dragImageForDraggableTabBarViewItem:withBookmark:) func dragImage(_ b: Any, _ i: Any, _ x: Any) -> Any? { nil }
    @objc(unifiedTabBar:bookmarkForDraggableTabBarViewItem:) func bookmark(_ b: Any, _ i: Any) -> Any? { nil }
    @objc(unifiedTabBar:draggableTabBarViewItemForTabBarItem:) func draggable(_ b: Any, _ i: Any) -> Any? { nil }
    @objc(unifiedTabBar:destinationWindowForDetachedTabBarItems:withActiveTabIndex:isMovingCluster:) func detachWindow(_ b: Any, _ i: Any, _ x: UInt, _ m: Bool) -> Any? { nil }
    @objc(unifiedTabBar:detachedWindowImageForDraggedTabBarViewItem:completion:) func detachImage(_ b: Any, _ i: Any, _ c: Any) {}
    @objc(unifiedTabBar:didBeginDraggingTab:) func beganDrag(_ b: Any, _ i: Any) {}
    @objc(unifiedTabBar:didFinishTransitionAnimationForWindow:) func didFinish(_ b: Any, _ w: Any) {}
    @objc(unifiedTabBar:didMoveTabBarViewItems:toIndex:isChangingPinning:targetClusterID:isMovingCluster:) func didMove(_ b: Any, _ i: Any, _ x: UInt, _ p: Bool, _ c: Any?, _ m: Bool) -> Any? { nil }
    @objc(unifiedTabBar:didUpdateSelectedTabs:) func didUpdateSelected(_ b: Any, _ i: Any) {}
    @objc(didFinishAnimatingButtonLayoutInUnifiedTabBar:) func didAnimate(_ b: Any) {}
    @objc(unifiedTabBarDidUpdateLayout:) func didLayout(_ b: Any) {}
    @objc func unifiedTabBarResignFirstResponder() {}
    @objc(unifiedTabBarSidecarTouchDidTapAlreadyActiveTab:) func sidecarTap(_ b: Any) {}
    @objc(unifiedTabBarSidecarTouchInteractionDidChange:) func sidecarChange(_ b: Any) {}
}

/// The Duo style's right edge, after the iPhone Duo iOS 27 UI Kit's Pane controls (Trailing): the status bar (time
/// over Wi-Fi) at the top and the buttons at the bottom, pushed apart. The middle is the real macOS Dock,
/// stood on the right for it (`DuoDockPin`); the column lines up on the Dock's middle, following it live.
/// This is the status bar; the buttons are `DuoPadView`. Each floats over every app, in a panel of its own (`DuoPad`).
struct DuoRail: View {
    /// The kit's pane: 84 wide, 24 in from its leading edge and 12 from its trailing one, 24 top and bottom.
    static let width: CGFloat = 84
    /// The status bar's panel is wider, so its blur can fade out past the pane's edge.
    static let hostWidth: CGFloat = 160
    /// The rail's screen.
    var display: CGDirectDisplayID = 0
    /// The band at the screen's top the rail starts under. The panel runs up behind it, so the blur has no cut edge.
    var top: CGFloat = 0
    /// The blur's reach from the status bar's middle.
    static let reach: CGFloat = 56
    /// From the band to the back and forward buttons' top: the status bar's 24, its 69, and 22 under the ring.
    static let navTop: CGFloat = 24 + 69 + 22
    @ObservedObject private var tone = DuoTone.shared
    @ObservedObject private var screens = DuoScreens.shared
    /// From the screen's right edge to the column's middle: the Dock's middle when it is on the right, else the kit's 36.
    static func center(on display: CGDirectDisplayID) -> CGFloat {
        let s = NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display }
        let dock = s.map { $0.frame.maxX - $0.visibleFrame.maxX } ?? 0
        return dock > 0 ? dock / 2 : 36
    }

    var body: some View {
        VStack(spacing: 7) { // Measured off the iPhone Duo simulator (iOS 27.3), as the buttons are.
            TimelineView(.everyMinute) { t in
                Text(t.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute()).font(.system(size: 16, weight: .semibold))
            }
            DuoRing()
        }
        .foregroundStyle(DuoTone.ink(tone.status))
        .frame(width: 44)
        // Wider than the rail: the blur thins out all round. Over it a breath of the ink's opposite, thinning the same
        // way, so the time reads over a window as bright (or dark) as the ink.
        .background(ZStack {
            DuoHalo()
            RadialGradient(colors: [(tone.status ? Color.white : .black).opacity(0.2), .clear], center: .center, startRadius: 0, endRadius: Self.reach)
        }.frame(width: Self.reach * 2, height: Self.reach * 2))
        .padding(.top, top + 24)
        .frame(width: 48)
        .padding(.trailing, max(Self.center(on: display) - 24, 0))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

/// The Duo style's rail, over every app and not only the desk browser: the status bar above the Dock, which never
/// takes the mouse, and the buttons under it (back, forward, reload, home), for whichever app is in front. Panels over
/// every window that never take the keyboard, so the app stays in front as a button is pressed.
/// A button presses the front app's own menu command of that name, through Accessibility (which face unlock already
/// has), and is dimmed when the app has none. With Andeville in front, the desktop shown or no window out, the
/// buttons are the desk page's.
final class DuoPad: ObservableObject {
    enum Action: CaseIterable {
        case back, forward, reload, home, downloads, share, newTab, tabs
        var symbol: String {
            [.back: "chevron.left", .forward: "chevron.right", .reload: "arrow.clockwise", .home: "house", .downloads: "arrow.down.circle",
             .share: "square.and.arrow.up", .newTab: "plus", .tabs: "square.on.square"][self]!
        }
        var name: String {
            [.back: "뒤로", .forward: "앞으로", .reload: "새로고침", .home: "홈", .downloads: "다운로드", .share: "공유", .newTab: "새 탭", .tabs: "탭 개요"][self]!
        }
    }

    static let shared = DuoPad()
    /// What the buttons can do right now.
    @Published private(set) var can = Set(Action.allCases)
    /// The buttons (and the bar) drive the desk page: no other app's window is in front.
    @Published private(set) var desk = true
    /// macOS's Show Desktop has the windows out of the way (`DeskBrowser`'s watch): false again as they start back,
    /// a third of a second before the window list says so.
    var desktopShown = false { didSet { if desktopShown != oldValue { refresh() } } }
    private var panels: [CGDirectDisplayID: [NSPanel]] = [:] // The foot's buttons, the status bar, back and forward.
    /// Room over the back and forward buttons' glass, inside their panel.
    static let navInset: CGFloat = 4

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Three panels per screen, pinned beside the desktops: like the Dock between them, they stay where they are as
    /// one desktop slides to the next (`LockScreenSpace.pin`). A screen still there keeps its own (see `DeskBrowser.rebuild`).
    func set(on: Bool) {
        var next: [CGDirectDisplayID: [NSPanel]] = [:]
        for s in on ? NSScreen.screens : [] {
            let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let f = s.frame
            // The band at the top the rail starts under (the notch's, or the menu bar's), as the desk page's (`DeskFrame`).
            let top = s.safeAreaInsets.top > 0 ? notchSize(of: s).height : f.maxY - s.visibleFrame.maxY
            let frames = [
                // The rail's bottom end: its width, and room over the four buttons (210, 34 up) for the glass to move in.
                NSRect(x: f.maxX - DuoRail.width, y: f.minY, width: DuoRail.width, height: 378),
                // Its top end, from the screen's top: the status bar (66 tall, 24 down from the band) and its blur's reach below it.
                NSRect(x: f.maxX - DuoRail.hostWidth, y: f.maxY - top - 57 - DuoRail.reach, width: DuoRail.hostWidth, height: top + 57 + DuoRail.reach),
                // Back and forward, under the status bar: the capsule (102) and room under it for the glass to move in.
                NSRect(x: f.maxX - DuoRail.width, y: f.maxY - top - DuoRail.navTop - 102 - 40, width: DuoRail.width, height: 102 + 40 + Self.navInset),
            ]
            let old = panels.removeValue(forKey: id)
            let pair = old ?? [Self.panel(DuoPadView(display: id), clicks: true), Self.panel(DuoRail(display: id, top: top), clicks: false),
                               Self.panel(DuoPadView(display: id, top: true), clicks: true)]
            for (p, r) in zip(pair, frames) {
                if p.frame != r { p.setFrame(r, display: true) }
                p.orderFrontRegardless()
                if old == nil { LockScreenSpace.pin(p) }
            }
            next[id] = pair
        }
        panels.values.joined().forEach { $0.orderOut(nil) }
        panels = next
        if on { refresh() }
    }

    private static func panel<V: View>(_ view: V, clicks: Bool) -> NSPanel {
        // Pinned: the status bar's runs up behind the menu bar, where AppKit would not leave it.
        let p = PinnedPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.ignoresMouseEvents = !clicks
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.isOpaque = false // Clear around the buttons: clicks there go to what is under the panel.
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary] // Over full-screen apps too.
        let host = FirstMouseHost(rootView: view)
        host.sizingOptions = []
        p.contentView = host
        return p
    }

    /// The app the buttons drive, or nil for the desk page.
    private static func target() -> NSRunningApplication? {
        guard !shared.desktopShown, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Andeville still in front as the windows come back from Show Desktop (it took the keyboard for the desk, and
        // handing it back can fail or lag): the desk is under them again, so the app whose window is on top it is.
        if app.processIdentifier == getpid() {
            guard let screen = notchScreen(), ShowDesktop.windowsCover(screen.frame) else { return nil }
            return ShowDesktop.topWindowOwner().flatMap { NSRunningApplication(processIdentifier: $0) }
        }
        return ShowDesktop.hasWindow(of: app.processIdentifier) ? app : nil
    }

    /// Which buttons the front app answers; again whenever another app comes forward, the cursor comes over the
    /// buttons, or one was pressed.
    func refresh() {
        let desk = Self.target() == nil
        if desk != self.desk { withAnimation(.easeInOut(duration: 0.2)) { self.desk = desk } }
        guard let pid = Self.target()?.processIdentifier else {
            if can.count < Action.allCases.count { withAnimation(.easeInOut(duration: 0.2)) { can = Set(Action.allCases) } }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let has = Set(Self.commands(of: pid).keys)
            DispatchQueue.main.async {
                guard Self.target()?.processIdentifier == pid, self.can != has else { return } // Not an app since left.
                withAnimation(.easeInOut(duration: 0.2)) { self.can = has }
            }
        }
    }

    func press(_ a: Action, on display: CGDirectDisplayID) {
        guard let pid = Self.target()?.processIdentifier else { return DeskBrowser.shared.press(a, on: display) }
        DispatchQueue.global(qos: .userInitiated).async { // Read again at the press: menus change with what the app shows.
            if let item = Self.commands(of: pid)[a] { AXUIElementPerformAction(item, kAXPressAction as CFString) }
            DispatchQueue.main.async { self.refresh() }
        }
    }

    /// The button a menu item's title names, as apps word it in English and Korean ("Back", "Go Back", "뒤로",
    /// "Reload Page", "페이지 다시 로드", "이 페이지 새로고침"…).
    /// ponytail: by name, in two languages; add the other languages' names here, or match shortcuts, if an app is missed.
    static func action(named title: String) -> Action? {
        let t = title.lowercased().trimmingCharacters(in: .whitespaces)
        if ["back", "go back", "뒤로", "뒤로 가기"].contains(t) { return .back }
        if ["forward", "go forward", "앞으로", "앞으로 가기"].contains(t) { return .forward }
        if ["home", "go home", "홈"].contains(t) { return .home }
        if t.hasPrefix("reload") || t.hasPrefix("refresh") || t.contains("새로 고침") || t.contains("새로고침") || t.contains("다시 로드") { return .reload }
        let bare = t.trimmingCharacters(in: CharacterSet(charactersIn: "…. ")) // "Share…"
        if ["show downloads", "downloads", "다운로드 보기", "다운로드"].contains(bare) { return .downloads }
        if ["share", "공유", "공유하기"].contains(bare) { return .share }
        if ["new tab", "새 탭", "새로운 탭"].contains(bare) { return .newTab }
        if ["show all tabs", "show tab overview", "모든 탭 보기", "탭 개요 보기"].contains(bare) { return .tabs }
        return nil
    }

    /// The button a menu item's shortcut names, whatever language the app speaks: ⌘[ back, ⌘] forward, ⇧⌘\ the tabs
    /// (Safari, Chrome, Finder, Xcode, Music, System Settings…). `mods` as Accessibility gives them: 0 is ⌘ alone, 1 adds ⇧.
    /// ponytail: only shortcuts no app reuses; ⌘R (Reply in Mail, Run in Xcode) and ⌘T (Fonts in TextEdit) stay by name.
    static func action(shortcut char: String, mods: Int) -> Action? {
        switch (char, mods) {
        case ("[", 0): return .back
        case ("]", 0): return .forward
        case ("\\", 1): return .tabs
        default: return nil
        }
    }

    /// The app's menu items for the buttons, from its menu bar's menus (not their submenus). Not on the main thread.
    /// Whether an item is greyed out is not read: apps only decide that as the menu opens.
    static func commands(of pid: pid_t) -> [Action: AXUIElement] {
        let e = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(e, 0.3)
        guard let bar = RealControlCenter.attr(e, kAXMenuBarAttribute),
              let menus = RealControlCenter.attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { return [:] }
        var out: [Action: AXUIElement] = [:]
        for m in menus.dropFirst() { // Not the Apple menu.
            guard let menu = (RealControlCenter.attr(m, kAXChildrenAttribute) as? [AXUIElement])?.first,
                  let items = RealControlCenter.attr(menu, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            var here: [Action: AXUIElement] = [:]
            // ponytail: a menu's first 40 items; commands lead, and a browser's history or bookmarks run to hundreds.
            for i in items.prefix(40) {
                // Title and shortcut in one round trip to the app, not one per attribute.
                var v: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(i, [kAXTitleAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute] as CFArray,
                                                             [], &v) == .success, let vals = v as? [Any], vals.count == 3 else { continue }
                let byName = (vals[0] as? String).flatMap(action(named:))
                guard let a = byName ?? (vals[1] as? String).flatMap({ c in (vals[2] as? Int).flatMap { action(shortcut: c, mods: $0) } }),
                      here[a] == nil else { continue }
                here[a] = i
            }
            if here[.back] == nil { here[.forward] = nil } // "Forward" with no "Back" beside it sends a message on (Mail).
            out.merge(here) { first, _ in first }
        }
        return out
    }
}

/// The buttons, laid out as the iPhone Duo's Safari lays out its own: back under the status bar, a circle on its own,
/// and back over forward in one capsule when there is a forward; Safari's top right ones (downloads, share, new tab,
/// the tabs) in one at the rail's foot, 34 up from the screen's edge. Reload sits in the bar's address (`DuoAddressSlot`). Each sits on the Dock's middle. `top`: the back and forward ones.
/// ponytail: a Dock taller than the room between the two (about 13 apps on a 982 pt screen) runs under them; shrink
/// the Dock (its tile size) when it collides.
struct DuoPadView: View {
    var display: CGDirectDisplayID
    var top = false
    @ObservedObject private var tone = DuoTone.shared
    @ObservedObject private var screens = DuoScreens.shared
    @ObservedObject private var pad = DuoPad.shared

    var body: some View {
        Group {
            if top { DuoGroup(actions: pad.can.contains(.forward) ? [.back, .forward] : [.back], display: display, dark: tone.nav) }
            else { DuoGroup(actions: [.downloads, .share, .newTab, .tabs], display: display, dark: tone.controls) } // Safari's top right, as the Duo's Safari stands it.
        }
        .onHover { if $0 { DuoPad.shared.refresh() } }
        .padding(top ? .top : .bottom, top ? DuoPad.navInset : 34)
        .frame(width: 48)
        .padding(.trailing, max(DuoRail.center(on: display) - 24, 0))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: top ? .topTrailing : .bottomTrailing)
    }
}

/// Ticks when the screens' layout changes (the Dock moving or resizing among it), so views measuring it redraw.
final class DuoScreens: ObservableObject {
    static let shared = DuoScreens()
    @Published private(set) var tick = 0
    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tick += 1
        }
    }
}

/// The real Dock, at the bottom and centred, always shown, while the Duo style is on, clear of the rail on the
/// right. The user's own placement is saved first and comes back when Duo goes off or Andeville quits (or on the next
/// launch, after a crash). Private CoreDock calls (ApplicationServices), applied live as System Settings does.
enum DuoDockPin {
    private static let savedKey = "duoDockBefore" // [orientation, pinning, autohide]
    private static let lib = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
    private static func fn<T>(_ name: String, _ type: T.Type) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: type) } }

    static func set(_ on: Bool) {
        typealias GetPlace = @convention(c) (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void
        typealias SetPlace = @convention(c) (Int32, Int32) -> Void
        typealias GetHide = @convention(c) () -> UInt8
        typealias SetHide = @convention(c) (UInt8) -> Void
        guard let getPlace = fn("CoreDockGetOrientationAndPinning", GetPlace.self),
              let setPlace = fn("CoreDockSetOrientationAndPinning", SetPlace.self),
              let getHide = fn("CoreDockGetAutoHideEnabled", GetHide.self),
              let setHide = fn("CoreDockSetAutoHideEnabled", SetHide.self) else { return }
        let d = UserDefaults.standard
        let saved = d.array(forKey: savedKey) as? [Int]
        if on {
            var o: Int32 = 0, p: Int32 = 0
            getPlace(&o, &p)
            let hide = getHide()
            if saved == nil { d.set([Int(o), Int(p), Int(hide)], forKey: savedKey) }
            if o != 2 || p != 2 { setPlace(2, 2) } // Bottom, middle: the rail has the right edge to itself.
            if hide != 0 { setHide(0) }
        } else if let s = saved, s.count == 3 {
            d.removeObject(forKey: savedKey)
            setPlace(Int32(s[0]), Int32(s[1]))
            setHide(UInt8(s[2]))
        }
        DuoMenuBarPin.set(on)
    }
}

/// macOS's own menu bar, always hidden while the Duo style is on: the notch and its tabs stand in for it.
/// Its slide-down at the top edge is kept off by `keepOffMenuBar`. Saved and given back
/// like the Dock (`DuoDockPin`). Written as System Settings › Control Center does, then announced so it applies live.
enum DuoMenuBarPin {
    private static let savedKey = "duoMenuBarBefore" // The user's values; a key they never set is left out, and removed again.
    /// Where each setting lives, and its always-hidden value.
    /// ponytail: AutoHideMenuBarOption 0 = "Always" as macOS 26 has it; recheck if the bar still shows.
    private static let never: [(key: String, app: CFString, value: Any)] = [
        ("_HIHideMenuBar", kCFPreferencesAnyApplication, true),
        ("AppleMenuBarVisibleInFullscreen", kCFPreferencesAnyApplication, false),
        ("AutoHideMenuBarOption", "com.apple.controlcenter" as CFString, 0),
    ]

    static func set(_ on: Bool) {
        let d = UserDefaults.standard
        let saved = d.dictionary(forKey: savedKey)
        if on {
            if saved == nil {
                var now: [String: Any] = [:]
                for s in never { now[s.key] = CFPreferencesCopyAppValue(s.key as CFString, s.app) }
                d.set(now, forKey: savedKey)
            }
            write { $0.value }
        } else if let s = saved {
            d.removeObject(forKey: savedKey)
            write { s[$0.key] }
        }
    }

    private static func write(_ value: ((key: String, app: CFString, value: Any)) -> Any?) {
        for s in never {
            CFPreferencesSetAppValue(s.key as CFString, value(s).map { $0 as AnyObject }, s.app)
            CFPreferencesAppSynchronize(s.app)
        }
        DistributedNotificationCenter.default().postNotificationName(.init("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, deliverImmediately: true)
    }
}

/// The Duo's glass buttons, in the Dock's glass (`DuoGlass`): one is a 48-point circle, two a 48 by 102 capsule (their
/// middles 54 apart); symbols SF 20 medium, greyed to 20% when the app has no such command. Measured off the iPhone
/// Duo simulator (iOS 27.3) at 3x.
struct DuoGroup: View {
    let actions: [DuoPad.Action]
    var display: CGDirectDisplayID = 0
    /// Dark ink (a light page behind the glass), else light ink.
    var dark = true
    @ObservedObject private var pad = DuoPad.shared
    @ObservedObject private var prefs = DuoGlassPrefs.shared
    @AppStorage(DuoGlassPrefs.padThemeKey) private var theme = 0
    @AppStorage(DuoGlassPrefs.padTintKey) private var tint = 0.0
    @Environment(\.accessibilityReduceTransparency) private var solid

    var body: some View {
        // Over a solid or mostly filled face the ink reads against the fill, not the page.
        let look = prefs.pad(theme: theme, tint: tint)
        let dark = solid || look.tint > 0.5 ? !look.dark : dark
        VStack(spacing: 6) {
            ForEach(actions, id: \.self) { a in
                Button { pad.press(a, on: display) } label: {
                    Image(systemName: a.symbol).font(.system(size: 20, weight: .medium))
                        .frame(width: 48, height: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(a.name)
                .accessibilityLabel(a.name)
                .opacity(pad.can.contains(a) ? 1 : 0.2) // The app in front has no such command.
            }
        }
        .foregroundStyle(DuoTone.ink(dark))
        .frame(width: 48)
        .modifier(DuoGlass())
        .environment(\.colorScheme, dark ? .light : .dark)
    }
}

/// The Dock's glass, in a capsule, following the system's Appearance settings as the Dock does. The Dock draws its own
/// glass with the same renderer (`glassBackground`, here `Backdrop`) and reads the same settings; its blur and face
/// follow Light or Dark and the Liquid Glass slider as the Dock's do (`DuoGlassPrefs`). Its face is clear, as the
/// Dock's: what is behind shows sharp, only toned down. Its rim is `NSGlassEffectView`'s own for this radius on
/// macOS 27 (bend -1.3 r over 0.72 r, and the lit hairline). Reduce Transparency: solid.
struct DuoGlass: ViewModifier {
    @ObservedObject private var prefs = DuoGlassPrefs.shared
    @AppStorage(DuoGlassPrefs.padThemeKey) private var theme = 0
    @AppStorage(DuoGlassPrefs.padTintKey) private var tint = 0.0
    @Environment(\.accessibilityReduceTransparency) private var solid

    func body(content: Content) -> some View {
        let look = prefs.pad(theme: theme, tint: tint)
        if #available(macOS 26.0, *) {
            content.background {
                if solid { Capsule().fill(Color(white: look.dark ? 0.17 : 0.94)) } else {
                    GeometryReader { g in
                        let r = min(g.size.width, g.size.height) / 2
                        Backdrop(blur: 0.6, saturation: DuoGlassPrefs.saturation(look.dark, look.tint), refraction: 1.3 * r / 120, rimDepth: 0.72 * r,
                                 body: g.size, radius: r, squareTop: false, face: DuoGlassPrefs.face(look.dark, look.tint))
                    }
                    .clipShape(Capsule())
                }
            }
        }
        else { content.background(.ultraThinMaterial, in: Capsule()) }
    }
}

/// Settings › 화면 모드 › 우측 컨트롤러: the rail's buttons' look, Andeville's own (`DuoGlassPrefs.pad`). macOS and the Dock untouched.
struct DuoPadLookSettings: View {
    @AppStorage(DuoGlassPrefs.padThemeKey) private var theme = 0
    @AppStorage(DuoGlassPrefs.padTintKey) private var tint = 0.0

    var body: some View {
        Picker(selection: $theme) {
            Text("macOS 따르기").tag(0)
            Text("라이트").tag(1)
            Text("다크").tag(2)
        } label: {
            Text("우측 컨트롤러 모양")
            Text("Andeville에서만 바뀝니다. Dock은 macOS 설정 › 모양을 따릅니다")
        }
        .tint(nil)
        LabeledContent {
            HStack {
                Text("투명").foregroundStyle(.secondary)
                Slider(value: $tint, in: 0...1).frame(width: 140)
                Text("색조").foregroundStyle(.secondary)
            }
        } label: {
            Text("컨트롤러 채움")
            Text(theme == 0 ? "macOS의 Liquid Glass를 따르는 중" : "버튼 유리의 채움")
        }
        .disabled(theme == 0)
    }
}

/// System Settings › Appearance, live: Light or Dark, and the Liquid Glass slider from Clear to Tinted
/// (`NSGlassTintAmount`, 0...1, which the Dock reads too), turned into the Dock's tone. Measured off the Dock over
/// colour bands: it blurs by 5 (as NSGlassEffectView; a band edge spreads over ~8pt), eases bright backdrops down (white to 190, black up to 15) and deepens colour.
/// ponytail: tone measured in Dark at Clear; the slider only eases the saturation, and Light is unchecked. Re-measure
/// (colour bands behind the Dock, compare its face with a button's) if either looks off.
final class DuoGlassPrefs: NSObject, ObservableObject {
    static let shared = DuoGlassPrefs()
    @Published private(set) var dark = true
    @Published private(set) var tint = 0.0
    private var appearance: NSKeyValueObservation?
    private static let tintKey = "NSGlassTintAmount"

    var saturation: Double { Self.saturation(dark, tint) }
    var face: Backdrop.Face { Self.face(dark, tint) }
    /// Measured off the Dock, easing along the slider as its colour does (1.3 to 1.05 at 0.73).
    static func saturation(_ dark: Bool, _ tint: Double) -> Double { (dark ? 1.3 : 1.2) - 0.35 * min(max(tint, 0), 1) }
    /// Measured off the Dock (Light: `NSGlassEffectView`'s standard tone for it), the slider's Tinted end laying the
    /// theme's colour over it, as the Dock's face fills in.
    static func face(_ dark: Bool, _ tint: Double) -> Backdrop.Face {
        let a = 0.6 * CGFloat(min(max(tint, 0), 1))
        return dark ? .init(white: 0.96, black: 0.05, fill: [0.1, 0.1, 0.1, a], maxLuma: 0.7, highlight: 0.4)
                    : .init(white: 0.96, black: 0.4, fill: [0.97, 0.97, 0.97, a], highlight: 0.4)
    }

    /// The Duo rail's buttons' own look, Andeville's alone (Settings › 화면 모드 › 우측 컨트롤러), macOS untouched: `padTheme`
    /// 0 follows macOS (Appearance and its Liquid Glass slider, as the Dock does), 1 Light, 2 Dark; `padTint` their
    /// fill then, 0 Clear ... 1 Tinted.
    static let padThemeKey = "duoPadTheme", padTintKey = "duoPadTint"
    func pad(theme: Int, tint own: Double) -> (dark: Bool, tint: Double) { theme == 0 ? (dark, tint) : (theme == 2, own) }

    private override init() {
        super.init()
        read()
        // Another process (System Settings) writes it; defaults KVO hears that.
        UserDefaults.standard.addObserver(self, forKeyPath: Self.tintKey, options: [], context: nil)
        appearance = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in DispatchQueue.main.async { self?.read() } }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { self.read() }
    }

    fileprivate func read() {
        let d = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let t = UserDefaults.standard.double(forKey: Self.tintKey)
        if d != dark { dark = d }
        if t != tint { tint = t }
    }
}

/// A blur of whatever is behind the status bar, strongest at its middle and fading out evenly in every direction.
/// As Control Center's behind its controls: no material, only the blur itself, its radius falling to nothing toward
/// the edge. A window-server backdrop (the page or an app's window, under the status bar's panel) through Core
/// Animation's variable blur (private `CAFilter`, as `Backdrop` uses), masked by a radial ramp.
/// ponytail: `defaults write com.ggear.faytai duoHaloBlur -float <pt>` sets the middle's blur radius (default 10).
struct DuoHalo: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Blur() }
    func updateNSView(_ v: NSView, context: Context) {}

    final class Blur: NSView {
        private var backdrop: CALayer?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            guard let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type,
                  let filters = NSClassFromString("CAFilter") as? NSObject.Type,
                  let blur = filters.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?.takeUnretainedValue() as? NSObject,
                  let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return }
            // The mask's alpha is the share of the radius used there; it is stretched over the layer.
            // Full under the time and the ring, then easing out: no rim where the blur ends.
            let ramp = CGGradient(colorsSpace: nil, colors: [1, 0.55, 0.15, 0].map { CGColor(gray: 0, alpha: $0) } as CFArray, locations: [0.15, 0.45, 0.75, 1])!
            ctx.drawRadialGradient(ramp, startCenter: CGPoint(x: 128, y: 128), startRadius: 0, endCenter: CGPoint(x: 128, y: 128), endRadius: 128, options: [])
            guard let mask = ctx.makeImage() else { return }
            blur.setValue(UserDefaults.standard.object(forKey: "duoHaloBlur") as? Double ?? 10, forKey: "inputRadius")
            blur.setValue(mask, forKey: "inputMaskImage")
            blur.setValue(true, forKey: "inputNormalizeEdges")
            let l = cls.init()
            l.setValue(true, forKey: "windowServerAware")
            l.filters = [blur]
            layer?.addSublayer(l) // A layer under the view's: AppKit clears the filters of the view's own layer.
            backdrop = l
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdrop?.frame = bounds
            CATransaction.commit()
        }
    }
}

/// The kit's status bar Wi-Fi module, its own 42-point SVG: the Wi-Fi glyph, the open ring (in the kit a 6-wide
/// stroke clipped to the ring's outline, which is that outline filled) and four dots, at 20% as the Duo draws them.
/// Drawn as a template, so it takes the current ink.
struct DuoRing: View {
    static let image: NSImage? = {
        let svg = """
        <svg width="42" height="42" viewBox="0 0 42 42" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M12.3873 19.0272C12.84 19.4819 13.5457 19.4039 14.1183 18.9103C16.0091 17.2476 18.3659 16.3902 21.0023 16.3902C23.6388 16.3902 26.0089 17.2735 27.8864 18.9103C28.4457 19.4169 29.1514 19.4689 29.6174 19.0272C30.0835 18.5596 30.15 17.8581 29.6707 17.3645C27.6734 15.377 24.4111 14 21.0023 14C17.5936 14 14.318 15.39 12.334 17.3775C11.8546 17.8581 11.9079 18.5596 12.3873 19.0402V19.0272ZM15.6762 22.2878C16.1955 22.7814 16.8612 22.7295 17.4471 22.2618C18.4058 21.5214 19.6841 21.0147 21.0023 21.0277C22.3073 21.0277 23.5855 21.5214 24.5576 22.2748C25.1434 22.7424 25.8358 22.7684 26.3418 22.2748C26.8345 21.7812 26.9144 21.0277 26.3951 20.5601C25.1035 19.4299 23.1594 18.6375 21.0157 18.6375C18.8719 18.6375 16.9145 19.4299 15.6362 20.5601C15.1835 20.9758 15.0903 21.6902 15.6895 22.2878H15.6762ZM20.1235 26.6005C20.6961 27.1332 21.2953 27.1332 21.8678 26.6005L22.9464 25.5873C23.519 25.0417 23.6388 24.3532 22.9863 23.8856C22.4404 23.5089 21.748 23.2621 21.0023 23.2621C20.2567 23.2621 19.551 23.5089 19.0183 23.8986C18.3659 24.3532 18.499 25.0547 19.0716 25.5873L20.1368 26.6005H20.1235Z" fill-rule="evenodd" clip-rule="evenodd" fill="black"/>
        <path d="M5.06145 31.8089C4.26518 32.3489 3.17495 32.1442 2.70278 31.3059C1.10949 28.4772 0.189749 25.31 0.0263552 22.0518C-0.166198 18.212 0.699023 14.3931 2.5277 11.0113C4.35638 7.62948 7.07834 4.81457 10.3969 2.87341C13.7154 0.932239 17.5031 -0.0606849 21.3472 0.00286956C25.1912 0.066424 28.944 1.18402 32.1966 3.23383C35.4491 5.28363 38.0765 8.18699 39.7924 11.6274C41.5083 15.0678 42.2468 18.9133 41.9274 22.7445C41.6564 25.9956 40.6325 29.1306 38.9465 31.9052C38.4469 32.7274 37.3505 32.8959 36.5725 32.3298V32.3298C35.7945 31.7638 35.6311 30.678 36.1171 29.8477C37.4353 27.5954 38.2374 25.0703 38.4554 22.4551C38.7218 19.2595 38.1058 16.052 36.6746 13.1824C35.2434 10.3128 33.0519 7.89112 30.339 6.1814C27.626 4.47167 24.4958 3.5395 21.2896 3.48649C18.0833 3.43348 14.924 4.26166 12.156 5.88077C9.38807 7.49988 7.11771 9.84778 5.59243 12.6685C4.06714 15.4892 3.34547 18.6746 3.50608 21.8773C3.63751 24.4982 4.3557 27.0485 5.5987 29.3431C6.05697 30.189 5.85773 31.2689 5.06145 31.8089V31.8089Z" fill="black"/>
        <rect x="8" y="34" width="4.5" height="4.5" rx="2.25" fill="black" fill-opacity="0.2"/>
        <rect x="15" y="37" width="4.5" height="4.5" rx="2.25" fill="black" fill-opacity="0.2"/>
        <rect x="22" y="37" width="4.5" height="4.5" rx="2.25" fill="black" fill-opacity="0.2"/>
        <rect x="29" y="34" width="4.5" height="4.5" rx="2.25" fill="black" fill-opacity="0.2"/>
        </svg>
        """
        let i = NSImage(data: Data(svg.utf8))
        i?.isTemplate = true
        return i
    }()

    var body: some View {
        Group {
            if let i = Self.image { Image(nsImage: i).renderingMode(.template).resizable() } else { Image(systemName: "wifi") }
        }
        .frame(width: 42, height: 42)
        .accessibilityLabel("Wi-Fi")
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
