import SwiftUI
import UIKit
import ShuZhaiCore

enum ReaderSheet: String, Identifiable { case toc, marks, search, rules, zones; var id: String { rawValue } }
enum ReaderPanel { case none, menu, style, tts }

struct ReaderScreen: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var scheme
    @StateObject private var model: ReaderModel
    @ObservedObject private var app: AppModel
    @ObservedObject private var tts: TtsController
    @State private var panel: ReaderPanel = .none
    @State private var sheet: ReaderSheet?
    @State private var sliderValue = 0.0
    @State private var askNote = false
    @State private var noteText = ""
    @State private var longPress: LongPressInfo?
    @State private var showResplit = false
    @State private var ruleSample: String?
    @State private var savedBrightness: CGFloat = -1

    struct LongPressInfo { let text: String; let chapter: Int; let start: Int }

    init(app: AppModel, bookId: String) {
        _model = StateObject(wrappedValue: ReaderModel(app: app, bookId: bookId))
        _app = ObservedObject(wrappedValue: app)
        _tts = ObservedObject(wrappedValue: app.tts)
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                ReaderCanvas(model: model, onTap: tap, onLongPress: longPressed)
                    .ignoresSafeArea()
                    .onAppear { model.setGeometry(size: fullSize(g), safe: g.safeAreaInsets, dark: scheme == .dark) }
                    .onChange(of: g.size) { _ in model.setGeometry(size: fullSize(g), safe: g.safeAreaInsets, dark: scheme == .dark) }
                    .onChange(of: scheme) { s in model.setGeometry(size: fullSize(g), safe: g.safeAreaInsets, dark: s == .dark) }
                HeaderFooter(model: model, safe: g.safeAreaInsets).allowsHitTesting(false)
                switch panel {
                case .menu: menuOverlay
                case .style: bottomPanel { StylePanel(app: app, model: model) }
                case .tts: bottomPanel { TtsPanel(app: app, model: model) }
                case .none: EmptyView()
                }
                if let msg = model.message {
                    Text(msg).padding(.horizontal, 16).padding(.vertical, 10).background(Color.black.opacity(0.8))
                        .foregroundColor(.white).cornerRadius(20).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 90)
                        .allowsHitTesting(false)
                        .task(id: msg) { try? await Task.sleep(nanoseconds: 1_500_000_000); model.message = nil }
                }
            }
        }
        .statusBarHidden(!(app.statusBar || panel == .menu))
        .persistentSystemOverlays(.hidden)
        .sheet(item: $sheet) { s in sheetView(s) }
        .alert("加入書籤", isPresented: $askNote) {
            TextField("備註（可不填）", text: $noteText)
            Button("加入") { model.addBookmark(note: noteText) }
            Button("取消", role: .cancel) {}
        } message: { Text("\(model.title(model.chapter))\n\(model.excerpt())…") }
        .confirmationDialog(longPress.map { String($0.text.prefix(40)) } ?? "",
                            isPresented: Binding(get: { longPress != nil }, set: { if !$0 { longPress = nil } }),
                            titleVisibility: .visible) {
            Button("從這裡開始朗讀") {
                if let lp = longPress { tts.start(bookId: model.book.id, chapter: lp.chapter, offset: lp.start) }
                longPress = nil
            }
            Button("建立取代規則") { ruleSample = longPress?.text; sheet = .rules; longPress = nil }
            Button("複製這一段") { UIPasteboard.general.string = longPress?.text; model.message = "已複製"; longPress = nil }
        }
        .confirmationDialog("重新切目錄（目前：\(model.book.ruleName)）。重切後書籤會清除。", isPresented: $showResplit, titleVisibility: .visible) {
            Button("自動判斷") { model.resplit(-1) }
            ForEach(Array(ChapterSplitter.rules.enumerated()), id: \.offset) { item in Button(item.element.name) { model.resplit(item.offset) } }
            Button("不切章，每 5000 字分段") { model.resplit(999) }
        }
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in model.flush() }
        .onChange(of: app.style) { _ in model.relayout() }
        .onChange(of: app.night) { _ in model.relayout() }
        .onChange(of: app.followSystem) { _ in model.relayout() }
        .onChange(of: app.pageMode) { _ in model.relayout() }
        .onChange(of: app.dualPage) { _ in model.relayout() }
        .onChange(of: app.statusBar) { _ in model.relayout() }
        .onChange(of: app.keepOn) { v in UIApplication.shared.isIdleTimerDisabled = v }
        .onChange(of: app.brightness) { _ in applyBrightness() }
        .onChange(of: app.fontsVersion) { _ in model.relayout() }
    }

    func fullSize(_ g: GeometryProxy) -> CGSize {
        CGSize(width: g.size.width + g.safeAreaInsets.leading + g.safeAreaInsets.trailing,
               height: g.size.height + g.safeAreaInsets.top + g.safeAreaInsets.bottom)
    }

    func appear() {
        UIApplication.shared.isIdleTimerDisabled = app.keepOn
        UIDevice.current.isBatteryMonitoringEnabled = true
        savedBrightness = UIScreen.main.brightness
        applyBrightness()
        Demo.drive(model: model, panel: $panel, sheet: $sheet)
    }

    func disappear() {
        model.flush()
        UIApplication.shared.isIdleTimerDisabled = false
        if app.brightness >= 0, savedBrightness >= 0 { UIScreen.main.brightness = savedBrightness }
    }

    func applyBrightness() {
        if app.brightness >= 0 { UIScreen.main.brightness = CGFloat(app.brightness) }
        else if savedBrightness >= 0 { UIScreen.main.brightness = savedBrightness }
    }

    // ── 點擊：九宮格 ──
    func tap(_ p: CGPoint, _ size: CGSize) {
        if panel != .none { panel = .none; return }
        let col = min(2, max(0, Int(p.x / size.width * 3))), row = min(2, max(0, Int(p.y / size.height * 3)))
        let zones = app.tapZones.count == 9 ? app.tapZones : AppModel.defaultZones
        switch zones[row * 3 + col] {
        case 1: model.next()
        case 2: model.prev()
        case 3: sliderValue = Double(model.chapter); panel = .menu
        default: break
        }
    }

    func longPressed(_ ch: Int, _ idx: Int) {
        panel = .none
        if let p = model.paragraph(chapter: ch, at: idx) { longPress = LongPressInfo(text: p.0, chapter: ch, start: p.1) }
    }

    @ViewBuilder func sheetView(_ s: ReaderSheet) -> some View {
        switch s {
        case .toc, .marks:
            TocSheet(model: model, startTab: s == .marks ? 1 : 0) { ch, off in sheet = nil; panel = .none; model.jump(chapter: ch, offset: off) }
        case .search:
            SearchSheet(model: model) { ch, off, len in sheet = nil; panel = .none; model.jump(chapter: ch, offset: off, highlight: len) }
        case .rules:
            RulesView(app: app, bookId: model.book.id, bookTitle: app.title(model.book.title), sample: ruleSample)
        case .zones:
            TapZonesView(app: app)
        }
    }

    // ── 選單 ──
    var barBg: Color { Color.black.opacity(0.88) }

    var menuOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button { model.flush(); dismiss() } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)) }
                Text(app.title(model.book.title)).font(.headline).lineLimit(1)
                Spacer()
                Button { noteText = ""; askNote = true } label: { Image(systemName: "bookmark") }
                Button { sheet = .search } label: { Image(systemName: "magnifyingglass") }
                Menu {
                    Button { ruleSample = nil; sheet = .rules } label: { Label("取代規則", systemImage: "text.badge.checkmark") }
                    Button { sheet = .marks } label: { Label("書籤列表", systemImage: "bookmark.fill") }
                    Button { sheet = .zones } label: { Label("點擊區域", systemImage: "square.grid.3x3") }
                    if model.book.format != "epub" {
                        Button { showResplit = true } label: { Label("重新切目錄", systemImage: "list.number") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            .font(.title3)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity).background(barBg)
            Color.clear.contentShape(Rectangle()).onTapGesture { panel = .none }
            VStack(spacing: 10) {
                Text(model.title(Int(sliderValue.rounded()))).font(.footnote).lineLimit(1)
                HStack(spacing: 12) {
                    Button("上一章") { model.prevChapter(); sliderValue = Double(model.chapter) }
                    Slider(value: $sliderValue, in: 0...Double(max(1, model.toc.count - 1)), step: 1,
                           onEditingChanged: { editing in if !editing { model.open(Int(sliderValue.rounded())) } })
                    Button("下一章") { model.nextChapter(); sliderValue = Double(model.chapter) }
                }
                .font(.subheadline)
                HStack(spacing: 0) {
                    barButton("目錄", "list.bullet") { sheet = .toc }
                    barButton("字小", "textformat.size.smaller") { app.style.fontSize = max(12, app.style.fontSize - 1) }
                    Text("\(app.style.fontSize)").font(.headline).frame(maxWidth: .infinity)
                    barButton("字大", "textformat.size.larger") { app.style.fontSize = min(40, app.style.fontSize + 1) }
                    barButton("介面", "textformat") { panel = .style }
                    barButton("朗讀", "headphones") { panel = .tts }
                    barButton(model.isNight ? "日間" : "夜間", model.isNight ? "sun.max" : "moon") { toggleNight() }
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            .frame(maxWidth: .infinity).background(barBg)
        }
        .foregroundColor(Color(white: 0.93))
        .tint(Color(UIColor(rgb: 0xD9A866)))
    }

    func toggleNight() {
        let n = !model.isNight
        if app.followSystem && n != model.systemDark { app.followSystem = false; model.message = "已關閉「跟隨系統深色模式」" }
        app.night = n
    }

    func barButton(_ t: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.title3)
                Text(t).font(.caption2).lineLimit(1).minimumScaleFactor(0.6)
            }.frame(maxWidth: .infinity)
        }
    }

    func bottomPanel<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            Color.clear.contentShape(Rectangle()).onTapGesture { panel = .none }
            content()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: UIScreen.main.bounds.height * 0.52)
                .background(barBg.ignoresSafeArea(edges: .bottom))
                .foregroundColor(Color(white: 0.93))
                .tint(Color(UIColor(rgb: 0xD9A866)))
        }
    }
}

/// 頁首章名、頁尾時間電量頁碼
struct HeaderFooter: View {
    @ObservedObject var model: ReaderModel
    let safe: EdgeInsets

    var body: some View {
        let s = model.app.style
        let color = Color(model.theme.info)
        VStack(spacing: 0) {
            if s.showHeader && !(model.layout != nil && model.pageIndex == 0 && !model.scrollMode) {
                Text(model.title(model.chapter)).font(.system(size: 12)).foregroundColor(color).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, max(safe.top, 10) + 6)
            }
            Spacer(minLength: 0)
            TimelineView(.everyMinute) { ctx in
                HStack {
                    Text(leftText(ctx.date))
                    Spacer()
                    Text(rightText)
                }
                .font(.system(size: 12).monospacedDigit()).foregroundColor(color)
            }
            .padding(.bottom, max(safe.bottom, 8) + 6)
        }
        .padding(.leading, model.contentInsets.left).padding(.trailing, model.contentInsets.right)
        .ignoresSafeArea()
    }

    func leftText(_ d: Date) -> String {
        let s = model.app.style
        var parts: [String] = []
        if s.showTime { let f = DateFormatter(); f.dateFormat = "HH:mm"; parts.append(f.string(from: d)) }
        let bat = UIDevice.current.batteryLevel
        if s.showBattery && bat >= 0 { parts.append("電量 \(Int(bat * 100))%") }
        return parts.joined(separator: "  ")
    }

    var rightText: String {
        let s = model.app.style
        var parts: [String] = []
        if s.showPage { parts.append(model.pageLabel) }
        if s.showPercent { parts.append(String(format: "%.1f%%", model.percent * 100)) }
        return parts.joined(separator: "   ")
    }
}

/// 背景＋翻頁或捲動畫面
struct ReaderCanvas: UIViewRepresentable {
    @ObservedObject var model: ReaderModel
    let onTap: (CGPoint, CGSize) -> Void
    let onLongPress: (Int, Int) -> Void

    final class Container: UIView {
        let bg = UIImageView()
        let page = PageView(frame: .zero)
        let scroll = ScrollReaderView(frame: .zero)
        override init(frame: CGRect) {
            super.init(frame: frame)
            bg.contentMode = .scaleAspectFill; bg.clipsToBounds = true
            addSubview(bg); addSubview(page); addSubview(scroll)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() {
            super.layoutSubviews()
            bg.frame = bounds; page.frame = bounds
        }
    }

    func makeUIView(context: Context) -> Container {
        let v = Container(frame: .zero)
        let m = model
        m.scrollView = v.scroll
        v.scroll.provider = { [weak m] ch in m?.scrollChapter(ch) }
        v.scroll.marksFor = { [weak m] ch in m?.marks(for: ch) ?? [] }
        v.scroll.onPosition = { [weak m] ch, off, frac in m?.scrolled(chapter: ch, offset: off, frac: frac) }
        v.page.onSwipe = { [weak m] left in if left { m?.next() } else { m?.prev() } }
        return v
    }

    func updateUIView(_ v: Container, context: Context) {
        let theme = model.theme
        v.backgroundColor = theme.bg
        switch theme.texture {
        case 1, 2:
            v.bg.image = nil
            v.bg.backgroundColor = UIColor(patternImage: Backgrounds.texture(theme.texture, base: theme.bg))
        case 3:
            v.bg.backgroundColor = theme.bg
            v.bg.image = Backgrounds.photo(root: model.app.root, size: model.viewSize, blur: model.app.style.imageBlur, dim: model.app.style.imageDim)
        default:
            v.bg.image = nil; v.bg.backgroundColor = theme.bg
        }
        v.page.onTap = { p in onTap(p, v.bounds.size) }
        v.scroll.onTap = { p in onTap(p, v.bounds.size) }
        v.page.onLongPress = onLongPress
        v.scroll.onLongPress = onLongPress
        let ins = model.contentInsets
        if model.scrollMode {
            v.page.isHidden = true; v.scroll.isHidden = false
            let f = CGRect(x: 0, y: ins.top, width: model.viewSize.width, height: max(0, model.viewSize.height - ins.top - ins.bottom))
            if v.scroll.frame != f { v.scroll.frame = f }
        } else {
            v.page.isHidden = false; v.scroll.isHidden = true
            var cols: [PageView.Column] = []
            if let l = model.layout {
                for (k, r) in model.columnRects.enumerated() where model.pageIndex + k < l.pages.count {
                    cols.append(PageView.Column(layout: l, page: model.pageIndex + k, rect: r))
                }
            }
            v.page.columns = cols
            v.page.marks = model.layout.map { model.marks(for: $0.chapter) } ?? []
            v.page.setNeedsDisplay()
        }
        _ = model.redraw
    }
}
