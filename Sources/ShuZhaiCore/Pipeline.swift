import Foundation

/// 章節文字處理流程：原文 → 整理段落 → 繁簡轉換 → 取代規則 → 段首縮排 → 拿掉樣式標記。
/// 閱讀、搜尋、朗讀、書籤都用同一份，位置才對得上（與 Android 版相同）。
public final class TextPipeline {
    public let store: LibraryStore
    public var converter: S2TWConverter?
    public var chineseOn: Bool = true
    public var rules: [ReplaceRule] = []

    public init(store: LibraryStore) { self.store = store }

    public func displayRules(for bookId: String) -> [ReplaceRule] {
        rules.filter { $0.enabled && !$0.ttsOnly && ($0.scope.isEmpty || $0.scope == bookId) }
    }

    public func ttsRules(for bookId: String) -> [ReplaceRule] {
        rules.filter { $0.enabled && $0.ttsOnly && ($0.scope.isEmpty || $0.scope == bookId) }
    }

    public func rich(_ bookId: String, _ index: Int) -> Rich {
        let raw = store.readChapter(bookId, index)
        var t = ChapterSplitter.format(raw, indent: false)
        if chineseOn, let c = converter { t = c.convertIfNeeded(t) }
        return Rich.parse(RuleEngine.finish(RuleEngine.apply(t, displayRules(for: bookId))))
    }

    public func title(_ s: String) -> String {
        guard chineseOn, let c = converter, !s.isEmpty else { return s }
        return c.title(s)
    }
}
