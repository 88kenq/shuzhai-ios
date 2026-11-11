import SwiftUI
import ShuZhaiCore

/// 閱讀狀態：目前章節、排版、頁碼、進度
@MainActor
final class ReaderModel: ObservableObject {
    let app: AppModel
    @Published var book: Book
    let toc: [TocEntry]
    @Published var chapter = 0
    @Published var pageIndex = 0
    @Published var layout: ChapterLayout?
    @Published var message: String?
    let typesetter = Typesetter()
    var pageSize: CGSize = .zero
    private var richCache: [Int: Rich] = [:]
    private var titleCache: [Int: String] = [:]

    init(app: AppModel, bookId: String) {
        self.app = app
        book = app.store.book(bookId) ?? Book(id: bookId, title: "", author: "", chapterCount: 0, ruleName: "", addedAt: 0)
        toc = app.store.toc(bookId)
        chapter = min(max(0, book.progChapter), max(0, toc.count - 1))
        app.ensureConverter()
        applySettings()
    }

    func applySettings() {
        typesetter.fontSize = CGFloat(app.settings.fontSize)
        typesetter.theme = app.settings.night ? .night : .day
    }

    func rich(_ i: Int) -> Rich {
        if let r = richCache[i] { return r }
        let r = app.pipeline.rich(book.id, i)
        if richCache.count > 4 { richCache.removeAll() }
        richCache[i] = r
        return r
    }

    func title(_ i: Int) -> String {
        if let t = titleCache[i] { return t }
        let t = i < toc.count ? app.title(toc[i].title) : ""
        titleCache[i] = t
        return t
    }

    var currentOffset: Int {
        guard let l = layout, pageIndex < l.pages.count else { return book.progOffset }
        return l.pages[pageIndex].location
    }

    /// 打開某章的某個位置（toLast＝最後一頁）
    func open(_ ch: Int, offset: Int = 0, toLast: Bool = false) {
        guard !toc.isEmpty, pageSize.width > 0 else { chapter = ch; return }
        chapter = min(max(0, ch), toc.count - 1)
        let l = typesetter.layout(chapter: chapter, rich: rich(chapter), title: title(chapter),
                                  imageURL: { [app, book] n in app.store.imageDir(book.id).appendingPathComponent(n) }, pageSize: pageSize)
        layout = l
        pageIndex = toLast ? l.pages.count - 1 : l.page(containing: offset)
        saveProgress()
    }

    /// 字級、主題、畫面大小改了：重新排版但停在同一句
    func relayout(size: CGSize? = nil) {
        let keep = layout == nil ? book.progOffset : currentOffset
        if let s = size { pageSize = s }
        applySettings()
        open(chapter, offset: keep)
    }

    func next() {
        guard let l = layout else { return }
        if pageIndex < l.pages.count - 1 { pageIndex += 1; saveProgress() }
        else if chapter < toc.count - 1 { open(chapter + 1) }
        else { message = "已經是最後一頁了" }
    }

    func prev() {
        if pageIndex > 0 { pageIndex -= 1; saveProgress() }
        else if chapter > 0 { open(chapter - 1, toLast: true) }
        else { message = "已經是第一頁了" }
    }

    var percent: Double {
        guard let l = layout, !toc.isEmpty else { return 0 }
        return min(1, (Double(chapter) + Double(pageIndex + 1) / Double(max(1, l.pages.count))) / Double(toc.count))
    }

    private var saveWork: DispatchWorkItem?
    func saveProgress() {
        book.progChapter = chapter
        book.progOffset = currentOffset
        book.progPercent = percent
        book.lastReadAt = nowMillis()
        saveWork?.cancel()
        let b = book
        let w = DispatchWorkItem { [weak app] in app?.saveProgress(b) }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    func flush() { saveWork?.cancel(); app.saveProgress(book); app.refresh() }
}

struct ReaderScreen: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var model: ReaderModel
    @State private var menu = false
    @State private var showToc = false

    init(app: AppModel, bookId: String) {
        _model = StateObject(wrappedValue: ReaderModel(app: app, bookId: bookId))
    }

    var body: some View {
        let m = model
        ReaderContent(model: m, menu: $menu, showToc: $showToc, close: { m.flush(); dismiss() })
            .statusBarHidden(!menu)
            .persistentSystemOverlays(.hidden)
            .sheet(isPresented: $showToc) {
                TocSheet(model: m) { ch in showToc = false; menu = false; m.open(ch) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in m.flush() }
    }
}

struct ReaderContent: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var settings: ReaderSettings
    @Binding var menu: Bool
    @Binding var showToc: Bool
    let close: () -> Void
    @State private var sliderValue: Double = 0

    init(model: ReaderModel, menu: Binding<Bool>, showToc: Binding<Bool>, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model); _settings = ObservedObject(wrappedValue: model.app.settings)
        _menu = menu; _showToc = showToc; self.close = close
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                Color(model.typesetter.theme.bg).ignoresSafeArea()
                PageCanvas(model: model, safe: g.safeAreaInsets, onTap: { p, size in tap(p, size) })
                    .ignoresSafeArea()
                if menu { menuOverlay }
                if let msg = model.message {
                    Text(msg).padding(.horizontal, 16).padding(.vertical, 10).background(.black.opacity(0.8))
                        .foregroundColor(.white).cornerRadius(20).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 80)
                        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.message = nil } }
                }
            }
        }
    }

    /// 九宮格：中間叫出選單，其他都是下一頁
    func tap(_ p: CGPoint, _ size: CGSize) {
        if menu { menu = false; return }
        let col = min(2, Int(p.x / size.width * 3)), row = min(2, Int(p.y / size.height * 3))
        if col == 1 && row == 1 { sliderValue = Double(model.chapter); menu = true } else { model.next() }
    }

    var menuOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: close) { Image(systemName: "chevron.left").font(.title3.weight(.semibold)) }
                Text(model.app.title(model.book.title)).font(.headline).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity).background(Color.black.opacity(0.88))
            Spacer().contentShape(Rectangle()).onTapGesture { menu = false }
            VStack(spacing: 10) {
                Text(model.title(Int(sliderValue.rounded()))).font(.footnote).lineLimit(1)
                HStack {
                    Button("上一章") { if model.chapter > 0 { model.open(model.chapter - 1); sliderValue = Double(model.chapter) } }
                    Slider(value: $sliderValue, in: 0...Double(max(1, model.toc.count - 1)), step: 1,
                           onEditingChanged: { editing in if !editing { model.open(Int(sliderValue.rounded())) } })
                    Button("下一章") { if model.chapter < model.toc.count - 1 { model.open(model.chapter + 1); sliderValue = Double(model.chapter) } }
                }
                HStack {
                    barButton("目錄", "list.bullet") { showToc = true }
                    barButton("小", "textformat.size.smaller") { changeFont(-1) }
                    Text("\(Int(settings.fontSize))").frame(maxWidth: .infinity)
                    barButton("大", "textformat.size.larger") { changeFont(1) }
                    barButton(settings.night ? "日間" : "夜間", settings.night ? "sun.max" : "moon") {
                        settings.night.toggle(); model.relayout()
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            .frame(maxWidth: .infinity).background(Color.black.opacity(0.88))
        }
        .foregroundColor(Color(white: 0.93))
        .tint(Color(UIColor(rgb: 0xD9A866)))
    }

    func barButton(_ t: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) { Image(systemName: icon).font(.title3); Text(t).font(.caption2).lineLimit(1) }.frame(maxWidth: .infinity)
        }
    }

    func changeFont(_ d: Double) {
        settings.fontSize = min(40, max(12, settings.fontSize + d))
        model.relayout()
    }
}

/// 把 UIKit 的 PageView 放進 SwiftUI
struct PageCanvas: UIViewRepresentable {
    @ObservedObject var model: ReaderModel
    let safe: EdgeInsets
    let onTap: (CGPoint, CGSize) -> Void

    func makeUIView(context: Context) -> PageView {
        let v = PageView(frame: .zero)
        v.onSwipe = { left in left ? model.next() : model.prev() }
        return v
    }

    func updateUIView(_ v: PageView, context: Context) {
        v.onTap = { p in onTap(p, v.bounds.size) }
        let insets = UIEdgeInsets(top: safe.top + 44, left: max(20, safe.leading + 12), bottom: max(safe.bottom, 8) + 34, right: max(20, safe.trailing + 12))
        let changed = v.contentInsets != insets
        v.contentInsets = insets
        v.headerTop = safe.top + 14
        v.footerBottom = max(safe.bottom, 8) + 4
        v.theme = model.typesetter.theme
        DispatchQueue.main.async {
            let size = CGSize(width: v.bounds.width - insets.left - insets.right, height: v.bounds.height - insets.top - insets.bottom)
            if size.width > 0, size.height > 0, changed || size != model.pageSize || model.layout == nil {
                model.relayout(size: size)
            }
        }
        v.layoutData = model.layout
        v.pageIndex = model.pageIndex
        v.headerText = model.title(model.chapter)
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        UIDevice.current.isBatteryMonitoringEnabled = true
        let bat = UIDevice.current.batteryLevel
        v.footerLeft = f.string(from: Date()) + (bat >= 0 ? "  電量 \(Int(bat * 100))%" : "")
        let pages = model.layout?.pages.count ?? 1
        v.footerRight = "\(model.pageIndex + 1)/\(pages)   " + String(format: "%.1f%%", model.percent * 100)
        v.setNeedsDisplay()
    }
}

struct TocSheet: View {
    @ObservedObject var model: ReaderModel
    let onPick: (Int) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(filtered, id: \.self) { i in
                        Button { onPick(i) } label: {
                            Text(model.title(i)).lineLimit(1)
                                .fontWeight(i == model.chapter ? .bold : .regular)
                                .foregroundColor(i == model.chapter ? Color.accent : Color.ink)
                        }
                        .id(i)
                    }
                }
                .listStyle(.plain)
                .searchable(text: $query, prompt: "搜尋章名")
                .onAppear { proxy.scrollTo(model.chapter, anchor: .center) }
            }
            .navigationTitle("目錄（共 \(model.toc.count) 章）")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    var filtered: [Int] {
        let all = Array(model.toc.indices)
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { model.title($0).localizedCaseInsensitiveContains(q) }
    }
}
