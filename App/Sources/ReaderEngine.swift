import UIKit
import CoreText
import ShuZhaiCore

/// 插圖在 CoreText 中佔的大小
final class ImageBox {
    let image: UIImage
    let size: CGSize
    init(image: UIImage, size: CGSize) { self.image = image; self.size = size }
}

let imageKey = NSAttributedString.Key("szImage")
let fgKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

/// 一章排好的文字（翻頁與捲動共用）
final class ChapterText {
    let chapter: Int
    let text: NSAttributedString
    let title: NSAttributedString
    let titleHeight: CGFloat
    let framesetter: CTFramesetter
    var boxes: [ImageBox]

    init(chapter: Int, text: NSAttributedString, title: NSAttributedString, titleHeight: CGFloat, boxes: [ImageBox]) {
        self.chapter = chapter; self.text = text; self.title = title; self.titleHeight = titleHeight; self.boxes = boxes
        framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
    }
}

/// 翻頁模式：把一章切成多欄（每欄＝一頁或雙頁的一半）
final class ChapterLayout {
    let ct: ChapterText
    let pages: [NSRange]
    var chapter: Int { ct.chapter }

    init(ct: ChapterText, column: CGSize) {
        self.ct = ct
        var pages: [NSRange] = []
        var loc = 0
        let len = ct.text.length
        var first = true
        while loc < len {
            let h = first ? column.height - ct.titleHeight : column.height
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: column.width, height: max(h, 1)), transform: nil)
            let frame = CTFramesetterCreateFrame(ct.framesetter, CFRange(location: loc, length: 0), path, nil)
            var visible = CTFrameGetVisibleStringRange(frame).length
            if visible <= 0 {
                if first { pages.append(NSRange(location: loc, length: 0)); first = false; continue }
                visible = 1
            }
            pages.append(NSRange(location: loc, length: visible))
            loc += visible
            first = false
        }
        if pages.isEmpty { pages.append(NSRange(location: 0, length: 0)) }
        self.pages = pages
    }

    func page(containing offset: Int) -> Int {
        var idx = 0
        for (i, p) in pages.enumerated() where p.location <= offset { idx = i }
        return idx
    }
}

/// 依排版樣式產生章節文字
final class Typesetter {
    var style = ReadStyle()
    var theme = ReaderTheme.presets[1]

    static func font(_ s: ReadStyle, size: CGFloat, bold: Bool = false) -> UIFont {
        let weight = bold ? 2 : s.weight
        if s.fontKey.hasPrefix("font:"), let name = Fonts.names[String(s.fontKey.dropFirst(5))], let f = UIFont(name: name, size: size) {
            if weight == 2, let d = f.fontDescriptor.withSymbolicTraits(.traitBold) { return UIFont(descriptor: d, size: size) }
            return f
        }
        if s.fontKey == "serif" {
            let w: UIFont.Weight = weight == 0 ? .light : weight == 2 ? .semibold : .regular
            let base = UIFont.systemFont(ofSize: size, weight: w)
            if let d = base.fontDescriptor.withDesign(.serif) { return UIFont(descriptor: d, size: size) }
            return base
        }
        let name = weight == 0 ? "PingFangTC-Light" : weight == 2 ? "PingFangTC-Semibold" : "PingFangTC-Regular"
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight == 2 ? .semibold : .regular)
    }

    func make(chapter: Int, rich: Rich, title: String, width: CGFloat, maxImage: CGSize, imageURL: (String) -> URL?,
              highlight: NSRange? = nil) -> ChapterText {
        let size = CGFloat(style.fontSize)
        let base = Self.font(style, size: size)
        let fg = theme.fg.cgColor
        let para = NSMutableParagraphStyle()
        para.lineSpacing = base.lineHeight * CGFloat(style.lineSpacing - 1)
        para.paragraphSpacing = base.lineHeight * CGFloat(style.paraSpacing)
        para.alignment = .justified
        para.lineBreakMode = .byWordWrapping
        let text = rich.text.isEmpty ? "（本章沒有內容）" : rich.text
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: base, fgKey: fg, .paragraphStyle: para, .kern: CGFloat(style.letterSpacing) * size,
        ])
        var boxes: [ImageBox] = []
        for sp in rich.spans where sp.end <= s.length && sp.start < sp.end {
            let r = NSRange(location: sp.start, length: sp.end - sp.start)
            switch sp.kind {
            case .bold: s.addAttribute(.font, value: Self.font(style, size: size, bold: true), range: r)
            case .italic:
                var m = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
                s.addAttribute(.font, value: CTFontCreateCopyWithAttributes(base as CTFont, size, &m, nil), range: r)
            case .center:
                let p = para.mutableCopy() as! NSMutableParagraphStyle
                p.alignment = .center
                s.addAttribute(.paragraphStyle, value: p, range: r)
            case .image(let name):
                guard let u = imageURL(name), let img = UIImage(contentsOfFile: u.path), img.size.width > 0 else { continue }
                let glyph = img.size.width <= 64 && img.size.height <= 64
                let sz: CGSize
                if glyph { sz = CGSize(width: size, height: size * img.size.height / img.size.width) }
                else {
                    let k = min(maxImage.width / img.size.width, maxImage.height / img.size.height, 3)
                    sz = CGSize(width: img.size.width * k, height: img.size.height * k)
                }
                let box = ImageBox(image: img, size: sz)
                boxes.append(box)
                var cb = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1, dealloc: { _ in },
                    getAscent: { Unmanaged<ImageBox>.fromOpaque($0).takeUnretainedValue().size.height },
                    getDescent: { _ in 0 },
                    getWidth: { Unmanaged<ImageBox>.fromOpaque($0).takeUnretainedValue().size.width })
                if let delegate = CTRunDelegateCreate(&cb, Unmanaged.passUnretained(box).toOpaque()) {
                    s.addAttribute(NSAttributedString.Key(kCTRunDelegateAttributeName as String), value: delegate, range: r)
                    s.addAttribute(imageKey, value: box, range: r)
                }
            }
        }
        if let h = highlight, h.location >= 0, h.location + h.length <= s.length, h.length > 0 {
            s.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.45), range: h)
        }
        let tp = NSMutableParagraphStyle(); tp.lineSpacing = 4
        let titleStr = NSAttributedString(string: title, attributes: [
            .font: Self.font(style, size: size * 1.35, bold: true), fgKey: fg, .paragraphStyle: tp, .kern: CGFloat(style.letterSpacing) * size,
        ])
        let fs = CTFramesetterCreateWithAttributedString(titleStr)
        let th = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                              CGSize(width: width, height: .greatestFiniteMagnitude), nil).height
        return ChapterText(chapter: chapter, text: s, title: titleStr, titleHeight: ceil(th) + 24, boxes: boxes)
    }
}

// MARK: - 共用繪圖

enum TextDraw {
    /// 在 CoreText 座標系（已翻轉）畫一個 frame 的指定行，並畫底色標示與插圖
    static func draw(frame: CTFrame, at origin: CGPoint, ctx: CGContext, marks: [(NSRange, UIColor)], clipY: ClosedRange<CGFloat>? = nil) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (i, line) in lines.enumerated() {
            var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
            let bx = origin.x + origins[i].x, by = origin.y + origins[i].y
            if let c = clipY, by + asc < c.lowerBound || by - desc > c.upperBound { continue }
            let lr = CTLineGetStringRange(line)
            for (r, color) in marks where r.length > 0 {
                let s = max(r.location, lr.location), e = min(r.location + r.length, lr.location + lr.length)
                if s >= e { continue }
                let x1 = CTLineGetOffsetForStringIndex(line, s, nil)
                let x2 = e >= lr.location + lr.length ? w : CTLineGetOffsetForStringIndex(line, e, nil)
                ctx.setFillColor(color.cgColor)
                ctx.fill(CGRect(x: bx + x1, y: by - desc - 2, width: max(0, x2 - x1), height: asc + desc + 4))
            }
            ctx.textPosition = CGPoint(x: bx, y: by)
            CTLineDraw(line, ctx)
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                guard let box = attrs[imageKey] as? ImageBox, let cg = box.image.cgImage else { continue }
                let x = CTLineGetOffsetForStringIndex(line, CTRunGetStringRange(run).location, nil)
                ctx.draw(cg, in: CGRect(x: bx + x, y: by, width: box.size.width, height: box.size.height))
            }
        }
    }

    /// 某點（CoreText 座標，相對 frame 原點）對應的字元位置
    static func index(frame: CTFrame, point p: CGPoint) -> Int? {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return nil }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var best = 0
        var bestD = CGFloat.greatestFiniteMagnitude
        for (i, line) in lines.enumerated() {
            var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
            CTLineGetTypographicBounds(line, &asc, &desc, &lead)
            let mid = origins[i].y + (asc - desc) / 2
            let d = abs(mid - p.y)
            if d < bestD { bestD = d; best = i }
        }
        let idx = CTLineGetStringIndexForPosition(lines[best], CGPoint(x: p.x - origins[best].x, y: 0))
        return idx == kCFNotFound ? CTLineGetStringRange(lines[best]).location : idx
    }
}

// MARK: - 翻頁模式

/// 畫一頁（或橫向時左右兩頁）
final class PageView: UIView {
    struct Column { let layout: ChapterLayout; let page: Int; let rect: CGRect }
    var columns: [Column] = []
    var marks: [(NSRange, UIColor)] = []
    var onTap: ((CGPoint) -> Void)?
    var onSwipe: ((Bool) -> Void)?           // true＝往左滑（下一頁）
    var onLongPress: ((Int, Int) -> Void)?   // 章、字元位置

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        let l = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:))); l.direction = .left
        let r = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:))); r.direction = .right
        addGestureRecognizer(l); addGestureRecognizer(r)
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func tapped(_ g: UITapGestureRecognizer) { onTap?(g.location(in: self)) }
    @objc func swiped(_ g: UISwipeGestureRecognizer) { onSwipe?(g.direction == .left) }
    @objc func pressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let p = g.location(in: self)
        for c in columns where c.rect.insetBy(dx: -10, dy: -10).contains(p) {
            let (frame, origin) = makeFrame(c)
            guard let frame else { return }
            let cp = CGPoint(x: p.x - origin.x, y: bounds.height - p.y - origin.y)
            if let i = TextDraw.index(frame: frame, point: cp) { onLongPress?(c.layout.chapter, i) }
            return
        }
    }

    /// 某欄的 CTFrame 與它在 CoreText 座標中的原點
    private func makeFrame(_ c: Column) -> (CTFrame?, CGPoint) {
        let range = c.layout.pages[c.page]
        var top = c.rect.minY
        if c.page == 0 { top += c.layout.ct.titleHeight }
        let h = c.rect.maxY - top
        guard range.length > 0, h > 0 else { return (nil, .zero) }
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: c.rect.width, height: h), transform: nil)
        let frame = CTFramesetterCreateFrame(c.layout.ct.framesetter, CFRange(location: range.location, length: range.length), path, nil)
        return (frame, CGPoint(x: c.rect.minX, y: bounds.height - c.rect.maxY))
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        for c in columns {
            if c.page == 0 {
                let fs = CTFramesetterCreateWithAttributedString(c.layout.ct.title)
                let tr = CGRect(x: c.rect.minX, y: bounds.height - c.rect.minY - c.layout.ct.titleHeight,
                                width: c.rect.width, height: c.layout.ct.titleHeight)
                CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: tr, transform: nil), nil), ctx)
            }
            let (frame, origin) = makeFrame(c)
            if let frame { TextDraw.draw(frame: frame, at: origin, ctx: ctx, marks: marks) }
        }
        ctx.restoreGState()
    }
}

// MARK: - 捲動模式

/// 捲動模式的一章：整章排成一個很高的 frame
final class ScrollChapter {
    let ct: ChapterText
    let frame: CTFrame
    let bodyHeight: CGFloat
    let width: CGFloat
    let lineTops: [CGFloat]       // 每行頂端（UIKit 座標，相對內文頂端）
    let lineStarts: [Int]
    let gap: CGFloat = 64
    var height: CGFloat { ct.titleHeight + bodyHeight + gap }

    init(ct: ChapterText, width: CGFloat) {
        self.ct = ct; self.width = width
        let sz = CTFramesetterSuggestFrameSizeWithConstraints(ct.framesetter, CFRange(location: 0, length: 0), nil,
                                                              CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        bodyHeight = ceil(sz.height) + 4
        frame = CTFramesetterCreateFrame(ct.framesetter, CFRange(location: 0, length: 0),
                                         CGPath(rect: CGRect(x: 0, y: 0, width: width, height: bodyHeight), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var tops: [CGFloat] = [], starts: [Int] = []
        for (i, l) in lines.enumerated() {
            var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
            CTLineGetTypographicBounds(l, &asc, &desc, &lead)
            tops.append(bodyHeight - origins[i].y - asc)
            starts.append(CTLineGetStringRange(l).location)
        }
        lineTops = tops; lineStarts = starts
    }

    /// 內文中某字元所在行的頂端 y（相對整章頂端，含標題）
    func y(of offset: Int) -> CGFloat {
        var idx = 0
        for (i, s) in lineStarts.enumerated() where s <= offset { idx = i }
        return ct.titleHeight + (lineTops.isEmpty ? 0 : lineTops[idx])
    }

    /// 整章中 y 位置（含標題）對應的第一個完整顯示的字元
    func offset(at y: CGFloat) -> Int {
        let by = y - ct.titleHeight
        if by <= 0 { return 0 }
        for (i, t) in lineTops.enumerated() where t >= by - 1 { return lineStarts[i] }
        return lineStarts.last ?? 0
    }
}

/// 不淡入的分塊圖層（不要動畫）
final class NoFadeTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

/// 捲動模式的一章畫面（分塊繪製，長章節也不吃記憶體）
final class ChapterTileView: UIView {
    override class var layerClass: AnyClass { NoFadeTiledLayer.self }
    var chapter: ScrollChapter? { didSet { setNeedsDisplay() } }
    var marks: [(NSRange, UIColor)] = [] { didSet { setNeedsDisplay() } }
    var inset: CGFloat = 20
    var sepColor: UIColor = .gray

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false
        (layer as! CATiledLayer).tileSize = CGSize(width: 1024, height: 1024)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let c = chapter, let ctx = UIGraphicsGetCurrentContext() else { return }
        let h = bounds.height
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        if rect.minY < c.ct.titleHeight {
            let fs = CTFramesetterCreateWithAttributedString(c.ct.title)
            let tr = CGRect(x: inset, y: h - c.ct.titleHeight, width: c.width, height: c.ct.titleHeight)
            CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: tr, transform: nil), nil), ctx)
        }
        let origin = CGPoint(x: inset, y: h - c.ct.titleHeight - c.bodyHeight)
        let clip = (h - rect.maxY - 40)...(h - rect.minY + 40)
        TextDraw.draw(frame: c.frame, at: origin, ctx: ctx, marks: marks, clipY: clip)
        ctx.restoreGState()
        // 章與章之間的分隔線
        let sy = c.ct.titleHeight + c.bodyHeight + c.gap / 2
        if rect.minY <= sy && rect.maxY >= sy {
            ctx.setFillColor(sepColor.cgColor)
            ctx.fill(CGRect(x: bounds.width / 2 - 24, y: sy, width: 48, height: 1))
        }
    }
}

final class ChapterCell: UITableViewCell {
    let tile = ChapterTileView(frame: .zero)
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear; contentView.backgroundColor = .clear; selectionStyle = .none
        contentView.addSubview(tile)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); tile.frame = contentView.bounds }
}

/// 捲動模式：每一章是一列，連續往下捲
final class ScrollReaderView: UIView, UITableViewDataSource, UITableViewDelegate {
    let table = UITableView(frame: .zero, style: .plain)
    var chapterCount = 0
    var provider: ((Int) -> ScrollChapter?)?
    var marksFor: ((Int) -> [(NSRange, UIColor)])?
    var onPosition: ((Int, Int, Double) -> Void)?    // 章、字元位置、本章比例
    var onTap: ((CGPoint) -> Void)?
    var onLongPress: ((Int, Int) -> Void)?
    var inset: CGFloat = 20
    var sepColor: UIColor = .gray
    var lineStep: CGFloat = 30
    private var suppress = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.showsVerticalScrollIndicator = false
        table.dataSource = self; table.delegate = self
        table.register(ChapterCell.self, forCellReuseIdentifier: "c")
        table.estimatedRowHeight = 3000
        table.contentInsetAdjustmentBehavior = .never
        table.clipsToBounds = true
        addSubview(table)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        table.addGestureRecognizer(tap)
        table.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() { super.layoutSubviews(); table.frame = bounds }

    func reload() { table.reloadData() }

    func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { chapterCount }
    func tableView(_ t: UITableView, heightForRowAt ip: IndexPath) -> CGFloat { provider?(ip.row)?.height ?? 100 }
    func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = t.dequeueReusableCell(withIdentifier: "c", for: ip) as! ChapterCell
        cell.tile.inset = inset
        cell.tile.sepColor = sepColor
        cell.tile.chapter = provider?(ip.row)
        cell.tile.marks = marksFor?(ip.row) ?? []
        return cell
    }

    func refreshMarks() {
        for case let cell as ChapterCell in table.visibleCells {
            if let ip = table.indexPath(for: cell) { cell.tile.marks = marksFor?(ip.row) ?? [] }
        }
    }

    /// 目前可視區頂端的章與位置
    func position() -> (Int, Int, Double)? {
        let y = table.contentOffset.y + 1
        guard let ip = table.indexPathForRow(at: CGPoint(x: 10, y: y)) ?? table.indexPathsForVisibleRows?.first,
              let c = provider?(ip.row) else { return nil }
        let r = table.rectForRow(at: ip)
        let within = y - r.minY
        return (ip.row, c.offset(at: within), Double(min(1, max(0, within / max(1, c.height - c.gap)))))
    }

    func scrollViewDidScroll(_ s: UIScrollView) {
        if suppress { return }
        if let p = position() { onPosition?(p.0, p.1, p.2) }
    }

    func scrollTo(chapter: Int, offset: Int) {
        guard chapter >= 0, chapter < chapterCount, let c = provider?(chapter) else { return }
        suppress = true
        table.layoutIfNeeded()
        let r = table.rectForRow(at: IndexPath(row: chapter, section: 0))
        let target = r.minY + (offset > 0 ? c.y(of: offset) : 0)
        table.setContentOffset(CGPoint(x: 0, y: min(max(0, target), max(0, table.contentSize.height - table.bounds.height))), animated: false)
        table.layoutIfNeeded()
        // 估計高度換成真實高度後再對準一次
        let r2 = table.rectForRow(at: IndexPath(row: chapter, section: 0))
        let t2 = r2.minY + (offset > 0 ? c.y(of: offset) : 0)
        table.setContentOffset(CGPoint(x: 0, y: min(max(0, t2), max(0, table.contentSize.height - table.bounds.height))), animated: false)
        suppress = false
        if let p = position() { onPosition?(p.0, p.1, p.2) }
    }

    /// 某位置若不在畫面上就捲過去（朗讀用）
    func ensureVisible(chapter: Int, offset: Int) {
        guard let c = provider?(chapter) else { return }
        let r = table.rectForRow(at: IndexPath(row: chapter, section: 0))
        let y = r.minY + c.y(of: offset)
        let top = table.contentOffset.y, bottom = top + table.bounds.height
        if y < top || y + lineStep > bottom { scrollTo(chapter: chapter, offset: offset) }
    }

    /// 一次捲一個畫面（保留一行），沒有動畫
    @discardableResult
    func page(_ dir: Int) -> Bool {
        let h = table.bounds.height - lineStep
        let maxY = max(0, table.contentSize.height - table.bounds.height)
        let before = table.contentOffset.y
        let ny = min(max(0, before + CGFloat(dir) * h), maxY)
        table.setContentOffset(CGPoint(x: 0, y: ny), animated: false)
        return abs(ny - before) > 1
    }

    @objc func tapped(_ g: UITapGestureRecognizer) { onTap?(g.location(in: self)) }
    @objc func pressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let p = g.location(in: table)
        guard let ip = table.indexPathForRow(at: p), let c = provider?(ip.row) else { return }
        let r = table.rectForRow(at: ip)
        let yInBody = p.y - r.minY - c.ct.titleHeight
        guard yInBody >= 0 else { return }
        // 轉成 CoreText 座標（frame 原點在左下）
        let cp = CGPoint(x: p.x - inset, y: c.bodyHeight - yInBody)
        if let i = TextDraw.index(frame: c.frame, point: cp) { onLongPress?(ip.row, i) }
    }
}
