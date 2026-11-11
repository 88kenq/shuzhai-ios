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

struct ShelfView: View {
    @EnvironmentObject var model: AppModel
    @State private var showImporter = false
    @State private var renaming: Book?
    @State private var renameText = ""
    @State private var deleting: Book?

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 14)]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.page.ignoresSafeArea()
                if model.books.isEmpty {
                    VStack(spacing: 12) {
                        Text("書架是空的").font(.title3).foregroundColor(.muted)
                        Text("點右上角「匯入」加入 TXT 或 EPUB").foregroundColor(.muted)
                    }
                } else {
                    ScrollView {
                        if let last = model.books.first(where: { $0.lastReadAt > 0 }) { continueCard(last) }
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(model.books) { b in bookCell(b) }
                        }
                        .padding(.horizontal, 16).padding(.bottom, 24)
                    }
                }
                if model.importing {
                    ProgressView("正在匯入…").padding(24).background(.regularMaterial).cornerRadius(12)
                }
            }
            .navigationTitle("書齋")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Label("匯入", systemImage: "plus") }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.plainText, .text, UTType(filenameExtension: "epub") ?? .data, .data],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result, !urls.isEmpty { model.importFiles(urls) }
            }
            .fullScreenCover(item: Binding(get: { model.openBookId.map { IdBox(id: $0) } },
                                           set: { model.openBookId = $0?.id })) { box in
                ReaderScreen(app: model, bookId: box.id)
            }
            .alert("重新命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("書名", text: $renameText)
                Button("確定") { if let b = renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty { model.rename(b, renameText) } }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("確定刪除這本書？閱讀進度和書籤也會一起刪除。",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("刪除", role: .destructive) { if let b = deleting { model.delete(b) } }
            }
            .overlay(alignment: .bottom) {
                if let t = model.toast {
                    Text(t).padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.black.opacity(0.8)).foregroundColor(.white).cornerRadius(20).padding(.bottom, 30)
                        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.toast = nil } }
                }
            }
        }
        .tint(.accent)
        .onAppear { model.refresh() }
    }

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
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
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
            Button { model.openBookId = b.id } label: { Label("閱讀", systemImage: "book") }
            Button { renameText = b.title; renaming = b } label: { Label("重新命名", systemImage: "pencil") }
            Button(role: .destructive) { deleting = b } label: { Label("刪除", systemImage: "trash") }
        }
    }
}

struct IdBox: Identifiable { let id: String }

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
