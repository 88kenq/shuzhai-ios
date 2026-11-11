import Foundation

/// 取代規則。JSON 欄位與 Android 版相同，規則檔可以互相匯入。
public final class ReplaceRule: Codable, Identifiable {
    public var id: String
    public var name: String
    public var pattern: String
    public var replacement: String
    public var isRegex: Bool
    public var scope: String        // 空字串＝全部書，否則為書的 id
    public var enabled: Bool
    public var ttsOnly: Bool        // 只用於朗讀

    enum CodingKeys: String, CodingKey { case id, name, pattern, replacement, isRegex, scope, enabled, ttsOnly = "tts" }

    public init(id: String = UUID().uuidString.lowercased(), name: String = "", pattern: String = "", replacement: String = "",
                isRegex: Bool = false, scope: String = "", enabled: Bool = true, ttsOnly: Bool = false) {
        self.id = id; self.name = name; self.pattern = pattern; self.replacement = replacement
        self.isRegex = isRegex; self.scope = scope; self.enabled = enabled; self.ttsOnly = ttsOnly
    }

    public required init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        pattern = (try? c.decode(String.self, forKey: .pattern)) ?? ""
        replacement = (try? c.decode(String.self, forKey: .replacement)) ?? ""
        isRegex = (try? c.decode(Bool.self, forKey: .isRegex)) ?? false
        scope = (try? c.decode(String.self, forKey: .scope)) ?? ""
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        ttsOnly = (try? c.decode(Bool.self, forKey: .ttsOnly)) ?? false
    }

    private var compiled: NSRegularExpression?
    private var compiledFor: String?

    func regex() -> NSRegularExpression? {
        if compiledFor != pattern {
            compiledFor = pattern
            compiled = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        }
        return compiled
    }

    /// Java 的 $1 與 ICU 的 $1 相同；Java 的 \\ 跳脫在 ICU 也通用
    public func apply(_ text: String) -> String {
        if pattern.isEmpty { return text }
        if isRegex {
            guard let r = regex() else { return text }
            let ns = text as NSString
            return r.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: replacement)
        }
        return text.replacingOccurrences(of: pattern, with: replacement)
    }

    public static func checkRegex(_ p: String) -> String? {
        do { _ = try NSRegularExpression(pattern: p); return nil } catch { return "格式錯誤" }
    }
}

public enum RuleEngine {
    public static func apply(_ text: String, _ rules: [ReplaceRule]) -> String {
        rules.reduce(text) { $1.apply($0) }
    }

    /// 刪掉變空的段落並加上段首縮排
    public static func finish(_ text: String) -> String { ChapterSplitter.format(text, indent: true) }

    public static func builtins() -> [ReplaceRule] {
        [
            ReplaceRule(name: "去除網址", pattern: "(https?://|www\\.)[A-Za-z0-9./?=&_%#:~+-]+", isRegex: true, enabled: false),
            ReplaceRule(name: "去除「本章完」", pattern: "^[\\s　]*[（(【\\[]?\\s*本章完\\s*[)）】\\]]?[\\s　]*$", isRegex: true, enabled: false),
            ReplaceRule(name: "去除「求月票／推薦票」", pattern: "^.{0,20}(求月票|求推薦票|求收藏|求訂閱|求打賞).{0,30}$", isRegex: true, enabled: false),
            ReplaceRule(name: "朗讀：略過括號內的註解", pattern: "[（(][^）)]{0,40}[）)]", isRegex: true, enabled: false, ttsOnly: true),
            ReplaceRule(name: "朗讀：「……」念成停頓", pattern: "[…．.]{2,}", replacement: "，", isRegex: true, enabled: false, ttsOnly: true),
        ]
    }
}

// MARK: - EPUB 樣式標記

/// 章節文字內的輕量標記（與 Android 版相同）：
///   \u{E000}…\u{E001} 粗體、\u{E002}…\u{E003} 斜體、\u{E010}檔名\u{E011} 插圖
/// 排版前把標記拿掉換成樣式範圍；插圖佔一個 \u{FFFC}。
public enum Marks {
    public static let bOn: UInt16 = 0xE000, bOff: UInt16 = 0xE001
    public static let iOn: UInt16 = 0xE002, iOff: UInt16 = 0xE003
    public static let imgOn: UInt16 = 0xE010, imgOff: UInt16 = 0xE011
    public static let obj: UInt16 = 0xFFFC

    public static func img(_ name: String) -> String { "\u{E010}\(name)\u{E011}" }
    static func isMark(_ c: UInt16) -> Bool { c >= 0xE000 && c <= 0xE011 }
    public static func strip(_ s: String) -> String {
        guard s.utf16.contains(where: isMark) else { return s }
        let u = s.utf16.filter { !isMark($0) }
        return String(utf16CodeUnits: u, count: u.count)
    }
}

public struct RichSpan: Equatable {
    public enum Kind: Equatable { case bold, italic, image(String), center }
    public let start: Int   // UTF-16
    public let end: Int
    public let kind: Kind
}

public struct Rich {
    public let text: String
    public let spans: [RichSpan]
    public init(text: String, spans: [RichSpan]) { self.text = text; self.spans = spans }

    public static func parse(_ marked: String) -> Rich {
        var src = Array(marked.utf16)
        guard src.contains(where: Marks.isMark) else { return Rich(text: marked, spans: []) }
        // 單獨一行的插圖不要段首縮排
        var cleaned = [UInt16](); cleaned.reserveCapacity(src.count)
        var i = 0
        while i < src.count {
            let lineStart = i == 0 || src[i - 1] == 0x0A
            if lineStart && i + 2 < src.count && src[i] == 0x3000 && src[i + 1] == 0x3000 && src[i + 2] == Marks.imgOn {
                if let e = src[(i + 3)...].firstIndex(of: Marks.imgOff), e + 1 == src.count || src[e + 1] == 0x0A { i += 2; continue }
            }
            cleaned.append(src[i]); i += 1
        }
        src = cleaned

        var out = [UInt16](); out.reserveCapacity(src.count)
        var spans: [RichSpan] = []
        var bold = -1, italic = -1
        i = 0
        while i < src.count {
            let c = src[i]
            switch c {
            case Marks.bOn: if bold < 0 { bold = out.count }
            case Marks.bOff:
                if bold >= 0 && bold < out.count { spans.append(RichSpan(start: bold, end: out.count, kind: .bold)) }
                bold = -1
            case Marks.iOn: if italic < 0 { italic = out.count }
            case Marks.iOff:
                if italic >= 0 && italic < out.count { spans.append(RichSpan(start: italic, end: out.count, kind: .italic)) }
                italic = -1
            case Marks.imgOn:
                guard let e = src[(i + 1)...].firstIndex(of: Marks.imgOff) else { i = src.count; continue }
                let name = src.str(i + 1, e)
                let pos = out.count
                out.append(Marks.obj)
                spans.append(RichSpan(start: pos, end: pos + 1, kind: .image(name)))
                let ls = pos == 0 || out[pos - 1] == 0x0A
                let le = e + 1 >= src.count || src[e + 1] == 0x0A
                if ls && le { spans.append(RichSpan(start: pos, end: e + 1 < src.count ? pos + 2 : pos + 1, kind: .center)) }
                i = e
            default:
                if !Marks.isMark(c) { out.append(c) }
            }
            i += 1
        }
        if bold >= 0 && bold < out.count { spans.append(RichSpan(start: bold, end: out.count, kind: .bold)) }
        if italic >= 0 && italic < out.count { spans.append(RichSpan(start: italic, end: out.count, kind: .italic)) }
        return Rich(text: String(utf16CodeUnits: out, count: out.count), spans: spans)
    }
}
