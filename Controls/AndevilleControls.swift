import AppIntents
import SwiftUI
import WidgetKit

/// Andeville's buttons for the Mac's own Control Center and menu bar (Control Center › Edit Controls), WidgetKit's
/// official way out. The extension runs sandboxed and cannot lock the screen or use the camera, so each control opens
/// an andeville:// link and the app does the work.
@main
struct AndevilleControls: WidgetBundle {
    var body: some Widget {
        LockControl()
        TestControl()
    }
}

private func link(_ path: String) -> OpenURLIntent { OpenURLIntent(URL(string: "andeville://\(path)")!) }

struct LockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.ggear.faytai.controls.lock") {
            ControlWidgetButton(action: link("lock")) { Label("지금 잠그기", systemImage: "lock.display") }
        }
        .displayName("지금 잠그기")
        .description("화면을 바로 잠급니다. 돌아오면 얼굴로 잠금을 해제합니다.")
    }
}

struct TestControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.ggear.faytai.controls.test") {
            ControlWidgetButton(action: link("test")) { Label("인식 테스트", systemImage: "faceid") }
        }
        .displayName("인식 테스트")
        .description("등록한 얼굴을 지금 알아보는지 확인합니다.")
    }
}
