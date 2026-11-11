import XCTest
@testable import ShuZhaiCore
import ZIPFoundation

final class CoreTests: XCTestCase {
    func body(_ n: Int) -> String { String(repeating: "他走進房間，看見桌上放著一封信。她說這是我們的事情，你不用管。", count: n) }

    func testChineseNumerals() {
        let t = "作者：無名氏\n\n第一章 初見\n\(body(20))\n\n第二章　重逢\n\(body(20))\n第一百零三章：終局\n\(body(20))\n"
        let r = ChapterSplitter.split(t)
        XCTAssertEqual(r.chapters.map(\.title), ["第一章 初見", "第二章　重逢", "第一百零三章：終局"])
        let u = Array(t.utf16)
        XCTAssertTrue(u.str(r.chapters[0].start, r.chapters[0].end).hasPrefix(body(1)))
        XCTAssertEqual(ChapterSplitter.guessAuthor(t), "無名氏")
    }

    func testTocListingAndPreface() {
        let toc = "目錄\n第1章 開始\n第2章 中段\n第3章 結束\n"
        let pre = String(repeating: "這是一段很長的簡介。", count: 10) + "\n"
        let t = toc + pre + "第一卷 風起\n第1章 開始\n\(body(15))\n第2章 中段\n\(body(15))\n第3章 結束\n\(body(15))\n番外\n\(body(15))"
        XCTAssertEqual(ChapterSplitter.split(t).chapters.map(\.title), ["開頭", "第1章 開始", "第2章 中段", "第3章 結束", "番外"])
    }

    func testNumberedAndFallback() {
        let t = "1、雨夜\n\(body(20))\n2、晴天\n\(body(20))\n3、風\n\(body(20))"
        XCTAssertEqual(ChapterSplitter.split(t).ruleName, "數字編號")
        let plain = String(repeating: body(3) + "\n", count: 200)
        let r = ChapterSplitter.split(plain)
        XCTAssertTrue(r.ruleName.hasPrefix("每"))
        XCTAssertEqual(r.chapters.last!.end, plain.utf16.count)
    }

    func testFormatAndUtf8() {
        XCTAssertEqual(ChapterSplitter.format("  甲乙 \r\n\n　　丙\n"), "　　甲乙\n　　丙")
        let s = "a中😀é"
        XCTAssertEqual(ChapterSplitter.utf8Len(Array(s.utf16), 0, s.utf16.count), s.utf8.count)
    }

    func testConverter() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../App/Resources/opencc").standardized
        let c = try XCTUnwrap(S2TWConverter(directory: dir))
        let src = "贞观憨婿 作者：大眼小金鱼 “陛下，管管你女婿韦憨子吧，他又要在东门外单挑那帮大臣！”他的头发很干净，用软件查信息。"
        let out = c.convert(src)
        XCTAssertEqual(out, "貞觀憨婿 作者：大眼小金魚 “陛下，管管你女婿韋憨子吧，他又要在東門外單挑那幫大臣！”他的頭髮很乾淨，用軟體查資訊。")
        XCTAssertTrue(c.looksSimplified(src))
        let trad = "他走進房間，看見桌上放著一封信。她說這是我們的事情，你不用管。"
        XCTAssertFalse(c.looksSimplified(trad))
        XCTAssertEqual(c.convertIfNeeded(trad), trad)
    }

    func testRules() {
        let text = ChapterSplitter.format("第一段 www.xxbiquge.com 內容\n本章完\n（本章完）\n正文錯字：帳號\n求月票求推薦票！", indent: false)
        let b = RuleEngine.builtins()
        let rules = [b[0], b[1], b[2], ReplaceRule(pattern: "帳號", replacement: "賬號"), ReplaceRule(pattern: "([壞", isRegex: true)]
        XCTAssertEqual(RuleEngine.finish(RuleEngine.apply(text, rules)), "　　第一段  內容\n　　正文錯字：賬號")
        XCTAssertNotNil(ReplaceRule.checkRegex("([壞"))
        // 與 Android 版規則檔互通
        let json = #"[{"id":"a1","name":"n","pattern":"x","replacement":"y","isRegex":false,"scope":"","enabled":true,"tts":true}]"#
        let r = try! JSONDecoder().decode([ReplaceRule].self, from: Data(json.utf8))
        XCTAssertTrue(r[0].ttsOnly)
    }

    func makeEpub(_ url: URL, epub3: Bool) throws {
        let a = try Archive(url: url, accessMode: .create)
        func put(_ name: String, _ s: String) throws { try put(name, Data(s.utf8)) }
        func put(_ name: String, _ d: Data) throws {
            try a.addEntry(with: name, type: .file, uncompressedSize: Int64(d.count), provider: { pos, size in d.subdata(in: Int(pos)..<Int(pos) + size) })
        }
        try put("mimetype", "application/epub+zip")
        try put("META-INF/container.xml", #"<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>"#)
        let nav = epub3 ? #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"# : #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#
        try put("OEBPS/content.opf", #"<?xml version="1.0"?><package><metadata><dc:title>測試之書</dc:title><dc:creator>某作者</dc:creator><meta name="cover" content="cov"/></metadata><manifest>"# + nav +
            #"<item id="cov" href="images/cover.jpg" media-type="image/jpeg"/><item id="c0" href="text/cover.xhtml" media-type="application/xhtml+xml"/><item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="text/ch%202.xhtml" media-type="application/xhtml+xml"/></manifest><spine toc="ncx"><itemref idref="c0"/><itemref idref="c1"/><itemref idref="c2"/></spine></package>"#)
        try put("OEBPS/nav.xhtml", #"<html><body><nav epub:type="toc"><ol><li><a href="text/ch1.xhtml">第一章 開始</a></li><li><a href="text/ch%202.xhtml#x">第二章 結束</a></li></ol></nav></body></html>"#)
        try put("OEBPS/toc.ncx", #"<?xml version="1.0"?><ncx><navMap><navPoint><navLabel><text>第一章 開始</text></navLabel><content src="text/ch1.xhtml"/></navPoint><navPoint><navLabel><text>第二章 結束</text></navLabel><content src="text/ch 2.xhtml#x"/></navPoint></navMap></ncx>"#)
        try put("OEBPS/images/cover.jpg", Data([1, 2, 3]))
        try put("OEBPS/images/pic.png", Data([4, 5, 6]))
        try put("OEBPS/text/cover.xhtml", #"<html><body><img src="../images/cover.jpg"/></body></html>"#)
        try put("OEBPS/text/ch1.xhtml", #"<html><head><style>p{}</style></head><body><h1>第一章 開始</h1><p>他說：<b>很重要</b>的事&nbsp;情。</p><p>第二段<i>斜體</i><br/>換行</p><div><img src="../images/pic.png"/></div><p>   </p></body></html>"#)
        try put("OEBPS/text/ch 2.xhtml", #"<html><body><h2>第二章 結束</h2><p>最後一段。</p></body></html>"#)
    }

    func testEpub() throws {
        for v3 in [true, false] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = dir.appendingPathComponent("t.epub")
            try makeEpub(f, epub3: v3)
            let book = try EpubParser.parse(f, imageDir: dir.appendingPathComponent("img"))
            XCTAssertEqual(book.title, "測試之書")
            XCTAssertEqual(book.author, "某作者")
            XCTAssertEqual(book.chapters.map(\.0), ["第一章 開始", "第二章 結束"])
            XCTAssertNotNil(book.cover)
            let rich = Rich.parse(ChapterSplitter.format(book.chapters[0].1, indent: true))
            XCTAssertEqual(rich.text, "　　他說：很重要的事 情。\n　　第二段斜體\n　　換行\n\u{FFFC}")
            let u = Array(rich.text.utf16)
            XCTAssertTrue(rich.spans.contains { $0.kind == .bold && u.str($0.start, $0.end) == "很重要" })
            XCTAssertTrue(rich.spans.contains { $0.kind == .italic && u.str($0.start, $0.end) == "斜體" })
            guard case .image(let name)? = rich.spans.first(where: { if case .image = $0.kind { return true }; return false })?.kind else { return XCTFail() }
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("img/\(name)").path))
            XCTAssertEqual(ChapterSplitter.format(book.chapters[1].1), "　　最後一段。")
        }
    }

    func testLibraryRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(root: root)
        let text = "第一章 甲\n\(body(20))\n第二章 乙\n😀\(body(20))\n"
        let b = try store.importTxt(data: Data(text.utf8), fileName: "《我的書》.txt")
        XCTAssertEqual(b.title, "我的書")
        XCTAssertEqual(b.chapterCount, 2)
        XCTAssertTrue(store.readChapter(b.id, 1).hasPrefix("😀他走進"))
        let again = LibraryStore(root: root)
        XCTAssertEqual(again.books.first?.id, b.id)
        // 讀得懂 Android 版的 books.json
        let android = #"[{"id":"x","title":"T","author":"","chapterCount":3,"ruleName":"r","addedAt":1,"lastReadAt":2,"progChapter":1,"progOffset":5,"progPercent":0.25}]"#
        let parsed = try JSONDecoder().decode([Book].self, from: Data(android.utf8))
        XCTAssertEqual(parsed[0].progOffset, 5)
        XCTAssertEqual(parsed[0].format, "txt")
    }
}
