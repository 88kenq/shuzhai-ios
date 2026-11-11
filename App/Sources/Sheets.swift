import SwiftUI
import UniformTypeIdentifiers
import ShuZhaiCore

private let accent = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0xB9844F) : UIColor(rgb: 0x8C5A2B) })

// MARK: - 目錄與書籤

struct TocSheet: View {
    @ObservedObject var model: ReaderModel
    let onPick: (Int, Int) -> Void
    @State private var tab: Int
    @State private var query = ""
    @State private var marks: [Bookmark] = []
    @State private var editing: Bookmark?
    @State private var noteText = ""

    init(model: ReaderModel, startTab: Int, onPick: @escaping (Int, Int) -> Void) {
        self.model = model; self.onPick = onPick; _tab = State(initialValue: startTab)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("目錄").tag(0)
                    Text(marks.isEmpty ? "書籤" : "書籤（\(marks.count)）").tag(1)
                }
                .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
                if tab == 0 { tocList } else { markList }
            }
            .navigationTitle(model.app.title(model.book.title)).navigationBarTitleDisplayMode(.inline)
            .onAppear { marks = model.app.store.bookmarks(model.book.id) }
            .alert("書籤備註", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("備註", text: $noteText)
                Button("儲存") {
                    if let e = editing, let i = marks.firstIndex(of: e) {
                        marks[i].n = noteText.trimmingCharacters(in: .whitespaces)
                        model.app.store.saveBookmarks(model.book.id, marks)
                    }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    var tocList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(filtered, id: \.self) { i in
                    Button { onPick(i, 0) } label: {
                        Text(model.title(i)).lineLimit(1)
                            .fontWeight(i == model.chapter ? .bold : .regular)
                            .foregroundColor(i == model.chapter ? accent : .primary)
                    }.id(i)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜尋章名")
            .onAppear { DispatchQueue.main.async { proxy.scrollTo(model.chapter, anchor: .center) } }
            .overlay(alignment: .bottomTrailing) {
                Text("共 \(model.toc.count) 章").font(.caption).foregroundColor(.secondary).padding(8)
            }
        }
    }

    var filtered: [Int] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? Array(model.toc.indices) : model.toc.indices.filter { model.title($0).localizedCaseInsensitiveContains(q) }
    }

    @ViewBuilder var markList: some View {
        if marks.isEmpty {
            VStack { Spacer(); Text("還沒有書籤\n\n閱讀時點畫面中間，再按上方的書籤圖示加入").multilineTextAlignment(.center).foregroundColor(.secondary); Spacer() }
        } else {
            List {
                ForEach(marks) { m in
                    Button { onPick(m.c, m.o) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(model.title(m.c)) · \(Self.date(m.t))").font(.caption).foregroundColor(.secondary).lineLimit(1)
                            Text(m.x).foregroundColor(.primary).lineLimit(2)
                            if !m.n.isEmpty { Text(m.n).font(.subheadline).foregroundColor(accent) }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            marks.removeAll { $0 == m }; model.app.store.saveBookmarks(model.book.id, marks)
                        } label: { Label("刪除", systemImage: "trash") }
                        Button { noteText = m.n; editing = m } label: { Label("備註", systemImage: "pencil") }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    static func date(_ ms: Int64) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

// MARK: - 全書搜尋

struct SearchSheet: View {
    @ObservedObject var model: ReaderModel
    let onPick: (Int, Int, Int) -> Void
    @State private var query = ""
    @State private var hits: [Hit] = []
    @State private var status = "輸入關鍵字後按鍵盤上的搜尋"
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    struct Hit: Identifiable { let id = UUID(); let chapter: Int; let offset: Int; let title: String; let snippet: AttributedString }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("搜尋全書內容", text: $query)
                    .textFieldStyle(.roundedBorder).submitLabel(.search).focused($focused)
                    .onSubmit(start).padding(.horizontal).padding(.top, 8)
                Text(status).font(.footnote).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 6)
                List(hits) { h in
                    Button { onPick(h.chapter, h.offset, query.utf16.count) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(h.title).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            Text(h.snippet).lineLimit(3).foregroundColor(.primary)
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("全書搜尋").navigationBarTitleDisplayMode(.inline)
            .onAppear { focused = true }
            .onDisappear { task?.cancel() }
        }
    }

    func start() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        task?.cancel()
        hits = []
        status = "搜尋中…"
        let count = model.toc.count
        task = Task { @MainActor in
            var total = 0
            for i in 0..<count {
                if Task.isCancelled { return }
                let text = model.rich(i).text as NSString
                let title = model.title(i)
                var r = text.range(of: q, options: [.caseInsensitive])
                while r.location != NSNotFound && total < 1000 {
                    let from = max(0, r.location - 24), to = min(text.length, r.location + r.length + 40)
                    var snip = text.substring(with: NSRange(location: from, length: to - from))
                        .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{3000}", with: "").replacingOccurrences(of: "\u{FFFC}", with: "［圖］")
                    if from > 0 { snip = "…" + snip }
                    if to < text.length { snip += "…" }
                    var a = AttributedString(snip)
                    if let rr = a.range(of: q, options: .caseInsensitive) { a[rr].backgroundColor = .yellow.opacity(0.5); a[rr].font = .body.bold() }
                    hits.append(Hit(chapter: i, offset: r.location, title: title, snippet: a))
                    total += 1
                    let next = r.location + r.length
                    r = text.range(of: q, options: [.caseInsensitive], range: NSRange(location: next, length: text.length - next))
                }
                if i % 10 == 0 || i == count - 1 {
                    status = i < count - 1 && total < 1000 ? "搜尋中… 第 \(i + 1)／\(count) 章，找到 \(hits.count) 處" : ""
                    await Task.yield()
                }
                if total >= 1000 { break }
            }
            status = total >= 1000 ? "找到超過 1000 處，只列出前 1000 處" : "找到 \(hits.count) 處"
        }
    }
}

// MARK: - 取代規則

struct RulesView: View {
    @ObservedObject var app: AppModel
    let bookId: String?
    let bookTitle: String?
    let sample: String?
    @Environment(\.dismiss) var dismiss
    @State private var editing: ReplaceRule?
    @State private var exporting = false
    @State private var importing = false
    @State private var exportDoc: JSONDoc?
    @State private var info: String?

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("由上到下依序套用。左滑可刪除，按「編輯」可調整順序。")) {
                    ForEach(app.rules) { r in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.name.isEmpty ? r.pattern : r.name).lineLimit(1)
                                Text(summary(r)).font(.caption).foregroundColor(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { r.enabled }, set: { v in r.enabled = v; app.saveRules(app.rules) })).labelsHidden()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editing = r }
                    }
                    .onDelete { idx in var l = app.rules; l.remove(atOffsets: idx); app.saveRules(l) }
                    .onMove { from, to in var l = app.rules; l.move(fromOffsets: from, toOffset: to); app.saveRules(l) }
                }
            }
            .navigationTitle("取代規則").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button { importing = true } label: { Label("匯入規則", systemImage: "square.and.arrow.down") }
                        Button {
                            exportDoc = JSONDoc(data: (try? JSONEncoder().encode(app.rules)) ?? Data()); exporting = true
                        } label: { Label("匯出規則", systemImage: "square.and.arrow.up") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    EditButton()
                    Button { editing = ReplaceRule(pattern: "") } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: Binding(get: { editing.map { RuleBox(rule: $0) } }, set: { editing = $0?.rule })) { box in
                RuleEditor(app: app, rule: box.rule, bookId: bookId, bookTitle: bookTitle, sample: sample ?? "")
            }
            .fileExporter(isPresented: $exporting, document: exportDoc, contentType: .json, defaultFilename: "書齋取代規則") { _ in }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { r in
                guard case .success(let u) = r else { return }
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                guard let d = try? Data(contentsOf: u), let list = try? JSONDecoder().decode([ReplaceRule].self, from: d) else {
                    info = "檔案格式不對，無法匯入"; return
                }
                var l = app.rules
                for r in list where !r.pattern.isEmpty {
                    if let i = l.firstIndex(where: { $0.id == r.id }) { l[i] = r } else { l.append(r) }
                }
                app.saveRules(l); info = "已匯入 \(list.count) 條規則"
            }
            .alert(info ?? "", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) { Button("好") {} }
            .onAppear { if let s = sample, !s.isEmpty { editing = ReplaceRule(pattern: String(s.prefix(60))) } }
        }
    }

    func summary(_ r: ReplaceRule) -> String {
        let scope = r.scope.isEmpty ? "全部書" : r.scope == bookId ? "只有這本書" : "只有某本書"
        let rep = r.replacement.isEmpty ? "刪除" : "→ \(r.replacement)"
        return "\(r.ttsOnly ? "［朗讀］" : "")\(r.isRegex ? "［正規］" : "")\(r.pattern)  \(rep) · \(scope)"
    }
}

struct RuleBox: Identifiable { let rule: ReplaceRule; var id: String { rule.id } }

struct JSONDoc: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// 規則編輯：可即時測試
struct RuleEditor: View {
    @ObservedObject var app: AppModel
    let rule: ReplaceRule
    let bookId: String?
    let bookTitle: String?
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var pattern = ""
    @State private var replacement = ""
    @State private var isRegex = false
    @State private var ttsOnly = false
    @State private var onlyBook = false
    @State private var test = ""
    @State private var error: String?

    init(app: AppModel, rule: ReplaceRule, bookId: String?, bookTitle: String?, sample: String) {
        self.app = app; self.rule = rule; self.bookId = bookId; self.bookTitle = bookTitle
        _name = State(initialValue: rule.name); _pattern = State(initialValue: rule.pattern)
        _replacement = State(initialValue: rule.replacement); _isRegex = State(initialValue: rule.isRegex)
        _ttsOnly = State(initialValue: rule.ttsOnly); _onlyBook = State(initialValue: !rule.scope.isEmpty)
        _test = State(initialValue: sample)
    }

    var result: String {
        let r = ReplaceRule(pattern: pattern, replacement: replacement, isRegex: isRegex)
        if test.isEmpty { return "（沒有測試文字）" }
        let out = r.apply(test)
        return out.isEmpty ? "（整段被刪除）" : out
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名稱（可不填）") { TextField("例如：去除網站廣告", text: $name) }
                Section("尋找") { TextField("要被取代的文字", text: $pattern, axis: .vertical) }
                Section("取代成（留空＝刪除）") { TextField("留空代表直接刪除", text: $replacement) }
                Section {
                    Toggle("使用正規表達式（進階）", isOn: $isRegex)
                    Toggle("只用於朗讀（畫面上的文字不變）", isOn: $ttsOnly)
                    if bookId != nil || !rule.scope.isEmpty {
                        Toggle(bookTitle.map { "只套用《\($0)》" } ?? "只套用指定的書", isOn: $onlyBook)
                    }
                    if isRegex, !pattern.isEmpty, ReplaceRule.checkRegex(pattern) != nil {
                        Text("正規表達式寫錯了").foregroundColor(.red)
                    }
                }
                Section("測試：貼上一段文字看看效果") { TextField("在這裡貼一段文字", text: $test, axis: .vertical).lineLimit(2...6) }
                Section("結果") { Text(result) }
            }
            .navigationTitle(app.rules.contains { $0.id == rule.id } ? "編輯取代規則" : "新增取代規則")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        guard !pattern.isEmpty, !(isRegex && ReplaceRule.checkRegex(pattern) != nil) else { return }
                        rule.name = name.trimmingCharacters(in: .whitespaces); rule.pattern = pattern; rule.replacement = replacement
                        rule.isRegex = isRegex; rule.ttsOnly = ttsOnly
                        rule.scope = onlyBook ? (bookId ?? rule.scope) : ""
                        app.upsertRule(rule)
                        dismiss()
                    }.disabled(pattern.isEmpty)
                }
            }
        }
    }
}
