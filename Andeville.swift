import AppKit
import Accelerate
import AVFoundation
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

/// Always-on black fillets where the notch meets the top edge. Same shape as the collapsed hub and island,
/// so they land on it and their fade-out shows nothing.
final class NotchBase {
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
        let size = CGSize(width: notch.width + HubView.ear * 2, height: notch.height)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        guard panel?.frame != frame else { return } // Called on every defaults change; rebuilding would flicker.
        panel?.orderOut(nil)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1) // Under the hub and island.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: IslandShape(width: notch.width, height: notch.height, radius: 10, ear: HubView.ear).fill(.black))
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
    /// Hidden through that, then faded back in on the settled lock screen.
    /// ponytail: fixed delay, calibration knob `defaults write com.ggear.faytai lockSettle -float <s>`.
    func sitOutLock() {
        guard let p = panel else { return }
        generation += 1
        let current = generation
        p.alphaValue = 0
        let settle = UserDefaults.standard.object(forKey: "lockSettle") == nil ? 1.0 : UserDefaults.standard.double(forKey: "lockSettle")
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            guard current == self.generation else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.35; p.animator().alphaValue = 1 }
        }
    }
}

/// Animates as a drawn shape, not layout, so the content inside can never hold its size open.
struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    /// Concave fillets where the shape meets the top edge, drawn outside `width` like the notch's own corners.
    var ear: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(radius, ear)) }
        set { (width, height, radius, ear) = (newValue.first.first, newValue.first.second, newValue.second.first, newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
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
        let radius: CGFloat = model.expanded ? 38 : 10
        ZStack(alignment: .top) {
            IslandShape(width: notch.width, height: model.expanded ? 190 : notch.height, radius: radius, ear: HubView.ear).fill(.black) // Same width as the notch, so no square top edge shows beside it.
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
            .animation(model.contentShown ? .spring(response: 0.42, dampingFraction: 0.74) : .easeIn(duration: 0.18), value: model.contentShown)
            .frame(width: notch.width)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Retract must not overshoot: shrinking past the notch size exposes the panel's top edge.
        .animation(reduceMotion ? .easeOut(duration: 0.15) : model.expanded ? .spring(response: 0.42, dampingFraction: 0.74) : .timingCurve(0.45, 0, 0.15, 1, duration: 0.5), value: model.expanded)
        .animation(.easeInOut(duration: 0.25), value: model.phase)
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

// MARK: - Notch hub

enum HubPage { case main, apps, shelf, quit }

/// The three hub presets: A compact dock, B status first (default), C menu list.
enum HubStyle: String {
    case dock, status, menu

    /// The panel's room and the main page's height; shared by the hub and its preview in Settings › 모양.
    func layout(notch: CGSize, consentNeeded: Bool) -> (size: CGSize, main: CGFloat) {
        let banner: CGFloat = consentNeeded ? 44 : 0
        let main: CGSize
        switch self {
        case .dock: main = CGSize(width: max(420, notch.width + 200), height: 132 + banner)
        case .status: main = CGSize(width: max(Store.hubWidth, notch.width), height: Store.hubHeight + banner)
        case .menu: main = CGSize(width: max(300, notch.width + 60), height: 364 + banner) // Shelf row (+34) and the divider before the face rows (+10).
        }
        return (CGSize(width: main.width, height: max(main.height, 210)), main.height) // Apps and quit pages need at least 210.
    }
}

final class HubModel: ObservableObject {
    @Published var expanded = false
    @Published var page = HubPage.main
    @Published var unlockOn = false
    @Published var consentNeeded = false
    @Published var consentLine = ""
    @Published var faceCount = 0
    @Published var apps: [LockedApp] = []
    @Published var battery: Battery?
    /// Files dropped on the notch, kept as references (nothing is copied) until removed.
    @Published var shelf: [URL] = Store.shelf { didSet { Store.shelf = shelf } }

    func addToShelf(_ urls: [URL]) {
        shelf += urls.filter { !shelf.contains($0) }
    }
}

struct Battery {
    let level: Int, charging: Bool

    static func read() -> Battery? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Battery(level: now * 100 / max, charging: d[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }

    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        return ["battery.0percent", "battery.25percent", "battery.50percent", "battery.75percent", "battery.100percent"][min(4, (level + 12) / 25)]
    }
}

struct HubActions {
    var test: () -> Void = {}
    var enroll: () -> Void = {}
    var lockNow: () -> Void = {}
    var settings: () -> Void = {}
    var quit: () -> Void = {}
    var toggleUnlock: () -> Void = {}
    var consent: () -> Void = {}
    var addApp: () -> Void = {}
}

struct HubTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct HubPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Menu-style highlight: blue while hovered or pressed.
struct HubMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: ButtonStyle.Configuration
        @State private var hover = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .opacity(isEnabled ? 1 : 0.4)
                .background((hover || configuration.isPressed) && isEnabled ? Color.blue : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onHover { hover = $0 }
        }
    }
}

struct HubWingStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0), in: Circle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct HubView: View {
    @ObservedObject var model: HubModel
    let notch: CGSize
    /// The panel's room: the main page's size, grown to fit the apps and quit pages.
    let size: CGSize
    let mainHeight: CGFloat
    let style: HubStyle
    let actions: HubActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static var ear: CGFloat { Store.notchEar }

    var body: some View {
        ZStack(alignment: .top) {
            IslandShape(width: model.expanded ? size.width : notch.width,
                        height: model.expanded ? shapeHeight : notch.height,
                        radius: model.expanded ? 26 : 10,
                        ear: HubView.ear).fill(.black)
            VStack(spacing: 0) {
                wings.frame(height: notch.height)
                Group {
                    switch (model.page, style) {
                    case (.main, .dock): dockPage
                    case (.main, .status): mainPage
                    case (.main, .menu): menuPage
                    case (.apps, _): appsPage
                    case (.shelf, _): shelfPage
                    case (.quit, _): quitPage
                    }
                }
                .padding(.top, 10)
                .padding(.horizontal, style == .menu && model.page == .main ? 8 : 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: size.width, height: shapeHeight, alignment: .top)
            .opacity(model.expanded ? 1 : 0)
            // No blur here: blurring the whole tile grid costs an offscreen pass every frame of the spring.
            .scaleEffect(model.expanded || reduceMotion ? 1 : 0.94, anchor: .top)
            .animation(model.expanded ? .spring(response: Store.hubOpen * 0.95, dampingFraction: 0.8).delay(Store.hubOpen * 0.2) : .easeIn(duration: Store.hubClose * 0.3), value: model.expanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // Retract must not overshoot: shrinking past the notch size exposes the panel's top edge.
        .animation(reduceMotion ? .easeOut(duration: 0.15) : model.expanded ? .spring(response: Store.hubOpen, dampingFraction: 0.78) : .timingCurve(0.45, 0, 0.15, 1, duration: Store.hubClose), value: model.expanded)
        .animation(.easeInOut(duration: 0.2), value: model.page)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.addToShelf([url]) }
                }
            }
            // Status shows the shelf on its main page; the other presets switch to it.
            if style != .status || model.page != .main { model.page = .shelf }
            return true
        }
    }

    @State private var dropping = false

    private var shapeHeight: CGFloat { model.page == .main ? mainHeight : size.height }

    /// Beside the notch. Status: settings and quit on the right. Dock: the unlock state on the left. Menu: too narrow, empty.
    @ViewBuilder private var wings: some View {
        let side = max((size.width - notch.width) / 2, 0)
        switch style {
        case .status:
            HStack(spacing: 0) {
                batteryLabel.padding(.leading, 16).frame(width: side, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    wingButton("gearshape", "설정", actions.settings)
                    wingButton("power", "종료", tint: HubView.quitTint) { model.page = .quit }
                }
                .padding(.trailing, 12)
                .frame(width: side, alignment: .trailing)
            }
        case .dock:
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    batteryLabel
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusTitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(width: side)
                Spacer(minLength: 0)
            }
        case .menu:
            Color.clear
        }
    }

    static let quitTint = Color(red: 1, green: 0.41, blue: 0.38)

    @ViewBuilder private var batteryLabel: some View {
        if let b = model.battery {
            HStack(spacing: 4) {
                Text("\(b.level)%").font(.system(size: 11, weight: .medium)).monospacedDigit().fixedSize()
                Image(systemName: b.symbol).font(.system(size: 13))
                    .foregroundStyle(b.charging ? Color.green : b.level <= 20 ? Color.red : Color.white)
            }
            .foregroundStyle(.white.opacity(0.85))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("배터리 \(b.level)%\(b.charging ? ", 충전 중" : "")")
        }
    }

    // MARK: Shelf

    private func openFile(_ url: URL) { NSWorkspace.shared.open(url) }

    private func shelfItem(_ url: URL, size icon: CGFloat) -> some View {
        VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: icon, height: icon)
            Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: icon + 22)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openFile(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("열기") { openFile(url) }
            Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("선반에서 빼기") { model.shelf.removeAll { $0 == url } }
        }
        .help(url.path)
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityAction(named: "열기") { openFile(url) }
        .accessibilityAction(named: "선반에서 빼기") { model.shelf.removeAll { $0 == url } }
    }

    private var shelfEmpty: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 22, weight: .light))
            Text("파일을 노치로 끌어다 놓으세요").font(.system(size: 11)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(dropping ? 0.95 : 0.55))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shelfHeader(back: Bool) -> some View {
        HStack(spacing: 6) {
            if back {
                Button { model.page = .main } label: {
                    Label("선반", systemImage: "chevron.left").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "tray.full").font(.system(size: 11))
                Text("선반").font(.system(size: 12, weight: .semibold))
            }
            if !model.shelf.isEmpty {
                Text("\(model.shelf.count)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            if !model.shelf.isEmpty {
                Button("비우기") { model.shelf.removeAll() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    /// Status preset's left card: drop files on the notch, drag them back out anywhere, double-click to open.
    private var shelfCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            shelfHeader(back: false)
            if model.shelf.isEmpty {
                shelfEmpty
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(model.shelf, id: \.self) { shelfItem($0, size: 34) }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(dropping ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if dropping { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
        }
    }

    private var shelfPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            shelfHeader(back: true)
            if model.shelf.isEmpty {
                shelfEmpty
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6)], spacing: 8) {
                        ForEach(model.shelf, id: \.self) { shelfItem($0, size: 36) }
                    }
                }
            }
        }
    }

    private func wingButton(_ symbol: String, _ title: String, tint: Color = .white, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(HubWingStyle())
        .accessibilityLabel(title)
    }

    private var cardWidth: CGFloat { min(200, (size.width - 32) * 0.46) }

    private var statusTitle: String {
        if model.faceCount == 0 { return "얼굴 미등록" }
        if model.consentNeeded { return "동의 필요" }
        return model.unlockOn ? "준비됨" : "잠금해제 꺼짐"
    }

    private var statusColor: Color {
        if model.consentNeeded { return .blue }
        return model.faceCount > 0 && model.unlockOn ? .green : Color(white: 0.6)
    }

    private var consentBanner: some View {
        Button(action: actions.consent) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(.blue)
                Text("약관이 갱신되었습니다 · 키체인 동의가 필요합니다").lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Text("서명하기").fontWeight(.semibold).foregroundStyle(Color(red: 0.39, green: 0.69, blue: 1))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: A · compact dock

    private var dockPage: some View {
        VStack(spacing: 10) {
            if model.consentNeeded { consentBanner }
            HStack(spacing: 6) {
                dockButton("tray.full", "선반", badge: model.shelf.count) { model.page = .shelf }
                dockButton("lock.display", "지금 잠그기", action: actions.lockNow)
                dockButton("lock.app.dashed", "앱 잠금", badge: model.apps.count) { model.page = .apps }
                dockButton("faceid", "인식 테스트", action: actions.test).disabled(model.faceCount == 0)
                dockButton("person.crop.square", "얼굴 등록", action: actions.enroll)
                dockButton("gearshape", "설정", action: actions.settings)
                dockButton("power", "종료", tint: HubView.quitTint) { model.page = .quit }
            }
        }
    }

    private func dockButton(_ symbol: String, _ title: String, tint: Color = .white, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18, weight: .light)).foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.1), in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text("\(badge)").font(.system(size: 10, weight: .bold))
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Color.blue, in: Capsule())
                                .offset(x: 2, y: -2)
                        }
                    }
                Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(HubPressStyle())
        .accessibilityLabel(badge > 0 ? "\(title), \(badge)개" : title)
    }

    // MARK: C · menu list

    private var menuPage: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.consentNeeded { consentBanner.padding(.bottom, 6) }
            menuRow("tray.full", "선반", trailing: "\(model.shelf.count)개", chevron: true) { model.page = .shelf }
            menuRow("lock.display", "지금 잠그기", trailing: "⌃⌘Q", action: actions.lockNow)
            menuRow("lock.app.dashed", "잠긴 앱", trailing: "\(model.apps.count)개", chevron: true) { model.page = .apps }
            menuDivider
            menuRow("faceid", "인식 테스트", action: actions.test).disabled(model.faceCount == 0)
            menuRow("person.crop.square", model.faceCount > 0 ? "얼굴 다시 등록…" : "얼굴 등록…", action: actions.enroll)
            menuDivider
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").font(.system(size: 13)).foregroundStyle(model.unlockOn ? Color.green : Color(white: 0.6)).frame(width: 18)
                Text("잠금화면 해제").font(.system(size: 13))
                Spacer(minLength: 4)
                Toggle("잠금화면 해제", isOn: Binding(get: { model.unlockOn }, set: { _ in actions.toggleUnlock() }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            Text("\(model.consentLine) · \(model.faceCount > 0 ? "얼굴 등록됨" : "얼굴 미등록")")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.leading, 38).padding(.trailing, 10)
            menuDivider
            menuRow("gearshape", "설정…", action: actions.settings)
            menuRow("power", "Andeville 종료") { model.page = .quit }
        }
    }

    private var menuDivider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 4)
    }

    private func menuRow(_ symbol: String, _ title: String, trailing: String? = nil, chevron: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 18)
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)) }
                if chevron { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.55)) }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(HubMenuRowStyle())
    }

    // MARK: B · status first

    private var mainPage: some View {
        VStack(spacing: 10) {
            if model.consentNeeded { consentBanner }
            HStack(spacing: 10) {
                shelfCard.frame(width: cardWidth)
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        tile("lock.display", "지금 잠그기", action: actions.lockNow)
                        tile("lock.app.dashed", "앱 잠금", detail: model.apps.isEmpty ? nil : "\(model.apps.count)개 잠김") { model.page = .apps }
                    }
                    GridRow {
                        // Face unlock is one feature among the notch's: its state on the tile, a tap flips it (or enrolls first).
                        tile("faceid", "얼굴 잠금", detail: statusTitle, tint: statusColor,
                             action: model.faceCount == 0 ? actions.enroll : actions.toggleUnlock)
                        tile("viewfinder", "인식 테스트", action: actions.test).disabled(model.faceCount == 0)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// B's tiles show the icon alone; the name stays in the tooltip and VoiceOver, the state in the icon's tint.
    private func tile(_ symbol: String, _ title: String, detail: String? = nil, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(HubTileStyle())
        .help(detail.map { "\(title) · \($0)" } ?? title)
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }

    private var appsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { model.page = .main } label: {
                    Label("잠긴 앱", systemImage: "chevron.left").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                Spacer()
                Button("앱 추가…", action: actions.addApp).buttonStyle(.borderedProminent).controlSize(.small)
            }
            if model.apps.isEmpty {
                Text("잠긴 앱이 없습니다. 잠긴 앱은 열 때 얼굴 확인을 거칩니다.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: size.width < 360 ? 1 : 3), spacing: 6) {
                        ForEach(model.apps) { app in
                            HStack(spacing: 8) {
                                Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                                Text(app.name).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var quitPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Andeville을 종료할까요?").font(.system(size: 14, weight: .bold))
            Text("노치 메뉴, 선반, 얼굴 잠금 해제가 꺼집니다. 선반의 파일은 그대로 남습니다. 다시 켜려면 응용 프로그램 폴더에서 Andeville을 여세요.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("취소") { model.page = .main }.controlSize(.small)
                Button("종료", role: .destructive, action: actions.quit).buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
            }
        }
    }
}

/// Buttons answer the first click even though the panel never becomes key.
final class FirstMouseHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Hub {
    let model = HubModel()
    var actions = HubActions()
    private var panel: NSPanel?
    private var host: FirstMouseHost<HubView>?
    private var generation = 0
    private(set) var isShown = false

    var frame: NSRect { isShown ? panel?.frame ?? .zero : .zero }

    /// Built once and kept: making the window and SwiftUI tree on every hover blocked the main thread ~40 ms
    /// right as the animation started. Rebuilt only when the size changes.
    private func prepare(on screen: NSScreen) -> NSPanel {
        let notch = notchSize(of: screen)
        let style = Store.hubStyle
        let (size, mainHeight) = style.layout(notch: notch, consentNeeded: model.consentNeeded)
        let outer = CGSize(width: size.width + HubView.ear * 2, height: size.height) // Room for the top fillets beside the body.
        let frame = NSRect(x: screen.frame.midX - outer.width / 2, y: screen.frame.maxY - outer.height, width: outer.width, height: outer.height)
        if let p = panel, let host, host.rootView.size == size, host.rootView.notch == notch,
           host.rootView.style == style, host.rootView.mainHeight == mainHeight, p.frame.size == frame.size { // Size tracks the ear radius too.
            if p.frame != frame { p.setFrame(frame, display: false) }
            return p
        }
        panel?.orderOut(nil)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        model.expanded = false
        let host = FirstMouseHost(rootView: HubView(model: model, notch: notch, size: size, mainHeight: mainHeight, style: style, actions: actions))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: outer)
        p.contentView = host
        p.setFrame(frame, display: false)
        host.layoutSubtreeIfNeeded()
        panel = p
        self.host = host
        return p
    }

    /// Renders once, invisibly, at launch so the first hover does not pay for the window or SwiftUI's first frame.
    func prewarm() {
        guard let screen = notchScreen() else { return }
        let p = prepare(on: screen)
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.displayIfNeeded()
        p.orderOut(nil)
    }

    func show(on screen: NSScreen) {
        let p = prepare(on: screen)
        generation += 1 // Cancels a pending fade-out, so hovering again mid-retract reverses it from where it is.
        isShown = true
        model.page = .main
        p.ignoresMouseEvents = false
        if !p.isVisible {
            model.expanded = false
            p.alphaValue = 0
            p.orderFrontRegardless()
            p.displayIfNeeded()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        DispatchQueue.main.async { self.model.expanded = true }
    }

    /// No retract: locking snapshots the desktop for its shrink-away, and a hub still mid-retract stayed in it as an afterimage.
    func hideNow() {
        generation += 1
        isShown = false
        model.expanded = false
        panel?.ignoresMouseEvents = true
        panel?.alphaValue = 0
        panel?.orderOut(nil)
    }

    func hide() {
        guard isShown, let p = panel else { return }
        isShown = false
        generation += 1
        let current = generation
        p.ignoresMouseEvents = true // The retracting shape must not swallow clicks meant for the menu bar.
        model.expanded = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Store.hubClose) { // Right as the retract lands on the notch.
            guard current == self.generation else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 },
                                                 completionHandler: { if current == self.generation { p.orderOut(nil) } })
        }
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
                            .animation(.easeOut(duration: 0.2), value: model.ring[i])
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
                HStack(spacing: 10) {
                    Image(systemName: "macbook")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.indigo.gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Andeville").font(.headline).fixedSize()
                        Text("노치 도우미")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .selectionDisabled()
                .listRowSeparator(.hidden)

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
    @AppStorage("hubStyle") private var hubStyle = HubStyle.status.rawValue
    @AppStorage("notchEar") private var notchEar = Store.notchEarDefault
    @AppStorage("hubWidth") private var hubWidth = Double(Store.hubDefault.width)
    @AppStorage("hubHeight") private var hubHeight = Double(Store.hubDefault.height)

    private var style: HubStyle { HubStyle(rawValue: hubStyle) ?? .status }

    private func hubSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: 4).frame(width: 190).labelsHidden()
                Text("\(Int(value.wrappedValue))pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("프리셋", selection: $hubStyle) {
                    Text("A · 컴팩트 독").tag(HubStyle.dock.rawValue)
                    Text("B · 상태 우선").tag(HubStyle.status.rawValue)
                    Text("C · 메뉴 리스트").tag(HubStyle.menu.rawValue)
                }
                .pickerStyle(.segmented)
                HubPreview(style: style, settings: model, width: hubWidth, height: hubHeight)
                    .frame(maxWidth: .infinity)
                Group {
                    hubSlider("폭", value: $hubWidth, range: 360...640)
                    hubSlider("높이", value: $hubHeight, range: 140...300)
                    LabeledContent("기본 크기로 되돌리기") {
                        Button("되돌리기") {
                            hubWidth = Store.hubDefault.width
                            hubHeight = Store.hubDefault.height
                        }
                    }
                }
                .disabled(style != .status) // A and C have fixed sizes.
            } header: {
                Text("노치 허브 프리셋")
            } footer: {
                Text("A 컴팩트 독은 아이콘 한 줄, B 상태 우선은 상태 카드와 동작 네 개, C 메뉴 리스트는 한 줄씩 나열한 메뉴입니다. 미리보기는 이 Mac의 지금 상태로 그립니다. 폭과 높이는 B에만 적용되며, 다음에 허브를 열 때부터 적용됩니다.")
            }
            Section {
                LabeledContent("모서리 라운드") {
                    HStack {
                        Slider(value: $notchEar, in: Store.notchEarRange, step: 1).frame(width: 190).labelsHidden()
                        Text("\(Int(notchEar))pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    }
                }
                LabeledContent("기본 라운드로 되돌리기") {
                    Button("되돌리기") { notchEar = Store.notchEarDefault }.disabled(notchEar == Store.notchEarDefault)
                }
            } footer: {
                Text("노치가 화면 상단과 만나는 곳의 둥근 모서리 크기입니다. 데스크톱과 잠금화면에서 항상 표시되며, 노치·허브·Face ID 표시에 같이 적용됩니다. 기본값이자 최소값은 7pt입니다.")
            }
        }
    }
}

/// The real hub view, fed this Mac's state, frozen open and scaled down to fit the settings page.
struct HubPreview: View {
    let style: HubStyle
    @ObservedObject var settings: SettingsModel
    let width: Double, height: Double // Read only so a slider move redraws the preview.

    var body: some View {
        let notch = notchScreen().map(notchSize) ?? CGSize(width: 220, height: 38)
        let consentNeeded = settings.hasPassword && !Terms.isSigned(by: settings.consent)
        let (size, main) = style.layout(notch: notch, consentNeeded: consentNeeded)
        let scene = CGSize(width: size.width + HubView.ear * 2 + 80, height: main + 24)
        let scale = min(1, 460 / scene.width, 270 / scene.height) // Tall C stays a preview, not a page.
        ZStack(alignment: .top) {
            Color(red: 0.11, green: 0.15, blue: 0.19)
            Color.black.opacity(0.28).frame(height: notch.height)
            HubView(model: model(consentNeeded), notch: notch, size: size, mainHeight: main, style: style, actions: HubActions())
                .frame(width: size.width + HubView.ear * 2, height: main)
        }
        .frame(width: scene.width, height: scene.height)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: scene.width * scale, height: scene.height * scale, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("노치 허브 미리보기")
        .padding(.vertical, 4)
    }

    private func model(_ consentNeeded: Bool) -> HubModel {
        let m = HubModel()
        m.expanded = true
        m.unlockOn = settings.hasPassword
        m.consentNeeded = consentNeeded
        if let c = settings.consent, Terms.isSigned(by: c) {
            m.consentLine = "키체인 동의 \(c.termsVersion)판 서명됨"
        } else {
            m.consentLine = consentNeeded ? "키체인 동의 · 다시 서명 필요" : "키체인 동의 전"
        }
        m.faceCount = settings.faceCount
        m.apps = settings.lockedApps
        return m
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
                timeSlider("감지 속도", value: $hubDwell, range: 0...0.5, step: 0.01)
                timeSlider("닫힘 감지 속도", value: $hubLeave, range: 0...0.6, step: 0.01)
                timeSlider("펼치는 속도", value: $hubOpen)
                timeSlider("접히는 속도", value: $hubClose)
                LabeledContent("기본값으로 되돌리기") {
                    Button("되돌리기") {
                        hubDwell = Store.hubTimingDefault.dwell
                        hubLeave = Store.hubTimingDefault.leave
                        hubOpen = Store.hubTimingDefault.open
                        hubClose = Store.hubTimingDefault.close
                    }
                }
            } header: {
                Text("노치 허브")
            } footer: {
                Text("데스크톱에서 노치에 커서를 올리면 열리는 메뉴의 동작 속도입니다. 모양과 프리셋은 모양 탭에서 바꿉니다. 펼치는·접히는 속도는 다음에 열 때부터 적용됩니다. 감지 속도는 노치에 커서가 머물러야 열리는 시간, 닫힘 감지 속도는 커서가 메뉴 밖으로 나간 뒤 닫히기까지의 시간이고(0초면 즉시, 두 감지 속도는 바로 적용), 펼치는·접히는 속도는 움직이는 데 걸리는 시간입니다. 모두 짧을수록 빠릅니다.")
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
        .animation(.easeOut(duration: 0.2), value: on)
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

    assert(!screenLocked(), "self-check runs on an unlocked session")
    assert(!typeIntoLockScreen("x"), "nothing may be typed while unlocked")
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

    /// Notch hub size in points; Settings › 일반 or `defaults write com.ggear.faytai hubWidth -float <px>`.
    static let hubDefault = CGSize(width: 460, height: 210)
    static var hubWidth: CGFloat {
        let v = UserDefaults.standard.double(forKey: "hubWidth")
        return v > 0 ? v : hubDefault.width
    }
    static var hubHeight: CGFloat {
        let v = UserDefaults.standard.double(forKey: "hubHeight")
        return v > 0 ? v : hubDefault.height
    }

    /// Settings › 일반 › 노치 허브 › 스타일.
    static var hubStyle: HubStyle { HubStyle(rawValue: UserDefaults.standard.string(forKey: "hubStyle") ?? "") ?? .status }

    /// Hub open/close animation lengths in seconds; Settings › 일반 › 노치 허브.
    static let hubTimingDefault = (open: 0.4, close: 0.45, dwell: 0.08, leave: 0.1)
    /// How long the cursor may be off the hub before it closes; 0 closes on exit.
    static var hubLeave: Double {
        UserDefaults.standard.object(forKey: "hubLeave") == nil ? hubTimingDefault.leave : max(UserDefaults.standard.double(forKey: "hubLeave"), 0)
    }
    /// How long the cursor must rest on the notch before the hub opens; 0 opens on contact.
    static var hubDwell: Double {
        UserDefaults.standard.object(forKey: "hubDwell") == nil ? hubTimingDefault.dwell : max(UserDefaults.standard.double(forKey: "hubDwell"), 0)
    }
    static var hubOpen: Double {
        let v = UserDefaults.standard.double(forKey: "hubOpen")
        return v > 0 ? v : hubTimingDefault.open
    }
    static var hubClose: Double {
        let v = UserDefaults.standard.double(forKey: "hubClose")
        return v > 0 ? v : hubTimingDefault.close
    }

    /// Notch shelf; files moved or deleted since are dropped on load.
    static var shelf: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: "shelf") ?? []).map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) } }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "shelf") }
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
        return keychainPassword()
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
        guard hasPassword, hasCurrentConsent, sealedSecret() == nil, let pw = keychainPassword() else { return }
        sealSecret(pw)
        log("consented copy filled from the keychain")
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
    private let hub = Hub()
    private let notchBase = NotchBase()
    private var appCache: [String: LockedApp] = [:]
    private var hubTimer: Timer?
    private var faces = Store.loadFaces()
    private var busy = false
    private let settingsModel = SettingsModel()
    private var settingsWindow: NSWindow?
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

    func applicationDidFinishLaunching(_ n: Notification) {
        setUpHub()
        notchBase.update()
        hub.prewarm()
        _ = lockedAppList()
        NotificationCenter.default.addObserver(self, selector: #selector(updateNotchBase), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateNotchBase), name: UserDefaults.didChangeNotification, object: nil)
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        wc.addObserver(self, selector: #selector(appQuit(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        wc.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenDidLock), name: .init("com.apple.screenIsLocked"), object: nil)
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
                DispatchQueue.global().async { // May wait on a keychain prompt; the hub must keep working meanwhile.
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

    // MARK: Notch hub (replaces the menu bar icon)

    @objc private func updateNotchBase() {
        DispatchQueue.main.async { self.notchBase.update() }
    }

    /// Opening the app again (Finder, Spotlight) is the way in without a notch hover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func setUpHub() {
        let closing: (@escaping () -> Void) -> () -> Void = { go in { [weak self] in self?.hub.hide(); go() } }
        hub.actions = HubActions(
            test: closing { [weak self] in self?.test() },
            enroll: closing { [weak self] in self?.enroll() },
            lockNow: { [weak self] in
                self?.hub.hideNow()
                // One beat so the window server drops the hub before the lock snapshots the desktop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { lockScreenNow() }
            },
            settings: closing { [weak self] in self?.openSettings() },
            quit: { NSApp.terminate(nil) },
            toggleUnlock: { [weak self] in
                guard let self else { return }
                if Store.hasPassword {
                    Store.deletePassword()
                    self.hub.model.unlockOn = false
                } else {
                    self.hub.hide()
                    self.toggleUnlock()
                }
            },
            consent: closing { [weak self] in self?.showConsent {} },
            addApp: closing { [weak self] in self?.addApp() }
        )

        var overSince: Date?, awaySince: Date?
        var armed = true // After the hub closes, the cursor must leave the notch before it can open again.
        // Polled like the lock screen watch; a 60 Hz mouse read is negligible and keeps the dwell setting accurate.
        hubTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard !screenLocked(), !self.busy, !self.island.isShowing, let screen = notchScreen() else {
                if self.hub.isShown { self.hub.hide() }
                overSince = nil
                armed = false
                return
            }
            let p = NSEvent.mouseLocation, now = Date()
            let overNotch = cursor(p, isOver: notchRect(in: screen.frame, notch: notchSize(of: screen)))
            if self.hub.isShown {
                // A held button means a file is being dragged out of the shelf: closing would drop the drag's source.
                if cursor(p, isOver: self.hub.frame) || NSEvent.pressedMouseButtons & 1 != 0 { awaySince = nil } else if awaySince == nil { awaySince = now }
                if let a = awaySince, now.timeIntervalSince(a) >= Store.hubLeave { // Grace, so a cursor that slips off the edge does not close it.
                    self.hub.hide()
                    armed = false
                }
                return
            }
            if !overNotch { armed = true }
            guard overNotch, armed else { overSince = nil; return }
            if overSince == nil { overSince = now }
            // Dwell (Settings › 노치 허브 › 감지 속도), so a cursor passing over the top edge does not open it.
            if now.timeIntervalSince(overSince!) >= Store.hubDwell {
                overSince = nil
                awaySince = nil
                self.openHub(on: screen)
            }
        }
    }

    private func openHub(on screen: NSScreen) {
        let m = hub.model
        m.unlockOn = Store.hasPassword
        m.consentNeeded = Store.hasPassword && !Store.hasCurrentConsent
        if let c = Store.consents.last, Terms.isSigned(by: c) {
            m.consentLine = "키체인 동의 \(c.termsVersion)판 서명됨"
        } else {
            m.consentLine = m.consentNeeded ? "키체인 동의 · 다시 서명 필요" : "키체인 동의 전"
        }
        m.faceCount = faces.count
        m.apps = lockedAppList()
        m.battery = Battery.read()
        hub.show(on: screen)
    }

    /// Icons are cached: loading them took ~20 ms on the first hover, right as the hub opened.
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
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
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

    @objc private func screenDidLock() {
        notchBase.sitOutLock()
        log("screen locked")
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

if CommandLine.arguments.contains("--hub-demo") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let demoHub = Hub()
    demoHub.model.unlockOn = true
    demoHub.model.faceCount = 50
    demoHub.model.consentNeeded = CommandLine.arguments.contains("--consent")
    demoHub.model.consentLine = demoHub.model.consentNeeded ? "키체인 동의 · 다시 서명 필요" : "키체인 동의 1판 · 2026. 11. 10. 서명"
    if let s = notchScreen() { demoHub.show(on: s) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
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
