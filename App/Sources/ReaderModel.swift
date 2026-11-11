import SwiftUI
import Combine
import ShuZhaiCore

/// 閱讀狀態：章節、排版、頁碼、捲動位置、標示、進度
@MainActor
final class ReaderModel: ObservableObject {
    let app: AppModel
    @Published var book: Book
    @Published var toc: [TocEntry]
    @Published var chapter = 0
    @Published var pageIndex = 0              // 翻頁模式：目前這一頁（雙頁時是左頁）的欄號
    @Published var layout: ChapterLayout?
    @Published var message: String?
    @Published var cols = 1
    @Published var scrollFrac = 0.0
    @Published var redraw = 0                 // 標示改變時重畫
    let typesetter = Typesetter()

    // 版面
    var viewSize: CGSize = .zero
    var safe = EdgeInsets()
    var systemDark = false
    private(set) var columnSize: CGSize = .zero
    private(set) var columnRects: [CGRect] = []
    private(set) var contentInsets = UIEdgeInsets()
    var scrollMode: Bool { app.pageMode == 1 }
    weak var scrollView: ScrollReaderView?

    private var richCache: [Int: Rich] = [:]
    private var titleCache: [Int: String] = [:]
    private var scrollCache: [Int: ScrollChapter] = [:]
    private var scrollOffset = 0
    private var bag = Set<AnyCancellable>()

    var searchMark: (chapter: Int, range: NSRange)?
    var ttsMark: (chapter: Int, range: NSRange)?

    init(app: AppModel, bookId: String) {
        self.app = app
        book = app.store.book(bookId) ?? Book(id: bookId, title: "", author: "", chapterCount: 0, ruleName: "", addedAt: 0)
        toc = app.store.toc(bookId)
        chapter = min(max(0, book.progChapter), max(0, toc.count - 1))
        scrollOffset = book.progOffset
        app.ensureConverter()
        typesetter.style = app.style
        typesetter.theme = theme
        // 朗讀進度 → 標示段落、自動翻頁
        app.tts.$state.receive(on: RunLoop.main).sink { [weak self] s in self?.ttsChanged(s) }.store(in: &bag)
        app.$rulesVersion.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.textChanged() } }.store(in: &bag)
        app.$chineseMode.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.textChanged() } }.store(in: &bag)
    }

    var isNight: Bool { app.followSystem ? systemDark : app.night }
    var theme: ReaderTheme { ReaderTheme.resolve(app.style, isNight ? app.style.nightTheme : app.style.dayTheme) }

    // ── 文字 ──
    func rich(_ i: Int) -> Rich {
        if let r = richCache[i] { return r }
        let r = app.pipeline.rich(book.id, i)
        if richCache.count > 6 { richCache.removeAll() }
        richCache[i] = r
        return r
    }

    func title(_ i: Int) -> String {
        if let t = titleCache[i] { return t }
        let t = i >= 0 && i < toc.count ? app.title(toc[i].title) : ""
        titleCache[i] = t
        return t
    }

    /// 繁簡、取代規則改了：清快取、重新排版，位置不變
    func textChanged() {
        richCache = [:]; titleCache = [:]
        relayout()
    }

    // ── 版面 ──
    func setGeometry(size: CGSize, safe: EdgeInsets, dark: Bool) {
        let changed = size != viewSize || safe != self.safe || dark != systemDark
        viewSize = size; self.safe = safe; systemDark = dark
        if changed || (layout == nil && !scrollMode) { relayout() }
    }

    private func computeGeometry() {
        let s = app.style
        let showFooter = s.showTime || s.showBattery || s.showPage || s.showPercent
        let headerH: CGFloat = s.showHeader ? 36 : 14, footerH: CGFloat = showFooter ? 32 : 14
        let top = max(safe.top, app.statusBar ? 0 : 0) + headerH + CGFloat(s.marginTop) + (safe.top > 0 ? 4 : 10)
        let bottom = max(safe.bottom, 8) + footerH + CGFloat(s.marginBottom)
        let left = CGFloat(s.marginH) + safe.leading, right = CGFloat(s.marginH) + safe.trailing
        contentInsets = UIEdgeInsets(top: top, left: left, bottom: bottom, right: right)
        cols = (!scrollMode && app.dualPage && viewSize.width > viewSize.height * 1.1) ? 2 : 1
        let gap: CGFloat = 32
        let w = max(40, (viewSize.width - left - right - gap * CGFloat(cols - 1)) / CGFloat(cols))
        let h = max(40, viewSize.height - top - bottom)
        columnSize = CGSize(width: w, height: h)
        columnRects = (0..<cols).map { CGRect(x: left + CGFloat($0) * (w + gap), y: top, width: w, height: h) }
    }

    /// 樣式、主題、畫面大小改了：重新排版但停在同一句
    func relayout() {
        let keep = currentOffset
        typesetter.style = app.style
        typesetter.theme = theme
        computeGeometry()
        guard viewSize.width > 0 else { return }
        if scrollMode {
            scrollCache = [:]
            layout = nil
            scrollView?.inset = contentInsets.left
            scrollView?.sepColor = theme.info
            scrollView?.lineStep = Typesetter.font(app.style, size: CGFloat(app.style.fontSize)).lineHeight * CGFloat(app.style.lineSpacing)
            scrollView?.chapterCount = toc.count
            scrollView?.reload()
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.scrollView?.scrollTo(chapter: self.chapter, offset: keep) }
        } else {
            open(chapter, offset: keep)
        }
        redraw += 1
    }

    private func chapterText(_ ch: Int, width: CGFloat) -> ChapterText {
        typesetter.make(chapter: ch, rich: rich(ch), title: title(ch), width: width,
                        maxImage: CGSize(width: width, height: columnSize.height * 0.92),
                        imageURL: { [app, book] n in app.store.imageDir(book.id).appendingPathComponent(n) })
    }

    func scrollChapter(_ ch: Int) -> ScrollChapter {
        if let c = scrollCache[ch] { return c }
        let c = ScrollChapter(ct: chapterText(ch, width: columnSize.width), width: columnSize.width)
        if scrollCache.count > 12 { scrollCache = scrollCache.filter { abs($0.key - ch) < 4 } }
        scrollCache[ch] = c
        return c
    }

    var currentOffset: Int {
        if scrollMode { return scrollOffset }
        guard let l = layout, pageIndex < l.pages.count else { return book.progOffset }
        return l.pages[pageIndex].location
    }

    /// 打開某章的某個位置（toLast＝最後一頁）
    func open(_ ch: Int, offset: Int = 0, toLast: Bool = false) {
        guard !toc.isEmpty else { return }
        let c = min(max(0, ch), toc.count - 1)
        if c != searchMark?.chapter { searchMark = nil }
        chapter = c
        if scrollMode {
            scrollOffset = offset
            scrollView?.scrollTo(chapter: c, offset: offset)
            saveProgress()
            return
        }
        guard columnSize.width > 0 else { scrollOffset = offset; book.progOffset = offset; return }
        let l = ChapterLayout(ct: chapterText(c, width: columnSize.width), column: columnSize)
        layout = l
        let p = toLast ? l.pages.count - 1 : l.page(containing: offset)
        pageIndex = p - p % cols
        saveProgress()
    }

    var spreadCount: Int { max(1, ((layout?.pages.count ?? 1) + cols - 1) / cols) }

    func next() {
        if scrollMode {
            if scrollView?.page(1) == false { message = "已經是最後一頁了" }
            return
        }
        guard let l = layout else { return }
        if pageIndex + cols < l.pages.count { pageIndex += cols; saveProgress() }
        else if chapter < toc.count - 1 { open(chapter + 1) }
        else { message = "已經是最後一頁了" }
    }

    func prev() {
        if scrollMode {
            if scrollView?.page(-1) == false { message = "已經是第一頁了" }
            return
        }
        if pageIndex > 0 { pageIndex = max(0, pageIndex - cols); saveProgress() }
        else if chapter > 0 { open(chapter - 1, toLast: true) }
        else { message = "已經是第一頁了" }
    }

    func nextChapter() { if chapter < toc.count - 1 { open(chapter + 1) } else { message = "已經是最後一章了" } }
    func prevChapter() { if chapter > 0 { open(chapter - 1) } else { message = "已經是第一章了" } }

    /// 捲動模式回報位置
    func scrolled(chapter ch: Int, offset: Int, frac: Double) {
        if ch != chapter { chapter = ch }
        scrollOffset = offset
        scrollFrac = frac
        saveProgress()
    }

    var percent: Double {
        guard !toc.isEmpty else { return 0 }
        let frac = scrollMode ? scrollFrac : Double(pageIndex / cols + 1) / Double(spreadCount)
        return min(1, (Double(chapter) + frac) / Double(toc.count))
    }

    var pageLabel: String {
        scrollMode ? "本章 \(Int(scrollFrac * 100))%" : "\(pageIndex / cols + 1)/\(spreadCount)"
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

    // ── 標示 ──
    func marks(for ch: Int) -> [(NSRange, UIColor)] {
        var m: [(NSRange, UIColor)] = []
        if let t = ttsMark, t.chapter == ch { m.append((t.range, theme.fg.withAlphaComponent(0.12))) }
        if let s = searchMark, s.chapter == ch { m.append((s.range, UIColor.systemYellow.withAlphaComponent(0.45))) }
        return m
    }

    func jump(chapter ch: Int, offset: Int, highlight: Int = 0) {
        searchMark = highlight > 0 ? (ch, NSRange(location: offset, length: highlight)) : nil
        open(ch, offset: offset)
        scrollView?.refreshMarks()
        redraw += 1
    }

    // ── 朗讀 ──
    private func ttsChanged(_ s: TtsController.State) {
        if s.active && s.bookId == book.id {
            ttsMark = (s.chapter, NSRange(location: s.paraStart, length: max(0, s.paraEnd - s.paraStart)))
            if s.playing { ensureVisible(chapter: s.chapter, offset: s.position) }
        } else {
            ttsMark = nil
        }
        scrollView?.refreshMarks()
        redraw += 1
    }

    func ensureVisible(chapter ch: Int, offset: Int) {
        if scrollMode { scrollView?.ensureVisible(chapter: ch, offset: offset); return }
        guard let l = layout, ch == chapter else { open(ch, offset: offset); return }
        let p = l.page(containing: offset)
        let target = p - p % cols
        if target != pageIndex { pageIndex = target; saveProgress() }
    }

    // ── 長按：整段文字 ──
    func paragraph(chapter ch: Int, at idx: Int) -> (String, Int)? {
        let u = Array(rich(ch).text.utf16)
        guard !u.isEmpty else { return nil }
        let i = min(max(0, idx), u.count - 1)
        var s = i; while s > 0 && u[s - 1] != 0x0A { s -= 1 }
        var e = i; while e < u.count && u[e] != 0x0A { e += 1 }
        let t = String(utf16CodeUnits: Array(u[s..<e]), count: e - s).trimmingCharacters(in: CharacterSet(charactersIn: " \u{3000}\t"))
        return t.isEmpty ? nil : (t, s)
    }

    // ── 書籤 ──
    func excerpt() -> String {
        let u = Array(rich(chapter).text.utf16)
        let s = min(currentOffset, u.count), e = min(u.count, s + 60)
        let t = String(utf16CodeUnits: Array(u[s..<e]), count: e - s)
        return String(t.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{3000}", with: "")
            .replacingOccurrences(of: "\u{FFFC}", with: "［圖］").trimmingCharacters(in: .whitespaces).prefix(40))
    }

    func addBookmark(note: String) {
        var l = app.store.bookmarks(book.id)
        l.append(Bookmark(chapter: chapter, offset: currentOffset, excerpt: excerpt(), note: note, time: nowMillis()))
        app.store.saveBookmarks(book.id, l)
        message = "已加入書籤"
    }

    func resplit(_ rule: Int) {
        guard let b = app.store.resplit(book.id, ruleIndex: rule) else { return }
        book = b
        toc = app.store.toc(book.id)
        richCache = [:]; titleCache = [:]
        chapter = 0
        relayout()
        open(0)
        message = "已重新切分：\(b.ruleName)，共 \(toc.count) 章"
    }
}
