import SwiftUI
import ShuZhaiCore

@main
struct ShuZhaiApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ShelfView()
                .environmentObject(model)
                .onOpenURL { url in model.importFiles([url], openAfter: true) }
        }
    }
}

/// 閱讀設定（存在 UserDefaults）
final class ReaderSettings: ObservableObject {
    private let d = UserDefaults.standard
    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    @Published var night: Bool { didSet { d.set(night, forKey: "night") } }
    @Published var chineseMode: Int { didSet { d.set(chineseMode, forKey: "chineseMode") } }   // 0 不轉換、1 簡轉繁

    init() {
        fontSize = d.object(forKey: "fontSize") as? Double ?? 20
        night = d.bool(forKey: "night")
        chineseMode = d.object(forKey: "chineseMode") as? Int ?? 1
    }
}

@MainActor
final class AppModel: ObservableObject {
    let store: LibraryStore
    let pipeline: TextPipeline
    let settings = ReaderSettings()
    @Published var books: [Book] = []
    @Published var importing = false
    @Published var toast: String?
    @Published var openBookId: String?
    private var converterLoaded = false

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShuZhai", isDirectory: true)
        store = LibraryStore(root: root)
        pipeline = TextPipeline(store: store)
        pipeline.rules = RulesStore.load(root: root)
        books = store.books
        // 背景載入繁簡詞庫
        Task.detached(priority: .utility) { [weak self] in
            guard let dir = Bundle.main.url(forResource: "opencc", withExtension: nil),
                  let conv = S2TWConverter(directory: dir) else { return }
            await MainActor.run {
                guard let self else { return }
                if !self.converterLoaded { self.pipeline.converter = conv; self.converterLoaded = true; self.objectWillChange.send() }
            }
        }
        applyChinese()
    }

    /// 開書前確保詞庫已載入，避免先看到簡體再跳成繁體
    func ensureConverter() {
        if converterLoaded { return }
        if let dir = Bundle.main.url(forResource: "opencc", withExtension: nil), let conv = S2TWConverter(directory: dir) {
            pipeline.converter = conv
        }
        converterLoaded = true
    }

    func applyChinese() { pipeline.chineseOn = settings.chineseMode == 1 }

    func title(_ s: String) -> String { converterLoaded ? pipeline.title(s) : s }

    func refresh() {
        books = store.books.sorted { ($0.lastReadAt, $0.addedAt) > ($1.lastReadAt, $1.addedAt) }
    }

    func importFiles(_ urls: [URL], openAfter: Bool = false) {
        importing = true
        let store = self.store
        Task.detached(priority: .userInitiated) {
            var ok: [Book] = []
            var failed: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // 先複製到暫存區（「用其他 App 開啟」傳進來的檔案可能不能直接讀）
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                do {
                    try? FileManager.default.removeItem(at: tmp)
                    try FileManager.default.copyItem(at: url, to: tmp)
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    let b: Book = try await MainActor.run { try store.importFile(tmp) }
                    ok.append(b)
                } catch {
                    failed.append(error.localizedDescription)
                }
            }
            await MainActor.run {
                self.importing = false
                self.refresh()
                var msg = ""
                if ok.count == 1 { msg = "已匯入《\(self.title(ok[0].title))》，共 \(ok[0].chapterCount) 章" }
                else if !ok.isEmpty { msg = "已匯入 \(ok.count) 本書" }
                if !failed.isEmpty { msg += (msg.isEmpty ? "" : "，") + "\(failed.count) 個檔案匯入失敗" }
                self.toast = msg
                if openAfter, ok.count == 1 { self.openBookId = ok[0].id }
            }
        }
    }

    func delete(_ b: Book) { store.delete(b.id); refresh() }

    func rename(_ b: Book, _ title: String) {
        var nb = b; nb.title = title; store.update(nb); refresh()
    }

    func saveProgress(_ b: Book) { store.update(b, save: true) }
}

/// 取代規則存取（rules.json，格式與 Android 版相同）
enum RulesStore {
    static func file(_ root: URL) -> URL { root.appendingPathComponent("rules.json") }

    static func load(root: URL) -> [ReplaceRule] {
        if let d = try? Data(contentsOf: file(root)), let r = try? JSONDecoder().decode([ReplaceRule].self, from: d) { return r }
        let r = RuleEngine.builtins()
        save(r, root: root)
        return r
    }

    static func save(_ rules: [ReplaceRule], root: URL) {
        if let d = try? JSONEncoder().encode(rules) { try? d.write(to: file(root), options: .atomic) }
    }
}
