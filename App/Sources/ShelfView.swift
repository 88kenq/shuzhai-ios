import SwiftUI
import UniformTypeIdentifiers
import ShuZhaiCore

extension Color {
    static let page = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x141414) : UIColor(rgb: 0xF7F3EA) })
    static let card = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x222222) : .white })
    static let ink = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0xDCD6CC) : UIColor(rgb: 0x2B2620) })
    static let muted = Color(UIColor(rgb: 0x8A8072))
    static let accent = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0xB9844F) : UIColor(rgb: 0x8C5A2B) })
}

extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ShelfView: View {
    @EnvironmentObject var model: AppModel
    @State private var showImporter = false
    @State private var renaming: Book?
    @State private var renameText = ""
    @State private var deleting: Book?
    @State private var group: String?            // nil＝全部
    @State private var askGroup = false
    @State private var groupText = ""
    @State private var groupTarget: Book?
    @State private var renamingGroup: String?
    @State private var showRules = false
    @State private var backupURL: URL?
    @State private var busy = false
    @State private var pickRestore = false
    @State private var confirmRestore: URL?
    @State private var showAbout = false

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 14)]

    var shown: [Book] { group == nil ? model.books : model.books.filter { $0.group == group } }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.page.ignoresSafeArea()
                ScrollView {
                    if let last = model.books.first(where: { $0.lastReadAt > 0 }) { continueCard(last) }
                    if !model.books.isEmpty { groupTabs }
                    if shown.isEmpty {
                        VStack(spacing: 12) {
                            Text(model.books.isEmpty ? "書架是空的" : "這個分組還沒有書").font(.title3).foregroundColor(.muted)
                            Text(model.books.isEmpty ? "點右上角「＋」匯入 TXT 或 EPUB" : "長按書本可以「移到分組」").foregroundColor(.muted)
                        }.padding(.top, 120)
                    } else {
                        LazyVGrid(columns: columns, spacing: 18) { ForEach(shown) { b in bookCell(b) } }
                            .padding(.horizontal, 16).padding(.bottom, 24)
                    }
                }
                if model.importing || busy {
                    ProgressView(busy ? "正在處理…" : "正在匯入…").padding(24).background(.regularMaterial).cornerRadius(12)
                }
            }
            .navigationTitle("書齋")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showRules = true } label: { Label("取代規則", systemImage: "text.badge.checkmark") }
                        Button { backup() } label: { Label("備份到檔案", systemImage: "square.and.arrow.up") }
                        Button { pickRestore = true } label: { Label("從備份還原", systemImage: "square.and.arrow.down") }
                        Button { showAbout = true } label: { Label("關於書齋", systemImage: "info.circle") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.plainText, .text, UTType(filenameExtension: "epub") ?? .data, .data],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result, !urls.isEmpty { model.importFiles(urls, group: group) }
            }
            .fullScreenCover(item: Binding(get: { model.openBookId.map { IdBox(id: $0) } }, set: { model.openBookId = $0?.id })) { box in
                ReaderScreen(app: model, bookId: box.id).environmentObject(model.tts)
            }
            .sheet(isPresented: $showRules) { RulesView(app: model, bookId: nil, bookTitle: nil, sample: nil) }
            .sheet(item: Binding(get: { backupURL.map { URLBox(url: $0) } }, set: { backupURL = $0?.url })) { b in ShareSheet(url: b.url) }
            .background(EmptyView().fileImporter(isPresented: $pickRestore, allowedContentTypes: [.zip, .data]) { r in
                if case .success(let u) = r { confirmRestore = u }
            })
            .alert("從備份還原", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })) {
                Button("還原", role: .destructive) { if let u = confirmRestore { restore(u) } }
                Button("取消", role: .cancel) {}
            } message: { Text("目前書架上的書、進度、書籤、取代規則和設定，都會換成備份檔裡的內容。Android 版的備份也可以還原。") }
            .alert("關於書齋", isPresented: $showAbout) { Button("好") {} } message: {
                Text("書齋 iPhone 版 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")\n本機 TXT／EPUB 閱讀器\n\n繁簡轉換使用 OpenCC 詞庫（Apache 2.0）\nEPUB 解析使用 SwiftSoup（MIT）與 ZIPFoundation（MIT）")
            }
            .alert("重新命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("書名", text: $renameText)
                Button("確定") { if let b = renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty { model.rename(b, renameText) } }
                Button("取消", role: .cancel) {}
            }
            .alert(renamingGroup == nil ? "新增分組" : "重新命名分組", isPresented: $askGroup) {
                TextField("分組名稱", text: $groupText)
                Button("確定") {
                    let t = groupText.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty {
                        if let old = renamingGroup { model.renameGroup(old, t); if group == old { group = t } }
                        else { model.addGroup(t); if let b = groupTarget { model.setGroup(b, t) } else { group = t } }
                    }
                    renamingGroup = nil; groupTarget = nil
                }
                Button("取消", role: .cancel) { renamingGroup = nil; groupTarget = nil }
            }
            .confirmationDialog("確定刪除這本書？閱讀進度和書籤也會一起刪除。",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("刪除", role: .destructive) { if let b = deleting { model.delete(b) } }
            }
            .overlay(alignment: .bottom) {
                if let t = model.toast {
                    Text(t).padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.black.opacity(0.8)).foregroundColor(.white).cornerRadius(20).padding(.bottom, 30)
                        .task(id: t) { try? await Task.sleep(nanoseconds: 3_000_000_000); model.toast = nil }
                }
            }
        }
        .tint(.accent)
        .onAppear { model.refresh() }
    }

    // ── 分組 ──
    var groupTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tab("全部 \(model.books.count)", group == nil) { group = nil }
                ForEach(model.groups, id: \.self) { g in
                    tab("\(g) \(model.books.filter { $0.group == g }.count)", group == g) { group = g }
                        .contextMenu {
                            Button { renamingGroup = g; groupText = g; askGroup = true } label: { Label("重新命名", systemImage: "pencil") }
                            Button(role: .destructive) { model.deleteGroup(g); if group == g { group = nil } } label: { Label("刪除分組（書不會刪除）", systemImage: "trash") }
                        }
                }
                tab("＋ 分組", false) { renamingGroup = nil; groupTarget = nil; groupText = ""; askGroup = true }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    func tab(_ t: String, _ sel: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.subheadline).lineLimit(1).padding(.horizontal, 14).padding(.vertical, 7)
                .background(sel ? Color.accent : Color.card).foregroundColor(sel ? .white : .ink).cornerRadius(16)
        }.buttonStyle(.plain)
    }

    // ── 備份與還原 ──
    func backup() {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("書齋備份-\(f.string(from: Date())).zip")
        busy = true
        Task {
            await Task.yield()
            do {
                try Backup.export(root: model.root, to: url, bookCount: model.books.count)
                busy = false
                backupURL = url
            } catch {
                busy = false
                model.toast = "備份失敗：\(error.localizedDescription)"
            }
        }
    }

    func restore(_ u: URL) {
        model.tts.stop()
        busy = true
        Task {
            await Task.yield()
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            do {
                let n = try Backup.restore(from: u, root: model.root)
                model.reloadAll()
                group = nil
                model.toast = "還原完成，共 \(n) 本書"
            } catch {
                model.toast = "還原失敗：\(error.localizedDescription)"
            }
            busy = false
        }
    }

    // ── 書本 ──
    func continueCard(_ b: Book) -> some View {
        let toc = model.store.toc(b.id)
        let ch = b.progChapter < toc.count ? model.title(toc[b.progChapter].title) : ""
        return Button { model.openBookId = b.id } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("上次讀到").font(.caption).foregroundColor(.muted)
                Text(model.title(b.title)).font(.headline).foregroundColor(.ink).lineLimit(1)
                Text("\(ch) · \(String(format: "%.1f%%", b.progPercent * 100))").font(.subheadline).foregroundColor(.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(Color.card).cornerRadius(14)
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 4)
    }

    func bookCell(_ b: Book) -> some View {
        let t = model.title(b.title)
        return Button { model.openBookId = b.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverView(title: t, cover: model.store.coverFile(b.id))
                Text(t).font(.subheadline).foregroundColor(.ink).lineLimit(2).multilineTextAlignment(.leading)
                Text(b.lastReadAt == 0 ? "未讀 · \(b.chapterCount) 章" : "讀到 \(String(format: "%.1f%%", b.progPercent * 100))")
                    .font(.caption).foregroundColor(.muted).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Text("\(b.format == "epub" ? "EPUB" : "TXT") · \(b.chapterCount) 章\(b.author.isEmpty ? "" : " · " + model.title(b.author))")
            Button { model.openBookId = b.id } label: { Label("閱讀", systemImage: "book") }
            Menu {
                Button("（不分組）") { model.setGroup(b, "") }
                ForEach(model.groups, id: \.self) { g in Button(g) { model.setGroup(b, g) } }
                Button("＋ 新增分組…") { renamingGroup = nil; groupTarget = b; groupText = ""; askGroup = true }
            } label: { Label("移到分組", systemImage: "folder") }
            Button { renameText = b.title; renaming = b } label: { Label("重新命名", systemImage: "pencil") }
            Button(role: .destructive) { deleting = b } label: { Label("刪除", systemImage: "trash") }
        }
    }
}

struct IdBox: Identifiable { let id: String }
struct URLBox: Identifiable { let url: URL; var id: String { url.path } }

/// 封面：EPUB 用書裡的封面，其他用書名產生
struct CoverView: View {
    let title: String
    let cover: URL?
    static let palette: [UInt32] = [0x8C5A2B, 0x3F6B5B, 0x4A5A86, 0x8A3E3E, 0x6B4E7A, 0x2F6A7A, 0x7A6A35, 0x555555]

    var body: some View {
        GeometryReader { g in
            ZStack {
                if let u = cover, let img = UIImage(contentsOfFile: u.path) {
                    Image(uiImage: img).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                } else {
                    let h = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFFFFFF }
                    Color(UIColor(rgb: Self.palette[h % Self.palette.count]))
                    RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.2), lineWidth: 1.5).padding(8)
                    Text(title).font(.system(size: max(12, g.size.width / 7.5), weight: .bold)).foregroundColor(.white)
                        .multilineTextAlignment(.center).lineLimit(4).padding(16)
                        .frame(maxHeight: .infinity, alignment: .top).padding(.top, g.size.height * 0.15)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
    }
}
