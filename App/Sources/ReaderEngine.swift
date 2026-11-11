import UIKit
import CoreText
import ShuZhaiCore

/// 閱讀主題
struct ReaderTheme {
    let bg: UIColor
    let fg: UIColor
    var info: UIColor { fg.withAlphaComponent(0.5) }
    static let day = ReaderTheme(bg: UIColor(rgb: 0xF4ECD8), fg: UIColor(rgb: 0x2B2B2B))
    static let night = ReaderTheme(bg: UIColor(rgb: 0x1C1813), fg: UIColor(rgb: 0x9C8E78))
}

/// 插圖在 CoreText 中佔的大小
final class ImageBox {
    let image: UIImage
    let size: CGSize
    init(image: UIImage, size: CGSize) { self.image = image; self.size = size }
}

private let imageKey = NSAttributedString.Key("szImage")

/// 一章排好的結果：每頁是一段 UTF-16 範圍
final class ChapterLayout {
    let chapter: Int
    let text: NSAttributedString
    let framesetter: CTFramesetter
    let pages: [NSRange]
    let titleHeight: CGFloat
    let title: NSAttributedString
    var boxes: [ImageBox] = []

    init(chapter: Int, text: NSAttributedString, title: NSAttributedString, titleHeight: CGFloat, pageSize: CGSize, boxes: [ImageBox]) {
        self.chapter = chapter; self.text = text; self.title = title; self.titleHeight = titleHeight; self.boxes = boxes
        framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        var pages: [NSRange] = []
        var loc = 0
        let len = text.length
        var first = true
        while loc < len {
            let h = first ? pageSize.height - titleHeight : pageSize.height
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: pageSize.width, height: max(h, 20)), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: loc, length: 0), path, nil)
            var visible = CTFrameGetVisibleStringRange(frame).length
            if visible <= 0 {
                if first { pages.append(NSRange(location: loc, length: 0)); first = false; continue }  // 標題太高，內文放到下一頁
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

/// 排版設定與章節排版
final class Typesetter {
    var fontSize: CGFloat = 20
    var lineSpacing: CGFloat = 1.6
    var paraSpacing: CGFloat = 0.5
    var theme = ReaderTheme.day

    func font(_ size: CGFloat, bold: Bool = false) -> UIFont {
        let name = bold ? "PingFangTC-Semibold" : "PingFangTC-Regular"
        return UIFont(name: name, size: size) ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
    }

    func layout(chapter: Int, rich: Rich, title: String, imageURL: (String) -> URL?, pageSize: CGSize) -> ChapterLayout {
        let base = font(fontSize)
        let fg = theme.fg.cgColor
        let para = NSMutableParagraphStyle()
        para.lineSpacing = base.lineHeight * (lineSpacing - 1)
        para.paragraphSpacing = base.lineHeight * paraSpacing
        para.alignment = .justified
        para.lineBreakMode = .byWordWrapping
        let text = rich.text.isEmpty ? "（本章沒有內容）" : rich.text
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: base, NSAttributedString.Key(kCTForegroundColorAttributeName as String): fg, .paragraphStyle: para,
        ])
        var boxes: [ImageBox] = []
        let maxImg = CGSize(width: pageSize.width, height: pageSize.height * 0.92)
        for sp in rich.spans where sp.end <= s.length && sp.start < sp.end {
            let r = NSRange(location: sp.start, length: sp.end - sp.start)
            switch sp.kind {
            case .bold: s.addAttribute(.font, value: font(fontSize, bold: true), range: r)
            case .italic:
                var m = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
                let it = CTFontCreateCopyWithAttributes(base as CTFont, fontSize, &m, nil)
                s.addAttribute(.font, value: it, range: r)
            case .center:
                let p = para.mutableCopy() as! NSMutableParagraphStyle
                p.alignment = .center
                s.addAttribute(.paragraphStyle, value: p, range: r)
            case .image(let name):
                guard let u = imageURL(name), let img = UIImage(contentsOfFile: u.path), img.size.width > 0 else { continue }
                let glyph = img.size.width <= 64 && img.size.height <= 64
                var size: CGSize
                if glyph { size = CGSize(width: fontSize, height: fontSize * img.size.height / img.size.width) }
                else {
                    let k = min(maxImg.width / img.size.width, maxImg.height / img.size.height, 3)
                    size = CGSize(width: img.size.width * k, height: img.size.height * k)
                }
                let box = ImageBox(image: img, size: size)
                boxes.append(box)
                var cb = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1, dealloc: { _ in },
                    getAscent: { Unmanaged<ImageBox>.fromOpaque($0).takeUnretainedValue().size.height },
                    getDescent: { _ in 0 },
                    getWidth: { Unmanaged<ImageBox>.fromOpaque($0).takeUnretainedValue().size.width })
                let delegate = CTRunDelegateCreate(&cb, Unmanaged.passUnretained(box).toOpaque())!
                s.addAttribute(NSAttributedString.Key(kCTRunDelegateAttributeName as String), value: delegate, range: r)
                s.addAttribute(imageKey, value: box, range: r)
            }
        }
        // 章名
        let tp = NSMutableParagraphStyle(); tp.lineSpacing = 4
        let titleStr = NSAttributedString(string: title, attributes: [
            .font: font(fontSize * 1.35, bold: true), NSAttributedString.Key(kCTForegroundColorAttributeName as String): fg, .paragraphStyle: tp,
        ])
        let fs = CTFramesetterCreateWithAttributedString(titleStr)
        let th = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                              CGSize(width: pageSize.width, height: .greatestFiniteMagnitude), nil).height
        return ChapterLayout(chapter: chapter, text: s, title: titleStr, titleHeight: ceil(th) + 24, pageSize: pageSize, boxes: boxes)
    }
}

/// 畫出一頁
final class PageView: UIView {
    var layoutData: ChapterLayout?
    var pageIndex = 0
    var theme = ReaderTheme.day
    var contentInsets = UIEdgeInsets(top: 50, left: 20, bottom: 40, right: 20)
    var headerTop: CGFloat = 16
    var footerBottom: CGFloat = 12
    var headerText = ""
    var footerLeft = ""
    var footerRight = ""

    var onTap: ((CGPoint) -> Void)?
    var onSwipe: ((Bool) -> Void)?     // true＝往左滑（下一頁）

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        let l = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:))); l.direction = .left
        let r = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:))); r.direction = .right
        addGestureRecognizer(l); addGestureRecognizer(r)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func tapped(_ g: UITapGestureRecognizer) { onTap?(g.location(in: self)) }
    @objc func swiped(_ g: UISwipeGestureRecognizer) { onSwipe?(g.direction == .left) }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        theme.bg.setFill(); ctx.fill(bounds)
        let infoAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: theme.info]
        let w = bounds.width - contentInsets.left - contentInsets.right

        guard let l = layoutData, pageIndex < l.pages.count else { return }
        let range = l.pages[pageIndex]
        var top = contentInsets.top

        if pageIndex != 0, !headerText.isEmpty {
            (headerText as NSString).draw(with: CGRect(x: contentInsets.left, y: headerTop, width: w, height: 16),
                                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: infoAttrs, context: nil)
        }

        // CoreText 的座標原點在左下角
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)

        if pageIndex == 0 {
            let fs = CTFramesetterCreateWithAttributedString(l.title)
            let tr = CGRect(x: contentInsets.left, y: bounds.height - top - l.titleHeight, width: w, height: l.titleHeight)
            CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: tr, transform: nil), nil), ctx)
            top += l.titleHeight
        }
        let h = bounds.height - top - contentInsets.bottom
        if range.length > 0, h > 0 {
            let r = CGRect(x: contentInsets.left, y: contentInsets.bottom, width: w, height: h)
            let frame = CTFramesetterCreateFrame(l.framesetter, CFRange(location: range.location, length: range.length), CGPath(rect: r, transform: nil), nil)
            CTFrameDraw(frame, ctx)
            drawImages(frame, origin: r.origin, ctx: ctx)
        }
        ctx.restoreGState()

        let fy = bounds.height - footerBottom - 14
        (footerLeft as NSString).draw(at: CGPoint(x: contentInsets.left, y: fy), withAttributes: infoAttrs)
        let rs = (footerRight as NSString).size(withAttributes: infoAttrs)
        (footerRight as NSString).draw(at: CGPoint(x: bounds.width - contentInsets.right - rs.width, y: fy), withAttributes: infoAttrs)
    }

    private func drawImages(_ frame: CTFrame, origin: CGPoint, ctx: CGContext) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (i, line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                guard let box = attrs[imageKey] as? ImageBox, let cg = box.image.cgImage else { continue }
                let x = CTLineGetOffsetForStringIndex(line, CTRunGetStringRange(run).location, nil)
                let rect = CGRect(x: origin.x + origins[i].x + x, y: origin.y + origins[i].y, width: box.size.width, height: box.size.height)
                ctx.draw(cg, in: rect)
            }
        }
    }
}
