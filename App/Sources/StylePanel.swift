import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ShuZhaiCore

private let accentUI = Color(UIColor(rgb: 0xD9A866))
private let chipBg = Color(white: 0.2)

/// 閱讀頁下方的「介面」面板，調整立即套用
struct StylePanel: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: ReaderModel
    @State private var tab = Demo.styleTab
    @State private var importFont = false
    @State private var photoItem: PhotosPickerItem?
    @State private var schemeName = ""
    @State private var askScheme = false
    @State private var fontToDelete: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("排版").tag(0); Text("主題").tag(1); Text("其他").tag(2)
            }
            .pickerStyle(.segmented).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
            .colorScheme(.dark)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    switch tab {
                    case 0: layoutTab
                    case 1: themeTab
                    default: otherTab
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .fileImporter(isPresented: $importFont, allowedContentTypes: [.font, .data], allowsMultipleSelection: false) { r in
            if case .success(let urls) = r, let u = urls.first {
                if let key = Fonts.importFont(u, root: app.root) { app.style.fontKey = key; app.fontsVersion += 1 }
                else { model.message = "這個檔案不是可用的字型" }
            }
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), Backgrounds.savePhoto(d, root: app.root) {
                    app.style.customImage = true
                    if model.isNight { app.style.nightTheme = ReaderTheme.custom } else { app.style.dayTheme = ReaderTheme.custom }
                } else { model.message = "無法讀取這張照片" }
                photoItem = nil
            }
        }
        .alert("存成排版方案", isPresented: $askScheme) {
            TextField("方案名稱", text: $schemeName)
            Button("儲存") {
                var l = Schemes.all(app.prefs)
                let n = schemeName.trimmingCharacters(in: .whitespaces).isEmpty ? "方案 \(l.count + 1)" : schemeName
                l.removeAll { $0.0 == n }; l.append((n, app.style))
                Schemes.save(app.prefs, l); app.objectWillChange.send()
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("刪除字型「\(Fonts.displayName(fontToDelete ?? ""))」？",
                            isPresented: Binding(get: { fontToDelete != nil }, set: { if !$0 { fontToDelete = nil } }), titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                if let k = fontToDelete { Fonts.delete(k, root: app.root); if app.style.fontKey == k { app.style.fontKey = "" }; app.fontsVersion += 1 }
            }
        }
    }

    // ───────── 排版 ─────────
    @ViewBuilder var layoutTab: some View {
        label("字型")
        ChipRow {
            chip("系統預設", app.style.fontKey == "") { app.style.fontKey = "" }
            chip("系統襯線", app.style.fontKey == "serif") { app.style.fontKey = "serif" }
            ForEach(Fonts.files(app.root), id: \.self) { f in
                let key = "font:" + f
                chip(Fonts.displayName(key), app.style.fontKey == key) { app.style.fontKey = key }
                    .onLongPressGesture { fontToDelete = key }
            }
            chip("＋ 匯入字型", false) { importFont = true }
        }
        hint("可匯入 TTF／OTF 字型檔；長按匯入的字型可刪除")
        stepRow("字級", value: app.style.fontSize, range: 12...40) { app.style.fontSize = $0 }
        SliderRow(name: "章名大小", value: app.style.titleScale, range: 0.7...1.6, step: 0.05, fmt: { String(format: "%.2f 倍", $0) }) { app.style.titleScale = $0 }
        HStack {
            Text("粗細").font(.body)
            Spacer()
            Segmented(options: ["細", "標準", "粗"], selected: app.style.weight) { app.style.weight = $0 }
        }.frame(minHeight: 44)
        SliderRow(name: "字距", value: app.style.letterSpacing, range: -0.05...0.3, step: 0.01, fmt: { String(format: "%.2f", $0) }) { app.style.letterSpacing = $0 }
        SliderRow(name: "行距", value: app.style.lineSpacing, range: 1.0...3.0, step: 0.05, fmt: { String(format: "%.2f", $0) }) { app.style.lineSpacing = $0 }
        SliderRow(name: "段距", value: app.style.paraSpacing, range: 0...2, step: 0.1, fmt: { String(format: "%.1f", $0) }) { app.style.paraSpacing = $0 }
        SliderRow(name: "左右邊距", value: Double(app.style.marginH), range: 0...60, step: 1, fmt: { "\(Int($0))" }) { app.style.marginH = Int($0) }
        SliderRow(name: "上邊距", value: Double(app.style.marginTop), range: 0...60, step: 1, fmt: { "\(Int($0))" }) { app.style.marginTop = Int($0) }
        SliderRow(name: "下邊距", value: Double(app.style.marginBottom), range: 0...60, step: 1, fmt: { "\(Int($0))" }) { app.style.marginBottom = Int($0) }

        label("排版方案")
        let schemes = Schemes.all(app.prefs)
        ChipRow {
            ForEach(Array(schemes.enumerated()), id: \.offset) { item in
                chip(item.element.0, false) { app.style = item.element.1 }
                    .contextMenu {
                        Button(role: .destructive) {
                            var l = schemes; l.remove(at: item.offset); Schemes.save(app.prefs, l); app.objectWillChange.send()
                        } label: { Label("刪除方案", systemImage: "trash") }
                    }
            }
            chip("＋ 存成方案", false) { schemeName = ""; askScheme = true }
        }
        hint("例如「白天通勤」「睡前閱讀」；長按方案可刪除")
    }

    // ───────── 主題 ─────────
    @ViewBuilder var themeTab: some View {
        let night = model.isNight
        HStack {
            Text(night ? "目前：夜間模式" : "目前：白天模式")
            Spacer()
            Segmented(options: ["白天", "夜間"], selected: night ? 1 : 0) { i in
                if app.followSystem && (i == 1) != model.systemDark { app.followSystem = false }
                app.night = i == 1
            }
        }.frame(minHeight: 44)
        hint(night ? "點色塊更換「夜間」使用的背景" : "點色塊更換「白天」使用的背景")
        let cur = night ? app.style.nightTheme : app.style.dayTheme
        ChipRow {
            ForEach(0..<ReaderTheme.presets.count, id: \.self) { i in swatch(ReaderTheme.presets[i], i == cur) { setTheme(i) } }
            swatch(ReaderTheme.resolve(app.style, ReaderTheme.custom), cur == ReaderTheme.custom) { setTheme(ReaderTheme.custom) }
        }
        label("自訂主題")
        ColorPicker("文字顏色", selection: Binding(get: { Color(UIColor(argb: app.style.customFg)) },
                                              set: { app.style.customFg = UIColor($0).argb; setTheme(ReaderTheme.custom) }), supportsOpacity: false)
            .frame(minHeight: 40)
        ColorPicker("背景顏色", selection: Binding(get: { Color(UIColor(argb: app.style.customBg)) },
                                              set: { app.style.customBg = UIColor($0).argb; app.style.customImage = false; setTheme(ReaderTheme.custom) }), supportsOpacity: false)
            .frame(minHeight: 40)
        HStack {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Text("用照片當背景").padding(.horizontal, 14).padding(.vertical, 7).background(app.style.customImage ? accentUI : chipBg)
                    .foregroundColor(app.style.customImage ? .black : .white).cornerRadius(16)
            }
            if app.style.customImage { chip("移除照片", false) { app.style.customImage = false } }
        }
        if app.style.customImage {
            SliderRow(name: "模糊", value: Double(app.style.imageBlur), range: 0...25, step: 1, fmt: { "\(Int($0))" }) { app.style.imageBlur = Int($0) }
            SliderRow(name: "變暗", value: Double(app.style.imageDim), range: 0...80, step: 1, fmt: { "\(Int($0))%" }) { app.style.imageDim = Int($0) }
        }
        Toggle("跟隨系統深色模式", isOn: $app.followSystem).frame(minHeight: 44)
    }

    func setTheme(_ i: Int) {
        if model.isNight { app.style.nightTheme = i } else { app.style.dayTheme = i }
    }

    // ───────── 其他 ─────────
    @ViewBuilder var otherTab: some View {
        label("翻頁")
        HStack {
            Text("翻頁方式"); Spacer()
            Segmented(options: ["翻頁", "捲動"], selected: app.pageMode) { app.pageMode = $0 }
        }.frame(minHeight: 44)
        hint("翻頁：一頁一頁切換，沒有動畫；捲動：上下拖動連續閱讀，章節自動接續")
        label("文字")
        HStack {
            Text("繁簡轉換"); Spacer()
            Segmented(options: ["不轉換", "簡轉繁"], selected: app.chineseMode) { app.chineseMode = $0 }
        }.frame(minHeight: 44)
        hint("簡轉繁使用台灣用詞（例如 軟件→軟體），原本就是繁體的書不受影響")
        label("頁首與頁尾")
        Toggle("頁首顯示章名", isOn: $app.style.showHeader)
        Toggle("時間", isOn: $app.style.showTime)
        Toggle("電量", isOn: $app.style.showBattery)
        Toggle("本章頁碼", isOn: $app.style.showPage)
        Toggle("全書進度 %", isOn: $app.style.showPercent)
        label("螢幕")
        Toggle("閱讀時螢幕常亮", isOn: $app.keepOn)
        Toggle("顯示系統狀態列", isOn: $app.statusBar)
        Toggle("橫向時左右雙頁", isOn: $app.dualPage)
        Toggle("亮度跟隨系統", isOn: Binding(get: { app.brightness < 0 }, set: { app.brightness = $0 ? -1 : Double(UIScreen.main.brightness) }))
        if app.brightness >= 0 {
            SliderRow(name: "閱讀亮度", value: app.brightness * 100, range: 1...100, step: 1, fmt: { "\(Int($0))%" }) { app.brightness = $0 / 100 }
            hint("離開閱讀頁時會恢復原本的亮度")
        }
    }

    // ── 小元件 ──
    func label(_ t: String) -> some View { Text(t).font(.footnote).foregroundColor(accentUI).padding(.top, 14).padding(.bottom, 4) }
    func hint(_ t: String) -> some View { Text(t).font(.caption).foregroundColor(.gray).padding(.vertical, 2) }

    func chip(_ t: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.subheadline).lineLimit(1).padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? accentUI : chipBg).foregroundColor(selected ? .black : .white).cornerRadius(16)
        }.buttonStyle(.plain)
    }

    func swatch(_ t: ReaderTheme, _ selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text("文").font(.title3).foregroundColor(Color(t.fg)).frame(width: 50, height: 50)
                    .background(t.texture == 1 || t.texture == 2 ? AnyView(Image(uiImage: Backgrounds.texture(t.texture, base: t.bg)).resizable(resizingMode: .tile)) : AnyView(Color(t.bg)))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? accentUI : Color.white.opacity(0.3), lineWidth: selected ? 3 : 1))
                Text(t.name).font(.caption2).foregroundColor(selected ? accentUI : .gray).lineLimit(1)
            }.frame(width: 58)
        }.buttonStyle(.plain)
    }

    func stepRow(_ name: String, value: Int, range: ClosedRange<Int>, set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(name)
            Spacer()
            StepButton("−") { set(max(range.lowerBound, value - 1)) }
            Text("\(value)").font(.headline).frame(minWidth: 44)
            StepButton("+") { set(min(range.upperBound, value + 1)) }
        }.frame(minHeight: 48)
    }
}

struct StepButton: View {
    let t: String; let action: () -> Void
    init(_ t: String, action: @escaping () -> Void) { self.t = t; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(t).font(.title3).frame(width: 48, height: 36).background(chipBg).foregroundColor(.white).cornerRadius(10)
        }.buttonStyle(.plain)
    }
}

/// 名稱、數值一行；「− 滑桿 ＋」一行
struct SliderRow: View {
    let name: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let fmt: (Double) -> String
    let set: (Double) -> Void
    @State private var live: Double?

    var body: some View {
        let v = live ?? value
        VStack(spacing: 4) {
            HStack { Text(name); Spacer(); Text(fmt(v)).foregroundColor(accentUI) }
            HStack(spacing: 8) {
                StepButton("−") { set(clamp(value - step)) }
                Slider(value: Binding(get: { live ?? value }, set: { live = ($0 / step).rounded() * step }), in: range,
                       onEditingChanged: { editing in if !editing, let l = live { set(clamp(l)); live = nil } })
                StepButton("+") { set(clamp(value + step)) }
            }
        }
        .padding(.vertical, 6)
    }

    func clamp(_ x: Double) -> Double { min(range.upperBound, max(range.lowerBound, (x / step).rounded() * step)) }
}

struct Segmented: View {
    let options: [String]
    let selected: Int
    let pick: (Int) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { item in
                Button { pick(item.offset) } label: {
                    Text(item.element).font(.subheadline).lineLimit(1).padding(.horizontal, 12).padding(.vertical, 7)
                        .frame(minWidth: 52)
                        .background(item.offset == selected ? accentUI : chipBg)
                        .foregroundColor(item.offset == selected ? .black : .white).cornerRadius(10)
                }.buttonStyle(.plain)
            }
        }
    }
}

struct ChipRow<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { content }.padding(.vertical, 4) }
    }
}

/// 九宮格點擊區域
struct TapZonesView: View {
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var zones: [Int] = []
    @State private var warn = false
    let names = ["無", "下一頁", "上一頁", "選單"]
    let colors: [UIColor] = [UIColor(rgb: 0x555555), UIColor(rgb: 0x3F6B5B), UIColor(rgb: 0x4A5A86), UIColor(rgb: 0x8C5A2B)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                Text("這九格代表閱讀畫面，點格子切換「下一頁 → 上一頁 → 選單 → 無」").font(.footnote).foregroundColor(.secondary)
                    .padding(.bottom, 8)
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { c in
                            let i = r * 3 + c
                            Button {
                                guard zones.count == 9 else { return }
                                zones[i] = [1: 2, 2: 3, 3: 0, 0: 1][zones[i]] ?? 1
                            } label: {
                                Text(zones.count == 9 ? names[zones[i]] : "").foregroundColor(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color(zones.count == 9 ? colors[zones[i]] : .gray)).cornerRadius(8)
                            }
                        }
                    }
                }
                if warn { Text("至少要有一格是「選單」，不然叫不出選單").foregroundColor(.red).font(.footnote) }
            }
            .padding()
            .navigationTitle("點擊區域").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("還原預設") { zones = AppModel.defaultZones } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { if zones.contains(3) { app.tapZones = zones; dismiss() } else { warn = true } }
                }
            }
            .onAppear { zones = app.tapZones.count == 9 ? app.tapZones : AppModel.defaultZones }
        }
    }
}
