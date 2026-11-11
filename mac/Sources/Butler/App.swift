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

    // 菜单栏图标被系统藏起来、或者被关掉时，在「应用程序」里再双击小管家就弹出设置窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !AppModel.shared.settings.setupDone { Openers.wizard?(0) } else { Openers.settings?() }
        }
        return false
    }
}

@main
struct ButlerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        MenuBarExtra {
            MenuView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        // 标准的设置窗口：顶部工具栏切换各页、标题跟着当前页、⌘, 打开（Apple 设计规范）
        Settings { SettingsView() }

        // 安装向导：一步一屏，标题栏藏起来（只留左上角三个按钮）
        Window(t("欢迎使用小管家"), id: "wizard") { WizardView() }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
    }
}
