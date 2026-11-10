// 小管家（StackChan Butler）：住在菜单栏里，给桌上的 StackChan 提供额度和「等你回复」的信号。
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.start()
            AppModel.shared.refresh()
            if let dir = ProcessInfo.processInfo.environment["BUTLER_SNAPSHOT"] { Snapshot.run(dir) }
            if ProcessInfo.processInfo.environment["BUTLER_FETCH_ICONS"] != nil {   // 开发调试：拉官方图标后退出
                Task {
                    await IconStore.fetchOfficial { b, ok in if let ok { print(b, ok ? "ok" : "fail") } }
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

@main
struct ButlerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .task { if !model.settings.setupDone { openWindow(id: "wizard") } }
        } label: {
            MenuBarLabel()
                .task { if !model.settings.setupDone { openWindow(id: "wizard") } }
        }
        .menuBarExtraStyle(.window)

        Window(t("设置"), id: "settings") { SettingsView() }
            .windowResizability(.contentSize)
            .keyboardShortcut(",")

        Window(t("欢迎使用小管家"), id: "wizard") { WizardView() }
            .windowResizability(.contentSize)
            .windowStyle(.titleBar)
    }
}
