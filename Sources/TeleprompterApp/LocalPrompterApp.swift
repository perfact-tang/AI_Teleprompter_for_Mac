import SwiftUI
import AppKit

@main
struct LocalPrompterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = TeleprompterController()
    var body: some Scene {
        WindowGroup("本地提词 · LocalPrompter") {
            ContentView(model: controller)
                .frame(minWidth: 1060, minHeight: 720)
                .onAppear { delegate.controller = controller; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入稿件…") { controller.importScript() }.keyboardShortcut("o").disabled(controller.isLocked)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: TeleprompterController?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        if controller.state == .preparing || controller.state == .finishing { return .terminateCancel }
        if controller.state == .recording || controller.state == .paused {
            let alert = NSAlert()
            alert.messageText = "结束录制并退出？"
            alert.informativeText = "先完成视频写入并选择保存位置。取消保存时，视频会保留在本地恢复目录。"
            alert.addButton(withTitle: "结束并保存"); alert.addButton(withTitle: "继续录制")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            Task { await controller.finish(); controller.capture.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        controller.capture.shutdown()
        return .terminateNow
    }
}
