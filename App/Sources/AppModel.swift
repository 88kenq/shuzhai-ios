import SwiftUI
import CoreText
import ShuZhaiCore

@main
struct ShuZhaiApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ShelfView()
                .environmentObject(model)
                .environmentObject(model.tts)
                .onOpenURL { url in model.importFiles([url], openAfter: true) }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let root: URL
    let store: LibraryStore
    let pipeline: TextPipeline
    let prefs: Prefs
    lazy var tts = TtsController(app: self)

    @Published var books: [Book] = []
    @Published var importing = false
    @Published var toast: String?
    @Published var openBookId: String?
    @Published var rules: [ReplaceRule] = []
    @Published var rulesVersion = 0
    @Published var fontsVersion = 0

    // ── 設定（存在 prefs.json，鍵名與 Android 版相同）──
    @Published var style: ReadStyle { didSet { if style != oldValue { prefs.set("style", style.json()) } } }
    @Published var night: Bool { didSet { prefs.set("night", night) } }
    @Published var followSystem: Bool { didSet { prefs.set("followSystem", followSystem) } }
    @Published var pageMode: Int { didSet { prefs.set("pageMode", pageMode) } }          // 0 翻頁、1 捲動
    @Published var keepOn: Bool { didSet { prefs.set("keepOn", keepOn) } }
    @Published var statusBar: Bool { didSet { prefs.set("statusBar", statusBar) } }
    @Published var dualPage: Bool { didSet { prefs.set("dualPage", dualPage) } }
    @Published var brightness: Double { didSet { prefs.set("brightness", brightness) } }  // -1 跟隨系統
    @Published var tapZones: [Int] { didSet { prefs.set("tapZones", tapZones.map(String.init).joined()) } }
    @Published var chineseMode: Int { didSet { prefs.set("chineseMode", chineseMode); applyChinese() } }
    @Published var ttsRate: Double { didSet { prefs.set("ttsRate", ttsRate) } }
    @Published var ttsPitch: Double { didSet { prefs.set("ttsPitch", ttsPitch) } }
    @Published var ttsVoice: String { didSet { prefs.set("ttsVoice", ttsVoice) } }

    static let defaultZones = [1, 1, 1, 1, 3, 1, 1, 1, 1]
    private var converterLoaded = false

    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShuZhai", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = LibraryStore(root: root)
        pipeline = TextPipeline(store: store)
        prefs = Prefs(file: root.appendingPathComponent("prefs.json"))
        style = ReadStyle.from(json: prefs.string("style")) ?? ReadStyle()
        night = prefs.bool("night"); followSystem = prefs.bool("followSystem")
        pageMode = prefs.int("pageMode"); keepOn = prefs.bool("keepOn", true)
        statusBar = prefs.bool("statusBar"); dualPage = prefs.bool("dualPage", true)
        brightness = prefs.double("brightness", -1)
        let z = prefs.string("tapZones")
        tapZones = z.count == 9 ? z.compactMap { Int(String($0)) } : Self.defaultZones
        chineseMode = prefs.int("chineseMode", 1)
        ttsRate = prefs.double("ttsRate", 1); ttsPitch = prefs.double("ttsPitch", 1)
        ttsVoice = prefs.string("ttsVoice")
        rules = RulesStore.load(root: root)
        pipeline.rules = rules
        books = store.books
        applyChinese()
        Fonts.registerAll(root: root)
        refresh()
        Task.detached(priority: .utility) { [weak self] in
            guard let dir = Bundle.main.url(forResource: "opencc", withExtension: nil),
                  let conv = S2TWConverter(directory: dir) else { return }
            await MainActor.run {
                guard let self, !self.converterLoaded else { return }
                self.pipeline.converter = conv; self.converterLoaded = true; self.objectWillChange.send()
            }
        }
        Demo.start(self)
    }

    /// 重新讀取全部設定（還原備份後）
    func reloadAll() {
        prefs.load()
        store.load()
        style = ReadStyle.from(json: prefs.string("style")) ?? ReadStyle()
        night = prefs.bool("night"); followSystem = prefs.bool("followSystem")
        pageMode = prefs.int("pageMode"); keepOn = prefs.bool("keepOn", true)
        statusBar = prefs.bool("statusBar"); dualPage = prefs.bool("dualPage", true)
        brightness = prefs.double("brightness", -1)
        let z = prefs.string("tapZones")
        tapZones = z.count == 9 ? z.compactMap { Int(String($0)) } : Self.defaultZones
        chineseMode = prefs.int("chineseMode", 1)
        ttsRate = prefs.double("ttsRate", 1); ttsPitch = prefs.double("ttsPitch", 1)
        rules = RulesStore.load(root: root); pipeline.rules = rules; rulesVersion += 1
        Fonts.registerAll(root: root); fontsVersion += 1
        Backgrounds.reset()
        refresh()
    }

    func ensureConverter() {
        if converterLoaded { return }
        if let dir = Bundle.main.url(forResource: "opencc", withExtension: nil), let conv = S2TWConverter(directory: dir) {
            pipeline.converter = conv
        }
        converterLoaded = true
    }

    func applyChinese() { pipeline.chineseOn = chineseMode == 1 }
    func title(_ s: String) -> String { converterLoaded ? pipeline.title(s) : s }

    func refresh() {
        books = store.books.sorted { ($0.lastReadAt, $0.addedAt) > ($1.lastReadAt, $1.addedAt) }
    }

    // ── 規則 ──
    func saveRules(_ r: [ReplaceRule]) {
        rules = r; pipeline.rules = r; RulesStore.save(r, root: root); rulesVersion += 1
    }
    func upsertRule(_ r: ReplaceRule) {
        var l = rules
        if let i = l.firstIndex(where: { $0.id == r.id }) { l[i] = r } else { l.append(r) }
        saveRules(l)
    }

    // ── 分組 ──
    var groups: [String] { Groups.all(prefs) }
    func addGroup(_ g: String) {
        let t = g.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !groups.contains(t) else { return }
        Groups.save(prefs, groups + [t]); objectWillChange.send()
    }
    func renameGroup(_ old: String, _ new: String) {
        let t = new.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !groups.contains(t) else { return }
        Groups.save(prefs, groups.map { $0 == old ? t : $0 })
        for var b in store.books where b.group == old { b.group = t; store.update(b, save: false) }
        store.save(); refresh()
    }
    func deleteGroup(_ g: String) {
        Groups.save(prefs, groups.filter { $0 != g })
        for var b in store.books where b.group == g { b.group = ""; store.update(b, save: false) }
        store.save(); refresh()
    }
    func setGroup(_ b: Book, _ g: String) { var nb = b; nb.group = g; store.update(nb); refresh() }

    // ── 匯入 ──
    func importFiles(_ urls: [URL], openAfter: Bool = false, group: String? = nil) {
        importing = true
        Task {
            var ok: [Book] = []
            var failed: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: url, to: tmp)
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    await Task.yield()
                    var b = try store.importFile(tmp)
                    if let g = group, !g.isEmpty { b.group = g; store.update(b) }
                    ok.append(b)
                } catch {
                    failed.append(error.localizedDescription)
                }
            }
            importing = false
            refresh()
            var msg = ""
            if ok.count == 1 { msg = "已匯入《\(title(ok[0].title))》，共 \(ok[0].chapterCount) 章" }
            else if !ok.isEmpty { msg = "已匯入 \(ok.count) 本書" }
            if !failed.isEmpty { msg += (msg.isEmpty ? "" : "，") + "\(failed.count) 個檔案匯入失敗：\(failed[0])" }
            toast = msg
            if openAfter, ok.count == 1 { openBookId = ok[0].id }
        }
    }

    func delete(_ b: Book) {
        if tts.active && tts.bookId == b.id { tts.stop() }
        store.delete(b.id); refresh()
    }

    func rename(_ b: Book, _ title: String) { var nb = b; nb.title = title; store.update(nb); refresh() }
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

/// 匯入的字型：放在 fonts/，啟動時向系統註冊（只限本 App 使用）
enum Fonts {
    static var names: [String: String] = [:]     // 檔名 → PostScript 名稱

    static func dir(_ root: URL) -> URL { root.appendingPathComponent("fonts", isDirectory: true) }

    static func files(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir(root).path)) ?? []).sorted()
    }

    static func registerAll(root: URL) {
        for f in files(root) { register(dir(root).appendingPathComponent(f)) }
    }

    @discardableResult
    static func register(_ url: URL) -> String? {
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let d = descs.first,
              let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        names[url.lastPathComponent] = name
        return name
    }

    /// 匯入字型檔，回傳 fontKey
    static func importFont(_ src: URL, root: URL) -> String? {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.createDirectory(at: dir(root), withIntermediateDirectories: true)
        let dest = dir(root).appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.copyItem(at: src, to: dest)) != nil, register(dest) != nil else {
            try? FileManager.default.removeItem(at: dest); return nil
        }
        return "font:" + dest.lastPathComponent
    }

    static func delete(_ key: String, root: URL) {
        let f = String(key.dropFirst(5))
        let u = dir(root).appendingPathComponent(f)
        CTFontManagerUnregisterFontsForURL(u as CFURL, .process, nil)
        try? FileManager.default.removeItem(at: u)
        names[f] = nil
    }

    static func displayName(_ key: String) -> String {
        if key.isEmpty { return "系統預設" }
        if key == "serif" { return "系統襯線" }
        return (key.dropFirst(5) as Substring).split(separator: ".").dropLast().joined(separator: ".")
    }
}
