import Foundation
import ZIPFoundation

/// 設定檔：prefs.json，格式與 Android 版備份裡的 prefs.json 相同（{"key": {"t": 型別, "v": 值}}），
/// 所以兩邊的備份可以直接互相還原。
public final class Prefs {
    public let file: URL
    private var values: [String: Any] = [:]

    public init(file: URL) {
        self.file = file
        load()
    }

    public func load() {
        values = [:]
        guard let d = try? Data(contentsOf: file),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        for (k, e) in o {
            guard let e = e as? [String: Any], let t = e["t"] as? String, let v = e["v"] else { continue }
            switch t {
            case "s": if let s = v as? String { values[k] = s }
            case "i", "l": if let n = v as? NSNumber { values[k] = n.intValue }
            case "f": if let n = v as? NSNumber { values[k] = n.doubleValue }
            case "b": if let b = v as? Bool { values[k] = b } else if let n = v as? NSNumber { values[k] = n.boolValue }
            default: break
            }
        }
    }

    public func save() {
        var o: [String: Any] = [:]
        for (k, v) in values {
            switch v {
            case let b as Bool: o[k] = ["t": "b", "v": b]
            case let i as Int: o[k] = ["t": "i", "v": i]
            case let d as Double: o[k] = ["t": "f", "v": d]
            case let s as String: o[k] = ["t": "s", "v": s]
            default: break
            }
        }
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) { try? d.write(to: file, options: .atomic) }
    }

    public func string(_ k: String, _ def: String = "") -> String { values[k] as? String ?? def }
    public func int(_ k: String, _ def: Int = 0) -> Int { values[k] as? Int ?? def }
    public func double(_ k: String, _ def: Double = 0) -> Double { (values[k] as? Double) ?? (values[k] as? Int).map(Double.init) ?? def }
    public func bool(_ k: String, _ def: Bool = false) -> Bool { values[k] as? Bool ?? def }

    public func set(_ k: String, _ v: Any?) {
        if let v { values[k] = v } else { values.removeValue(forKey: k) }
        save()
    }
}

/// 排版樣式；JSON 欄位與 Android 版 ReadStyle 相同
public struct ReadStyle: Codable, Equatable {
    public var fontKey = ""            // "" 系統預設、"serif" 宋體、"font:檔名"
    public var fontSize = 20
    public var letterSpacing = 0.0     // em
    public var lineSpacing = 1.6
    public var paraSpacing = 0.5
    public var marginH = 20
    public var marginTop = 8
    public var marginBottom = 8
    public var weight = 1              // 0 細、1 標準、2 粗
    public var dayTheme = 1
    public var nightTheme = 8
    public var customBg = Int(Int32(bitPattern: 0xFFF4ECD8))
    public var customFg = Int(Int32(bitPattern: 0xFF2B2B2B))
    public var customImage = false
    public var imageBlur = 8
    public var imageDim = 20
    public var showHeader = true
    public var showTime = true
    public var showBattery = true
    public var showPage = true
    public var showPercent = true

    public init() {}

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = ReadStyle()
        func v<T: Decodable>(_ k: CodingKeys, _ x: T) -> T { (try? c.decode(T.self, forKey: k)) ?? x }
        fontKey = v(.fontKey, def.fontKey); fontSize = v(.fontSize, def.fontSize)
        letterSpacing = v(.letterSpacing, def.letterSpacing); lineSpacing = v(.lineSpacing, def.lineSpacing)
        paraSpacing = v(.paraSpacing, def.paraSpacing); marginH = v(.marginH, def.marginH)
        marginTop = v(.marginTop, def.marginTop); marginBottom = v(.marginBottom, def.marginBottom)
        weight = v(.weight, def.weight); dayTheme = v(.dayTheme, def.dayTheme); nightTheme = v(.nightTheme, def.nightTheme)
        customBg = v(.customBg, def.customBg); customFg = v(.customFg, def.customFg); customImage = v(.customImage, def.customImage)
        imageBlur = v(.imageBlur, def.imageBlur); imageDim = v(.imageDim, def.imageDim)
        showHeader = v(.showHeader, def.showHeader); showTime = v(.showTime, def.showTime); showBattery = v(.showBattery, def.showBattery)
        showPage = v(.showPage, def.showPage); showPercent = v(.showPercent, def.showPercent)
    }

    public func json() -> String { (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "{}" }
    public static func from(json: String) -> ReadStyle? { try? JSONDecoder().decode(ReadStyle.self, from: Data(json.utf8)) }
}

/// 書架分組：存在 prefs 的 "groups"（JSON 字串陣列），與 Android 版相同
public enum Groups {
    public static func all(_ p: Prefs) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(p.string("groups", "[]").utf8))) ?? []
    }
    public static func save(_ p: Prefs, _ l: [String]) {
        p.set("groups", String(decoding: (try? JSONEncoder().encode(l)) ?? Data("[]".utf8), as: UTF8.self))
    }
}

/// 排版方案：prefs 的 "schemes"：[{"name":..., "style":{...}}]
public enum Schemes {
    struct Item: Codable { let name: String; let style: ReadStyle }
    public static func all(_ p: Prefs) -> [(String, ReadStyle)] {
        let l = (try? JSONDecoder().decode([Item].self, from: Data(p.string("schemes", "[]").utf8))) ?? []
        return l.map { ($0.name, $0.style) }
    }
    public static func save(_ p: Prefs, _ l: [(String, ReadStyle)]) {
        let items = l.map { Item(name: $0.0, style: $0.1) }
        p.set("schemes", String(decoding: (try? JSONEncoder().encode(items)) ?? Data("[]".utf8), as: UTF8.self))
    }
}

/// 備份與還原：書、進度、書籤、取代規則、字型、背景照片、設定。zip 格式與 Android 版相同。
public enum Backup {
    static let mark = "shuzhai-backup.json"
    static let items = ["books.json", "rules.json", "bg.jpg", "prefs.json"]
    static let dirs = ["books", "fonts"]

    public static func export(root: URL, to dest: URL, bookCount: Int) throws {
        try? FileManager.default.removeItem(at: dest)
        let a = try Archive(url: dest, accessMode: .create)
        let info = try JSONSerialization.data(withJSONObject: ["app": "書齋", "version": 1, "time": nowMillis(), "books": bookCount, "platform": "ios"])
        try a.addEntry(with: mark, type: .file, uncompressedSize: Int64(info.count), provider: { pos, size in info.subdata(in: Int(pos)..<Int(pos) + size) })
        let fm = FileManager.default
        for n in items where fm.fileExists(atPath: root.appendingPathComponent(n).path) {
            try a.addEntry(with: n, relativeTo: root, compressionMethod: .deflate)
        }
        for d in dirs {
            let base = root.appendingPathComponent(d)
            for rel in (fm.subpaths(atPath: base.path) ?? []).sorted() {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: base.appendingPathComponent(rel).path, isDirectory: &isDir), !isDir.boolValue else { continue }
                try a.addEntry(with: d + "/" + rel, relativeTo: root, compressionMethod: .deflate)
            }
        }
    }

    /// 回傳還原後的書本數；不是書齋備份時丟出錯誤，現有資料不動
    public static func restore(from src: URL, root: URL) throws -> Int {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let a = try Archive(url: src, accessMode: .read)
        let base = tmp.standardizedFileURL.path + "/"
        for e in a {
            let dest = tmp.appendingPathComponent(e.path).standardizedFileURL
            guard dest.path.hasPrefix(base) else { continue }     // 防止路徑穿越
            if e.type == .directory { try fm.createDirectory(at: dest, withIntermediateDirectories: true); continue }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try a.extract(e, to: dest, skipCRC32: true)
        }
        guard fm.fileExists(atPath: tmp.appendingPathComponent(mark).path),
              fm.fileExists(atPath: tmp.appendingPathComponent("books.json").path) else {
            throw EpubError.invalid("這不是書齋的備份檔")
        }
        for n in dirs + items { try? fm.removeItem(at: root.appendingPathComponent(n)) }
        for n in dirs + items {
            let s = tmp.appendingPathComponent(n)
            if fm.fileExists(atPath: s.path) { try fm.moveItem(at: s, to: root.appendingPathComponent(n)) }
        }
        let books = (try? JSONDecoder().decode([Book].self, from: Data(contentsOf: root.appendingPathComponent("books.json")))) ?? []
        return books.count
    }
}
