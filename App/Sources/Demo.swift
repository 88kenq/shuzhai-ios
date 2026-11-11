import SwiftUI
import ShuZhaiCore

/// 自動示範模式（只在 CI 的模擬器截圖時使用）：
/// 環境變數 SZ_DEMO_DIR 指向範例書資料夾，SZ_DEMO_STEP 決定要停在哪個畫面。
/// 一般使用者不會設定這些環境變數，所以完全不影響正常使用。
enum Demo {
    static let env = ProcessInfo.processInfo.environment
    static var step: String? { env["SZ_DEMO_STEP"] }
    static var styleTab: Int { ["theme": 1, "other": 2][step ?? ""] ?? 0 }

    @MainActor
    static func start(_ app: AppModel) {
        guard let dir = env["SZ_DEMO_DIR"], let step else { return }
        if app.store.books.isEmpty {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
            for f in files { _ = try? app.store.importFile(URL(fileURLWithPath: dir).appendingPathComponent(f)) }
            app.refresh()
        }
        app.pageMode = step == "scroll" ? 1 : 0
        app.night = step == "night"
        app.followSystem = false
        if step == "theme" { app.style.dayTheme = 5 } else { app.style.dayTheme = 1 }
        guard step != "shelf" else { return }
        let target = step == "epub" ? app.store.books.first { $0.format == "epub" } : app.store.books.first { $0.format == "txt" }
        if let b = target {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.openBookId = b.id }
        }
    }

    @MainActor
    static func drive(model: ReaderModel, panel: Binding<ReaderPanel>, sheet: Binding<ReaderSheet?>) {
        guard let step else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            switch step {
            case "menu": panel.wrappedValue = .menu
            case "style", "theme", "other": panel.wrappedValue = .style
            case "tts": panel.wrappedValue = .tts
            case "toc": sheet.wrappedValue = .toc
            case "search": sheet.wrappedValue = .search
            case "rules": sheet.wrappedValue = .rules
            case "page2": model.next(); model.next()
            case "epub": model.open(0)
            default: break
            }
        }
    }
}
