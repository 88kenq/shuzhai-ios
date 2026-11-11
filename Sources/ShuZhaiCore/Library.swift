import Foundation

/// 書本資料；JSON 欄位與 Android 版 books.json 相同，備份可互通
public struct Book: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var author: String
    public var chapterCount: Int
    public var ruleName: String
    public var addedAt: Int64
    public var lastReadAt: Int64 = 0
    public var progChapter: Int = 0
    public var progOffset: Int = 0
    public var progPercent: Double = 0
    public var format: String = "txt"
    public var group: String = ""

    public init(id: String, title: String, author: String, chapterCount: Int, ruleName: String, addedAt: Int64, format: String = "txt") {
        self.id = id; self.title = title; self.author = author; self.chapterCount = chapterCount
        self.ruleName = ruleName; self.addedAt = addedAt; self.format = format
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
        chapterCount = (try? c.decode(Int.self, forKey: .chapterCount)) ?? 0
        ruleName = (try? c.decode(String.self, forKey: .ruleName)) ?? ""
        addedAt = (try? c.decode(Int64.self, forKey: .addedAt)) ?? 0
        lastReadAt = (try? c.decode(Int64.self, forKey: .lastReadAt)) ?? 0
        progChapter = (try? c.decode(Int.self, forKey: .progChapter)) ?? 0
        progOffset = (try? c.decode(Int.self, forKey: .progOffset)) ?? 0
        progPercent = (try? c.decode(Double.self, forKey: .progPercent)) ?? 0
        format = (try? c.decode(String.self, forKey: .format)) ?? "txt"
        group = (try? c.decode(String.self, forKey: .group)) ?? ""
    }
}

public struct TocEntry: Codable, Equatable {
    public let t: String       // 標題
    public let s: Int          // content.txt 中的 UTF-8 起點
    public let e: Int          // 終點
    public var title: String { t }
}

public struct Bookmark: Codable, Identifiable, Equatable {
    public var c: Int          // 章
    public var o: Int          // 章內 UTF-16 位置
    public var x: String       // 摘錄
    public var n: String       // 備註
    public var t: Int64        // 建立時間（毫秒）
    public var id: String { "\(c):\(o):\(t)" }
    public init(chapter: Int, offset: Int, excerpt: String, note: String, time: Int64) { c = chapter; o = offset; x = excerpt; n = note; t = time }
}

public func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

/// 本機書庫：書架清單、每本書的內文與目錄、書籤
public final class LibraryStore {
    public let root: URL
    public private(set) var books: [Book] = []
    private var tocCache: [String: [TocEntry]] = [:]
    private let enc = JSONEncoder()

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    public func load() {
        tocCache = [:]
        let f = root.appendingPathComponent("books.json")
        books = (try? JSONDecoder().decode([Book].self, from: Data(contentsOf: f))) ?? []
    }

    public func save() {
        let f = root.appendingPathComponent("books.json")
        if let d = try? enc.encode(books) { try? d.write(to: f, options: .atomic) }
    }

    public func dir(_ id: String) -> URL { root.appendingPathComponent("books/\(id)", isDirectory: true) }
    public func contentFile(_ id: String) -> URL { dir(id).appendingPathComponent("content.txt") }
    public func imageDir(_ id: String) -> URL { dir(id).appendingPathComponent("img", isDirectory: true) }

    public func coverFile(_ id: String) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir(id).path)) ?? []
        return items.first { $0.hasPrefix("cover.") }.map { dir(id).appendingPathComponent($0) }
    }

    public func book(_ id: String) -> Book? { books.first { $0.id == id } }

    public func update(_ b: Book, save doSave: Bool = true) {
        if let i = books.firstIndex(where: { $0.id == b.id }) { books[i] = b } else { books.append(b) }
        if doSave { save() }
    }

    public func delete(_ id: String) {
        books.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: dir(id))
        tocCache[id] = nil
        save()
    }

    public func toc(_ id: String) -> [TocEntry] {
        if let t = tocCache[id] { return t }
        let t = (try? JSONDecoder().decode([TocEntry].self, from: Data(contentsOf: dir(id).appendingPathComponent("toc.json")))) ?? []
        tocCache[id] = t
        return t
    }

    public func readChapter(_ id: String, _ index: Int) -> String {
        let toc = self.toc(id)
        guard index >= 0, index < toc.count, let h = try? FileHandle(forReadingFrom: contentFile(id)) else { return "" }
        defer { try? h.close() }
        let e = toc[index]
        try? h.seek(toOffset: UInt64(e.s))
        let data = (try? h.read(upToCount: max(0, e.e - e.s))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func writeToc(_ id: String, _ text: String, _ chapters: [ChapterSpan]) throws {
        let u = Array(text.utf16)
        var entries: [TocEntry] = []
        var pos = 0, bytes = 0
        for c in chapters {
            bytes += ChapterSplitter.utf8Len(u, pos, c.start)
            let s = bytes
            bytes += ChapterSplitter.utf8Len(u, c.start, c.end)
            pos = c.end
            entries.append(TocEntry(t: c.title, s: s, e: bytes))
        }
        try enc.encode(entries).write(to: dir(id).appendingPathComponent("toc.json"), options: .atomic)
        tocCache[id] = entries
    }

    // MARK: 匯入

    public func importFile(_ url: URL) throws -> Book {
        let data = try Data(contentsOf: url)
        let isZip = data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B
        if url.pathExtension.lowercased() == "epub" || isZip { return try importEpub(url) }
        return try importTxt(data: data, fileName: url.lastPathComponent)
    }

    public func importTxt(data: Data, fileName: String) throws -> Book {
        let enc = EncodingDetector.detect(data)
        let text = Marks.strip(EncodingDetector.decode(data, enc)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        let split = ChapterSplitter.split(text)
        let id = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: contentFile(id))
        try writeToc(id, text, split.chapters)
        let b = Book(id: id, title: ChapterSplitter.cleanTitle(fileName), author: ChapterSplitter.guessAuthor(text),
                     chapterCount: split.chapters.count, ruleName: split.ruleName, addedAt: nowMillis())
        books.append(b); save()
        return b
    }

    public func importEpub(_ url: URL) throws -> Book {
        let id = UUID().uuidString.lowercased()
        do {
            try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
            let epub = try EpubParser.parse(url, imageDir: imageDir(id))
            var text = ""
            var u16 = 0
            var spans: [ChapterSpan] = []
            for (t, body) in epub.chapters {
                let start = u16
                text += body; u16 += body.utf16.count
                spans.append(ChapterSpan(title: t, start: start, end: u16))
                text += "\n"; u16 += 1
            }
            try Data(text.utf8).write(to: contentFile(id))
            try writeToc(id, text, spans)
            let title = epub.title.isEmpty ? ChapterSplitter.cleanTitle(url.lastPathComponent) : epub.title
            let b = Book(id: id, title: title, author: epub.author, chapterCount: spans.count, ruleName: "EPUB 目錄",
                         addedAt: nowMillis(), format: "epub")
            books.append(b); save()
            return b
        } catch {
            try? FileManager.default.removeItem(at: dir(id))
            throw error
        }
    }

    /// 重新切目錄（TXT）；ruleIndex = -1 自動
    public func resplit(_ id: String, ruleIndex: Int) -> Book? {
        guard var b = book(id), let data = try? Data(contentsOf: contentFile(id)) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let split = ChapterSplitter.split(text, forcedRule: ruleIndex)
        guard !split.chapters.isEmpty, (try? writeToc(id, text, split.chapters)) != nil else { return nil }
        try? FileManager.default.removeItem(at: dir(id).appendingPathComponent("bookmarks.json"))
        b.chapterCount = split.chapters.count; b.ruleName = split.ruleName
        b.progChapter = 0; b.progOffset = 0; b.progPercent = 0
        update(b)
        return b
    }

    // MARK: 書籤

    public func bookmarks(_ id: String) -> [Bookmark] {
        let f = dir(id).appendingPathComponent("bookmarks.json")
        let l = (try? JSONDecoder().decode([Bookmark].self, from: Data(contentsOf: f))) ?? []
        return l.sorted { ($0.c, $0.o) < ($1.c, $1.o) }
    }

    public func saveBookmarks(_ id: String, _ list: [Bookmark]) {
        if let d = try? enc.encode(list) { try? d.write(to: dir(id).appendingPathComponent("bookmarks.json"), options: .atomic) }
    }
}
