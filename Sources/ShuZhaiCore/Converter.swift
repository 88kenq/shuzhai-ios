import Foundation

/// 簡轉繁（台灣用詞），使用 OpenCC 詞庫（Apache 2.0）。流程與 Android 版相同：
/// 簡體詞組／單字 → 繁體 → 台灣用詞 → 台灣異體字，每一步都用「最長詞優先」比對。
final class Dict {
    private var map: [String: String] = [:]
    private var maxLenByFirst: [UInt16: Int] = [:]

    init(_ entries: [String: String]) {
        map = entries
        for k in entries.keys {
            guard let f = k.utf16.first else { continue }
            let l = k.utf16.count
            if l > (maxLenByFirst[f] ?? 0) { maxLenByFirst[f] = l }
        }
    }

    func convert(_ s: String) -> String {
        let u = Array(s.utf16)
        var out = [UInt16]()
        out.reserveCapacity(u.count)
        var i = 0
        let n = u.count
        while i < n {
            guard let maxL = maxLenByFirst[u[i]] else { out.append(u[i]); i += 1; continue }
            var len = min(maxL, n - i)
            var matched = false
            while len >= 1 {
                if let v = map[u.str(i, i + len)] { out.append(contentsOf: v.utf16); i += len; matched = true; break }
                len -= 1
            }
            if !matched { out.append(u[i]); i += 1 }
        }
        return String(utf16CodeUnits: out, count: out.count)
    }

    static func parse(_ texts: [String]) -> [String: String] {
        var m: [String: String] = [:]
        for t in texts {
            for line in t.split(separator: "\n") {
                if line.first == "#" { continue }
                guard let tab = line.firstIndex(of: "\t") else { continue }
                let key = String(line[..<tab])
                let rest = line[line.index(after: tab)...].trimmingCharacters(in: .whitespaces)
                let v = String(rest.split(separator: " ").first ?? "")
                if !key.isEmpty && !v.isEmpty && m[key] == nil { m[key] = v }
            }
        }
        return m
    }
}

public final class S2TWConverter {
    private let st: Dict
    private let twp: Dict
    private let twv: Dict
    private let simplifiedOnly: Set<UInt16>

    /// 四個參數為詞庫檔內容
    public init(stPhrases: String, stChars: String, twPhrases: String, twVariants: String) {
        let chars = Dict.parse([stChars])
        var stMap = Dict.parse([stPhrases])
        for (k, v) in chars where k.utf16.count == 1 { stMap[k] = stMap[k] ?? v }
        st = Dict(stMap)
        twp = Dict(Dict.parse([twPhrases]))
        twv = Dict(Dict.parse([twVariants]))
        var so = Set<UInt16>()
        for (k, v) in chars where k.utf16.count == 1 && k != v { so.insert(k.utf16.first!) }
        simplifiedOnly = so
    }

    public convenience init?(directory: URL) {
        func read(_ n: String) -> String? { try? String(contentsOf: directory.appendingPathComponent(n), encoding: .utf8) }
        guard let a = read("STPhrases.txt"), let b = read("STCharacters.txt"), let c = read("TWPhrases.txt"), let d = read("TWVariants.txt") else { return nil }
        self.init(stPhrases: a, stChars: b, twPhrases: c, twVariants: d)
    }

    /// 至少 2% 的漢字是簡體專用字才算簡體書
    public func looksSimplified(_ s: String) -> Bool {
        var han = 0, simp = 0
        for c in s.utf16 where c >= 0x4E00 && c <= 0x9FFF {
            han += 1
            if simplifiedOnly.contains(c) { simp += 1 }
        }
        return han > 0 && simp * 100 >= han * 2
    }

    public func hasSimplified(_ s: String) -> Bool { s.utf16.contains { simplifiedOnly.contains($0) } }

    public func convert(_ s: String) -> String { twv.convert(twp.convert(st.convert(s))) }

    /// 內文：轉繁體，並把 “ ” 換成「 」
    public func convertIfNeeded(_ s: String) -> String {
        guard looksSimplified(s) else { return s }
        return convert(s).replacingOccurrences(of: "\u{201C}", with: "「").replacingOccurrences(of: "\u{201D}", with: "」")
    }

    public func title(_ s: String) -> String { hasSimplified(s) ? convert(s) : s }
}
