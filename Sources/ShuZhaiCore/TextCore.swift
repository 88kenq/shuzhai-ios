import Foundation

// 與 Android 版（TextCore.kt）邏輯相同。所有位置都用 UTF-16 單位計算，
// 這樣與 Android 版的閱讀進度、書籤、備份可以互通。

/// 一個章節：title 為標題，[start, end) 為內文在全文中的 UTF-16 位置（不含標題行）
public struct ChapterSpan: Equatable {
    public let title: String
    public let start: Int
    public let end: Int
    public init(title: String, start: Int, end: Int) { self.title = title; self.start = start; self.end = end }
}

public struct SplitResult {
    public let ruleName: String
    public let chapters: [ChapterSpan]
}

@inline(__always) func isWS(_ c: UInt16) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C || c == 0x3000 || c == 0xA0 || c == 0xFEFF
}

extension String {
    /// 去掉頭尾的空白與全形空白
    func trimmedWS() -> String {
        let u = Array(utf16)
        var a = 0, b = u.count
        while a < b && isWS(u[a]) { a += 1 }
        while b > a && isWS(u[b - 1]) { b -= 1 }
        if a == 0 && b == u.count { return self }
        return String(utf16CodeUnits: Array(u[a..<b]), count: b - a)
    }
}

extension Array where Element == UInt16 {
    func str(_ a: Int, _ b: Int) -> String {
        if a >= b { return "" }
        return self[a..<b].withUnsafeBufferPointer { String(utf16CodeUnits: $0.baseAddress!, count: b - a) }
    }
}

public enum EncodingDetector {
    static let common: Set<Character> = Set(("的一是不了人我在有他這个们們来來到时時大地为為子中你说說生国國年着著就那和要她出也得里裡后後" +
        "自以会會家可下而过過天去能对對小多然于於心学學么麼之都好看起发發当當没沒成只如事把还還用第样樣道想作种種开開" +
        "美总總从從无無情己面最女但现現前些所同日手又行意动動方期它头頭经經长長儿兒回位分爱愛老因很给給名法间間知世什两兩" +
        "次使身者被高已亲親其进進此话話常与與活正感见見明问問力理尔爾点點文几幾定本公特做外孩相西果走将將月十实實向声聲车車" +
        "全信重三机機工物气氣每并並别別真打太新比才便夫再书書部水像眼等体體却卻加电電主界门門利海受听聽表德少克代员員许許"))

    public static var gb18030: String.Encoding {
        #if canImport(Darwin)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        #else
        return .utf8
        #endif
    }

    public static var big5: String.Encoding {
        #if canImport(Darwin)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))
        #else
        return .utf8
        #endif
    }

    public static func detect(_ data: Data) -> String.Encoding {
        let b = [UInt8](data.prefix(4))
        if b.count >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF { return .utf8 }
        if b.count >= 2 && b[0] == 0xFF && b[1] == 0xFE { return .utf16LittleEndian }
        if b.count >= 2 && b[0] == 0xFE && b[1] == 0xFF { return .utf16BigEndian }
        var sample = data.prefix(512 * 1024)
        if sample.count < data.count {
            // 避免截在 UTF-8 多位元組字中間
            var len = sample.count
            var back = 0
            while len > 0 && back < 4 && (sample[sample.startIndex + len - 1] & 0xC0) == 0x80 { len -= 1; back += 1 }
            if len > 0 && (sample[sample.startIndex + len - 1] & 0x80) != 0 { len -= 1 }
            sample = sample.prefix(len)
        }
        if String(data: Data(sample), encoding: .utf8) != nil { return .utf8 }
        #if canImport(Darwin)
        let sg = score(Data(sample), gb18030), sb = score(Data(sample), big5)
        return sb > sg ? big5 : gb18030
        #else
        return .utf8
        #endif
    }

    static func score(_ d: Data, _ enc: String.Encoding) -> Int {
        // 截斷的尾端可能解不開，退一點再試
        var data = d
        var s: String? = nil
        for _ in 0..<4 {
            s = String(data: data, encoding: enc)
            if s != nil || data.isEmpty { break }
            data = data.dropLast()
        }
        guard let str = s else { return Int.min / 2 }
        var sc = 0
        for c in str {
            if common.contains(c) { sc += 2 } else if c == "\u{FFFD}" { sc -= 10 }
        }
        return sc
    }

    public static func decode(_ data: Data, _ enc: String.Encoding) -> String {
        var s = String(data: data, encoding: enc)
            ?? String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s
    }
}

public enum ChapterSplitter {
    static let NUM = "[0-9０-９零〇一二兩两三四五六七八九十百千萬万壹貳贰參叁肆伍陸陆柒捌玖拾佰仟]"

    public struct Rule {
        public let name: String
        let regex: NSRegularExpression
        func matches(_ s: String) -> Bool {
            let ns = s as NSString
            guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return false }
            return m.range.location == 0 && m.range.length == ns.length
        }
    }

    static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    public static let rules: [Rule] = [
        Rule(name: "第X章／回", regex: re("^(?:正文\\s*)?(?:(?:第\\s*\(NUM)+\\s*[卷部集篇])\\s*.{0,20}?\\s*)?第\\s*\(NUM)+\\s*[章回節节話话].{0,30}$|^第\\s*\(NUM)+\\s*[卷部集篇](?:[\\s　:：、.．·\\-].{0,30})?$")),
        Rule(name: "第X卷／部", regex: re("^第\\s*\(NUM)+\\s*[卷部集篇](?:\\s.{0,30}|[　:：、.．·\\-].{0,30})?$")),
        Rule(name: "Chapter N", regex: try! NSRegularExpression(pattern: "^chapter\\s*\\d+.{0,40}$", options: [.caseInsensitive])),
        Rule(name: "【標題】", regex: re("^【.{1,30}】$")),
        Rule(name: "數字編號", regex: re("^[0-9０-９]{1,4}[、.．\\s　].{0,30}$")),
        Rule(name: "純數字", regex: re("^[0-9０-９]{1,4}$")),
    ]

    static let special = Rule(name: "special", regex: re("^(?:序章|序言|序|楔子|引子|前言|自序|尾聲|尾声|後記|后记|番外.{0,20}|終章|终章|完本感言)$"))
    static let maxTitle = 40
    static let chunkSize = 5000

    struct Line { let start: Int; let end: Int; let text: String }

    static func lines(_ u: [UInt16]) -> [Line] {
        var out: [Line] = []
        var i = 0
        let n = u.count
        while i < n {
            var j = i
            while j < n && u[j] != 0x0A { j += 1 }
            var e = j
            if e > i && u[e - 1] == 0x0D { e -= 1 }
            var a = i, b = e
            while a < b && isWS(u[a]) { a += 1 }
            while b > a && isWS(u[b - 1]) { b -= 1 }
            out.append(Line(start: i, end: e, text: u.str(a, b)))
            i = j + 1
        }
        return out
    }

    public static func split(_ text: String, forcedRule: Int = -1) -> SplitResult {
        let u = Array(text.utf16)
        let ls = lines(u)
        if forcedRule >= rules.count { return SplitResult(ruleName: "每 \(chunkSize) 字分段", chapters: chunk(u, ls)) }
        let tried = forcedRule >= 0 ? [forcedRule] : Array(rules.indices)
        for ri in tried {
            if let ch = tryRule(u, ls, rules[ri]), forcedRule >= 0 || plausible(ch) {
                return SplitResult(ruleName: rules[ri].name, chapters: ch)
            }
        }
        return SplitResult(ruleName: "每 \(chunkSize) 字分段", chapters: chunk(u, ls))
    }

    static func tryRule(_ u: [UInt16], _ ls: [Line], _ rule: Rule) -> [ChapterSpan]? {
        var hits: [Int] = []
        for (idx, l) in ls.enumerated() {
            let len = l.text.utf16.count
            if len == 0 || len > maxTitle { continue }
            if rule.matches(l.text) || special.matches(l.text) { hits.append(idx) }
        }
        let realHits = hits.filter { !special.matches(ls[$0].text) }.count
        if realHits < 2 { return nil }

        var kept: [Int] = []
        for (k, idx) in hits.enumerated() {
            let next = k + 1 < hits.count ? hits[k + 1] : ls.count
            var body = 0
            if idx + 1 < next { for x in (idx + 1)..<next { body += ls[x].text.utf16.count } }
            if body >= 20 || k == hits.count - 1 { kept.append(idx) }
        }
        // 檔案開頭的目錄清單：同一標題後面又出現、且這次內文不長 → 去掉前面那個
        var dup = Set<Int>()
        for (k, idx) in kept.enumerated() {
            let t = ls[idx].text
            let laterSame = kept[(k + 1)...].contains { ls[$0].text == t }
            if !laterSame { continue }
            let next = k + 1 < kept.count ? ls[kept[k + 1]].start : u.count
            if next - ls[idx].end < 3000 { dup.insert(idx) }
        }
        kept.removeAll { dup.contains($0) }
        if kept.count < 2 { return nil }

        var result: [ChapterSpan] = []
        let firstStart = ls[kept[0]].start
        var nonWS = 0
        for i in 0..<firstStart where !isWS(u[i]) { nonWS += 1 }
        if nonWS > 50 { result.append(ChapterSpan(title: "開頭", start: 0, end: firstStart)) }
        for (k, idx) in kept.enumerated() {
            let bodyStart = min(ls[idx].end + 1, u.count)
            let end = k + 1 < kept.count ? ls[kept[k + 1]].start : u.count
            result.append(ChapterSpan(title: ls[idx].text, start: bodyStart, end: max(bodyStart, end)))
        }
        return result
    }

    static func plausible(_ ch: [ChapterSpan]) -> Bool {
        if ch.count < 3 { return ch.count >= 2 && ch.allSatisfy { $0.end - $0.start > 500 } }
        let lens = ch.map { $0.end - $0.start }.sorted()
        return lens[lens.count / 2] >= 300
    }

    static func chunk(_ u: [UInt16], _ ls: [Line]) -> [ChapterSpan] {
        var out: [ChapterSpan] = []
        var start = 0
        for l in ls where l.end - start >= chunkSize {
            let end = min(l.end + 1, u.count)
            out.append(ChapterSpan(title: "第 \(out.count + 1) 段", start: start, end: end))
            start = end
        }
        if start < u.count || out.isEmpty { out.append(ChapterSpan(title: "第 \(out.count + 1) 段", start: start, end: u.count)) }
        return out
    }

    /// 整理成顯示用文字：每段去頭尾空白、刪空行、（可選）段首縮排兩字
    public static func format(_ raw: String, indent: Bool = true) -> String {
        var out: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = String(line).trimmedWS()
            if t.isEmpty { continue }
            out.append(indent ? "　　" + t : t)
        }
        return out.joined(separator: "\n")
    }

    /// UTF-16 範圍 [from, to) 的 UTF-8 位元組長度
    public static func utf8Len(_ u: [UInt16], _ from: Int, _ to: Int) -> Int {
        var n = 0
        var i = from
        while i < to {
            let c = u[i]
            if c < 0x80 { n += 1 }
            else if c < 0x800 { n += 2 }
            else if c >= 0xD800 && c <= 0xDBFF && i + 1 < to && u[i + 1] >= 0xDC00 && u[i + 1] <= 0xDFFF { n += 4; i += 1 }
            else { n += 3 }
            i += 1
        }
        return n
    }

    public static func guessAuthor(_ text: String) -> String {
        let head = String(text.prefix(3000))
        let r = re("作\\s*者\\s*[:：]\\s*([^\\s\\n]{1,20})")
        let ns = head as NSString
        guard let m = r.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) else { return "" }
        return ns.substring(with: m.range(at: 1))
    }

    public static func cleanTitle(_ fileName: String) -> String {
        var t = fileName
        if let dot = t.lastIndex(of: "."), dot != t.startIndex { t = String(t[..<dot]) }
        if let a = t.range(of: "《"), let b = t.range(of: "》", range: a.upperBound..<t.endIndex), a.upperBound < b.lowerBound {
            t = String(t[a.upperBound..<b.lowerBound])
        }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "未命名" : t
    }
}
