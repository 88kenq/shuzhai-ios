import Foundation
import SwiftSoup
import ZIPFoundation

/// EPUB 解析（與 Android 版 Epub.kt 相同邏輯）
public struct EpubBook {
    public let title: String
    public let author: String
    public let chapters: [(String, String)]   // 標題、帶標記的內文
    public let cover: URL?
}

public enum EpubError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let m) = self { return m }; return nil }
}

public enum EpubParser {
    static let blocks: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "section", "article",
        "tr", "pre", "figure", "figcaption", "dt", "dd", "header", "footer", "aside", "table", "ul", "ol", "hr", "center"]
    static let skip: Set<String> = ["script", "style", "head", "title", "noscript", "rt", "rp"]

    public static func parse(_ file: URL, imageDir: URL) throws -> EpubBook {
        let archive: Archive
        do { archive = try Archive(url: file, accessMode: .read) } catch { throw EpubError.invalid("不是有效的 EPUB 檔") }
        var lowerIndex: [String: Entry] = [:]
        for e in archive { lowerIndex[e.path.lowercased()] = e }

        func readData(_ path: String) -> Data? {
            guard let e = archive[path] ?? lowerIndex[path.lowercased()] else { return nil }
            var d = Data()
            _ = try? archive.extract(e, skipCRC32: true) { d.append($0) }
            return d
        }
        func read(_ path: String) -> String? { readData(path).map { String(decoding: $0, as: UTF8.self) } }

        guard let container = read("META-INF/container.xml") else { throw EpubError.invalid("不是有效的 EPUB（缺少 container.xml）") }
        guard let opfPath = try SwiftSoup.parse(container, "", Parser.xmlParser()).select("rootfile").first()?.attr("full-path"),
              !opfPath.isEmpty, let opfText = read(opfPath) else { throw EpubError.invalid("找不到 OPF") }
        let opfDir = dirname(opfPath)
        let opf = try SwiftSoup.parse(opfText, "", Parser.xmlParser())

        let meta = try opf.select("metadata > *").array()
        let title = try meta.first { $0.tagName().hasSuffix("title") }?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = try meta.first { $0.tagName().hasSuffix("creator") }?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        struct Item { let id: String; let href: String; let type: String; let props: [String] }
        let manifest: [Item] = try opf.select("manifest > item").array().map {
            Item(id: try $0.attr("id"), href: resolve(opfDir, try $0.attr("href")), type: try $0.attr("media-type"),
                 props: try $0.attr("properties").split(separator: " ").map(String.init))
        }
        var byId: [String: Item] = [:]
        for m in manifest { byId[m.id] = m }
        let spine = try opf.select("spine > itemref").array().compactMap { byId[try $0.attr("idref")] }
            .filter { $0.type.contains("html") || $0.href.hasSuffix(".html") || $0.href.hasSuffix(".xhtml") || $0.href.hasSuffix(".htm") }

        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        let coverId = try opf.select("metadata > meta[name=cover]").attr("content")
        let coverItem = manifest.first { $0.props.contains("cover-image") } ?? byId[coverId]
            ?? manifest.first { $0.type.hasPrefix("image") && $0.id.lowercased().contains("cover") }
        var cover: URL? = nil
        if let ci = coverItem, let d = readData(ci.href) {
            let ext = String((ci.href.split(separator: ".").last ?? "jpg").lowercased().prefix(4))
            let u = imageDir.deletingLastPathComponent().appendingPathComponent("cover.\(ext)")
            try? d.write(to: u); cover = u
        }

        // 目錄：href（不含 #）→ 標題
        var tocTitles: [String: String] = [:]
        if let nav = manifest.first(where: { $0.props.contains("nav") }), let html = read(nav.href) {
            let doc = try SwiftSoup.parse(html)
            let navs = try doc.select("nav").array()
            let navEl = try navs.first { try $0.attr("epub:type") == "toc" } ?? navs.first
            for a in try navEl?.select("a[href]").array() ?? [] {
                let h = resolve(dirname(nav.href), String(try a.attr("href").split(separator: "#", omittingEmptySubsequences: false).first ?? ""))
                let t = try a.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && tocTitles[h] == nil { tocTitles[h] = t }
            }
        }
        if tocTitles.isEmpty {
            let ncxId = try opf.select("spine").first()?.attr("toc") ?? ""
            if let ncx = byId[ncxId] ?? manifest.first(where: { $0.type.contains("ncx") }), let xml = read(ncx.href) {
                let doc = try SwiftSoup.parse(xml, "", Parser.xmlParser())
                for np in try doc.select("navPoint").array() {
                    let t = try np.select("navLabel").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let src = String((try np.select("content").first()?.attr("src") ?? "").split(separator: "#", omittingEmptySubsequences: false).first ?? "")
                    let key = resolve(dirname(ncx.href), src)
                    if !t.isEmpty && !src.isEmpty && tocTitles[key] == nil { tocTitles[key] = t }
                }
            }
        }

        var imgCount = 0
        var imgNames: [String: String] = [:]
        func saveImage(_ path: String) -> String? {
            if let n = imgNames[path] { return n }
            guard let d = readData(path) else { return nil }
            let ext = String((path.split(separator: ".").last ?? "img").lowercased().filter { $0.isLetter || $0.isNumber }.prefix(4))
            imgCount += 1
            let name = "\(imgCount).\(ext)"
            try? d.write(to: imageDir.appendingPathComponent(name))
            imgNames[path] = name
            return name
        }

        var chapters: [(String, String)] = []
        for (idx, item) in spine.enumerated() {
            guard let html = read(item.href) else { continue }
            let doc = try SwiftSoup.parse(html)
            var text = cleanup(try htmlToMarked(doc, baseDir: dirname(item.href), saveImage: saveImage))
            let plain = Rich.parse(text).text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.isEmpty && (idx == 0 || !text.contains("\u{E010}")) { continue }
            let firstHeading = try doc.body()?.select("h1, h2, h3").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let t = tocTitles[item.href] ?? firstHeading
            if !t.isEmpty {
                let first = String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                let fp = Rich.parse(first).text.trimmingCharacters(in: .whitespacesAndNewlines)
                if fp == t || (!fp.isEmpty && (t.contains(fp) || fp.contains(t))) {
                    if let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) } else { text = "" }
                }
            }
            chapters.append((t.isEmpty ? (chapters.isEmpty ? "開頭" : "第 \(chapters.count + 1) 節") : t, text))
        }
        if chapters.isEmpty { throw EpubError.invalid("這本 EPUB 裡找不到文字內容") }
        return EpubBook(title: title, author: author, chapters: chapters, cover: cover)
    }

    /// 把 HTML 轉成段落文字（段落間換行，粗斜體與插圖用標記）
    public static func htmlToMarked(_ doc: Document, baseDir: String, saveImage: (String) -> String?) throws -> String {
        var sb = ""
        func newline() { if !sb.isEmpty && sb.last != "\n" { sb.append("\n") } }
        func walk(_ n: Node) throws {
            if let t = n as? TextNode {
                let raw = t.text().replacingOccurrences(of: "\u{00A0}", with: " ")
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
                var s = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                if sb.isEmpty || sb.last == "\n" { s = String(s.drop(while: { $0 == " " })) }
                sb.append(s)
                return
            }
            guard let e = n as? Element else { return }
            let tag = e.tagName().lowercased()
            if skip.contains(tag) { return }
            if tag == "br" { sb.append("\n"); return }
            if tag == "img" || tag == "image" {
                var src = try e.attr("src")
                if src.isEmpty { src = try e.attr("xlink:href") }
                if src.isEmpty { src = try e.attr("href") }
                if !src.isEmpty && !src.hasPrefix("data:"), let name = saveImage(resolve(baseDir, src)) {
                    newline(); sb.append(Marks.img(name)); sb.append("\n")
                }
                return
            }
            let block = blocks.contains(tag)
            let bold = tag == "b" || tag == "strong" || (tag.count == 2 && tag.hasPrefix("h") && "123456".contains(tag.last!))
            let italic = tag == "i" || tag == "em" || tag == "cite"
            if block { newline() }
            if bold { sb.append("\u{E000}") }
            if italic { sb.append("\u{E002}") }
            for c in e.getChildNodes() { try walk(c) }
            if italic { sb.append("\u{E003}") }
            if bold { sb.append("\u{E001}") }
            if block { newline() }
        }
        if let body = doc.body() { try walk(body) }
        return sb
    }

    /// 去掉空的粗斜體標記、只剩標記的行
    public static func cleanup(_ t: String) -> String {
        var s = t
        while true {
            let n = s.replacingOccurrences(of: "\u{E000}\u{E001}", with: "").replacingOccurrences(of: "\u{E002}\u{E003}", with: "")
            if n == s { break }; s = n
        }
        return s.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            line.utf16.contains { !($0 >= 0xE000 && $0 <= 0xE003) && !isWS($0) }
        }.joined(separator: "\n")
    }

    static func dirname(_ p: String) -> String {
        guard let i = p.lastIndex(of: "/") else { return "" }
        return String(p[..<i])
    }

    /// 相對路徑轉成 zip 內的完整路徑
    public static func resolve(_ baseDir: String, _ href: String) -> String {
        let h = href.removingPercentEncoding ?? href
        if h.hasPrefix("/") { return String(h.drop(while: { $0 == "/" })) }
        var parts: [String] = baseDir.isEmpty ? [] : baseDir.split(separator: "/").map(String.init)
        for p in h.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            switch p {
            case "", ".": break
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(p)
            }
        }
        return parts.joined(separator: "/")
    }
}
