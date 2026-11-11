import SwiftUI
import AVFoundation
import MediaPlayer
import ShuZhaiCore

/// 朗讀：一句一句交給 AVSpeechSynthesizer；用 willSpeakRange 得知念到哪個字，畫面跟著翻頁。
/// 鎖螢幕繼續念（背景音訊），鎖定畫面與耳機可以控制。
@MainActor
final class TtsController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    struct State: Equatable {
        var bookId = ""
        var chapter = 0
        var paraStart = 0
        var paraEnd = 0
        var position = 0
        var playing = false
        var active = false
        var sleepAt: Date?
        var sleepEndOfChapter = false
    }

    @Published private(set) var state = State()
    var active: Bool { state.active }
    var bookId: String { state.bookId }

    private unowned let app: AppModel
    private let synth = AVSpeechSynthesizer()
    private var book: Book?
    private var toc: [TocEntry] = []
    private var chapter = 0
    private var text: [UInt16] = []
    private var paras: [Range<Int>] = []
    private var para = 0
    private var enqueuedUpTo = -1
    private var info: [ObjectIdentifier: (para: Int, chunk: Int, base: Int, last: Bool)] = [:]
    private var sleepTimer: Timer?
    private var resumeAfterInterruption = false
    private var lastSave = Date.distantPast

    init(app: AppModel) {
        self.app = app
        super.init()
        synth.delegate = self
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        setupRemote()
    }

    // ── 控制 ──
    func start(bookId: String, chapter ch: Int, offset: Int) {
        if state.active && state.bookId == bookId { jump(chapter: ch, offset: offset); return }
        guard let b = app.store.book(bookId) else { return }
        app.ensureConverter()
        book = b
        toc = app.store.toc(bookId)
        load(ch)
        para = paras.firstIndex { offset < $0.upperBound } ?? 0
        state.bookId = bookId
        state.active = true
        resume()
    }

    func jump(chapter ch: Int, offset: Int) {
        if ch != chapter { load(ch) }
        para = paras.firstIndex { offset < $0.upperBound } ?? 0
        if state.playing { speak(from: para) } else { resume() }
    }

    func toggle() { state.playing ? pause() : resume() }

    func resume() {
        guard state.active else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: [])
        try? s.setActive(true)
        state.playing = true
        speak(from: para)
        updateNowPlaying()
    }

    func pause() {
        guard state.playing else { return }
        state.playing = false
        halt()
        saveProgress(force: true)
        updateNowPlaying()
    }

    func stop() {
        state.playing = false
        halt()
        saveProgress(force: true)
        setSleep(0)
        state.active = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func nextPara() {
        if para < paras.count - 1 { para += 1 }
        else if chapter < toc.count - 1 { load(chapter + 1) }
        if state.playing { speak(from: para) } else { publish() }
    }

    func prevPara() {
        if para > 0 { para -= 1 }
        else if chapter > 0 { load(chapter - 1); para = max(0, paras.count - 1) }
        if state.playing { speak(from: para) } else { publish() }
    }

    /// 語速、音調、語音改了：從目前這段重念
    func settingsChanged() { if state.playing { speak(from: para) } }

    /// minutes：0 取消、-1 本章結束
    func setSleep(_ minutes: Int) {
        sleepTimer?.invalidate(); sleepTimer = nil
        state.sleepAt = nil; state.sleepEndOfChapter = false
        if minutes > 0 {
            state.sleepAt = Date().addingTimeInterval(Double(minutes) * 60)
            sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sleepTick() }
            }
        } else if minutes < 0 { state.sleepEndOfChapter = true }
    }

    private func sleepTick() {
        guard let at = state.sleepAt else { return }
        if Date() >= at, !state.playing { stop() }
        objectWillChange.send()
    }

    // ── 內部 ──
    private func load(_ ch: Int) {
        guard let b = book else { return }
        chapter = min(max(0, ch), max(0, toc.count - 1))
        text = Array(app.pipeline.rich(b.id, chapter).text.utf16)
        var list: [Range<Int>] = []
        var s = 0
        while s < text.count {
            var e = s
            while e < text.count && text[e] != 0x0A { e += 1 }
            if text[s..<e].contains(where: { !($0 == 0x20 || $0 == 0x3000 || $0 == 0xFFFC) }) { list.append(s..<e) }
            s = e + 1
        }
        paras = list
        para = 0
        enqueuedUpTo = -1
    }

    private func halt() {
        info = [:]
        enqueuedUpTo = -1
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
    }

    private func speak(from p: Int) {
        halt()
        guard !paras.isEmpty else { chapterFinished(); return }
        para = min(max(0, p), paras.count - 1)
        state.position = paras[para].lowerBound
        enqueue(para)
        enqueue(para + 1)
        publish()
    }

    /// 把段落切成一句一句
    private func chunks(_ u: ArraySlice<UInt16>) -> [Range<Int>] {
        let enders: Set<UInt16> = Set("。！？；!?;…".utf16)
        let closers: Set<UInt16> = Set("」』”’）)】".utf16)
        let commas: Set<UInt16> = Set("，,、：:".utf16)
        var out: [Range<Int>] = []
        var start = u.startIndex
        var i = u.startIndex
        while i < u.endIndex {
            var cut = -1
            if enders.contains(u[i]) {
                var j = i + 1
                while j < u.endIndex && (enders.contains(u[j]) || closers.contains(u[j])) { j += 1 }
                cut = j
            } else if i - start >= 120 && commas.contains(u[i]) { cut = i + 1 }
            else if i - start >= 300 { cut = i + 1 }
            if cut > 0 { out.append(start..<cut); start = cut; i = cut } else { i += 1 }
        }
        if start < u.endIndex { out.append(start..<u.endIndex) }
        var merged: [Range<Int>] = []
        for r in out {
            if let last = merged.last, r.count <= 2 { merged[merged.count - 1] = last.lowerBound..<r.upperBound } else { merged.append(r) }
        }
        return merged
    }

    private func enqueue(_ p: Int) {
        guard p < paras.count, p > enqueuedUpTo, let b = book else { return }
        let r = paras[p]
        let rules = app.pipeline.ttsRules(for: b.id)
        let cs = chunks(text[r])
        for (k, c) in cs.enumerated() {
            let raw = String(utf16CodeUnits: Array(text[c]), count: c.count)
            var spoken = RuleEngine.apply(raw, rules).replacingOccurrences(of: "\u{3000}", with: " ").replacingOccurrences(of: "\u{FFFC}", with: "")
            if spoken.trimmingCharacters(in: .whitespaces).isEmpty { spoken = " " }
            let u = AVSpeechUtterance(string: spoken)
            u.voice = voice()
            u.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(app.ttsRate)))
            u.pitchMultiplier = Float(min(2, max(0.5, app.ttsPitch)))
            u.postUtteranceDelay = 0
            info[ObjectIdentifier(u)] = (p, k, c.lowerBound, k == cs.count - 1)
            synth.speak(u)
        }
        enqueuedUpTo = p
    }

    func voice() -> AVSpeechSynthesisVoice? {
        if !app.ttsVoice.isEmpty, let v = AVSpeechSynthesisVoice(identifier: app.ttsVoice) { return v }
        return AVSpeechSynthesisVoice(language: "zh-TW") ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }

    static func chineseVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }.sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    private func chapterFinished() {
        if state.sleepEndOfChapter { stop(); return }
        if chapter >= toc.count - 1 { pause(); return }
        load(chapter + 1)
        speak(from: 0)
        updateNowPlaying()
    }

    private func publish() {
        var s = state
        s.chapter = chapter
        if para < paras.count { s.paraStart = paras[para].lowerBound; s.paraEnd = paras[para].upperBound }
        if s != state { state = s }
    }

    // ── AVSpeechSynthesizerDelegate ──
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in
            guard let i = self.info[id] else { return }
            if i.chunk == 0 { self.para = i.para; self.enqueue(i.para + 1); self.saveProgress() }
            self.state.position = i.base
            self.publish()
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in
            guard let i = self.info[id], i.para == self.para else { return }
            let p = i.base + r.location
            if p != self.state.position { self.state.position = p }
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in
            guard let i = self.info.removeValue(forKey: id), self.state.playing else { return }
            guard i.last else { return }
            if let at = self.state.sleepAt, Date() >= at { self.stop(); return }
            if i.para >= self.paras.count - 1 { self.chapterFinished() }
        }
    }

    // ── 中斷：來電、其他 App 播放、拔耳機 ──
    @objc nonisolated private func interrupted(_ n: Notification) {
        guard let t = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) else { return }
        Task { @MainActor in
            if t == .began { if self.state.playing { self.resumeAfterInterruption = true; self.pause() } }
            else {
                let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
                if self.resumeAfterInterruption && opts.contains(.shouldResume) { self.resume() }
                self.resumeAfterInterruption = false
            }
        }
    }

    @objc nonisolated private func routeChanged(_ n: Notification) {
        guard let r = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init),
              r == .oldDeviceUnavailable else { return }
        Task { @MainActor in self.pause() }
    }

    // ── 鎖定畫面與耳機 ──
    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.nextPara() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.prevPara() }; return .success }
    }

    private func updateNowPlaying() {
        guard let b = book else { return }
        let ch = chapter < toc.count ? app.title(toc[chapter].title) : ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: ch,
            MPMediaItemPropertyArtist: app.title(b.title),
            MPNowPlayingInfoPropertyPlaybackRate: state.playing ? 1.0 : 0.0,
        ]
    }

    private func saveProgress(force: Bool = false) {
        guard var b = app.store.book(state.bookId), !paras.isEmpty else { return }
        b.progChapter = chapter
        b.progOffset = paras[min(para, paras.count - 1)].lowerBound
        b.progPercent = min(1, (Double(chapter) + Double(b.progOffset) / Double(max(1, text.count))) / Double(max(1, toc.count)))
        b.lastReadAt = nowMillis()
        let save = force || Date().timeIntervalSince(lastSave) > 5
        if save { lastSave = Date() }
        app.store.update(b, save: save)
    }
}

/// 閱讀頁下方的「朗讀」面板
struct TtsPanel: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: ReaderModel
    @EnvironmentObject var tts: TtsController
    private let accent = Color(UIColor(rgb: 0xD9A866))

    var mine: Bool { tts.state.active && tts.state.bookId == model.book.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(!mine ? "按「播放」從目前這一頁開始朗讀；也可以長按任一段文字，從那裡開始" : tts.state.playing ? "朗讀中" : "已暫停")
                    .font(.footnote).foregroundColor(.gray).padding(.top, 14)
                HStack(spacing: 8) {
                    ctl("上一段", "backward.end.fill") { tts.prevPara() }
                    ctl(mine && tts.state.playing ? "暫停" : "播放", mine && tts.state.playing ? "pause.fill" : "play.fill") {
                        if mine { tts.toggle() } else { tts.start(bookId: model.book.id, chapter: model.chapter, offset: model.currentOffset) }
                    }
                    ctl("下一段", "forward.end.fill") { tts.nextPara() }
                    ctl("停止", "stop.fill") { tts.stop() }
                }
                SliderRow(name: "語速", value: app.ttsRate, range: 0.5...2.0, step: 0.05, fmt: { String(format: "%.2f×", $0) }) {
                    app.ttsRate = $0; tts.settingsChanged()
                }
                SliderRow(name: "音調", value: app.ttsPitch, range: 0.5...2.0, step: 0.05, fmt: { String(format: "%.2f", $0) }) {
                    app.ttsPitch = $0; tts.settingsChanged()
                }
                Text("定時關閉").font(.footnote).foregroundColor(accent).padding(.top, 10)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    ChipRow {
                        sleepChip("關閉", 0, selected: tts.state.sleepAt == nil && !tts.state.sleepEndOfChapter)
                        sleepChip("15 分", 15, selected: false)
                        sleepChip("30 分", 30, selected: false)
                        sleepChip("60 分", 60, selected: false)
                        sleepChip("本章結束", -1, selected: tts.state.sleepEndOfChapter)
                        if let at = tts.state.sleepAt {
                            let left = max(0, Int(at.timeIntervalSince(ctx.date)))
                            Text(String(format: "剩 %d:%02d", left / 60, left % 60)).foregroundColor(accent)
                        }
                    }
                }
                Text("語音").font(.footnote).foregroundColor(accent).padding(.top, 10)
                ChipRow {
                    voiceChip("預設（台灣）", id: "")
                    ForEach(TtsController.chineseVoices(), id: \.identifier) { v in
                        let region = v.language.hasSuffix("TW") ? "台灣" : v.language.hasSuffix("HK") ? "香港" : v.language.hasSuffix("CN") ? "中國" : v.language
                        voiceChip("\(region) \(v.name)", id: v.identifier)
                    }
                }
                Text("可到 iPhone「設定 → 輔助使用 → 語音內容 → 語音」下載更自然的「加強版」語音。")
                    .font(.caption).foregroundColor(.gray).padding(.top, 6)
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
    }

    func ctl(_ t: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) { Image(systemName: icon).font(.title3); Text(t).font(.caption) }
                .frame(maxWidth: .infinity).padding(.vertical, 10).background(Color(white: 0.2)).cornerRadius(10)
        }.buttonStyle(.plain)
    }

    func sleepChip(_ t: String, _ m: Int, selected: Bool) -> some View {
        Button {
            if !mine { model.message = "請先開始朗讀"; return }
            tts.setSleep(m)
        } label: {
            Text(t).font(.subheadline).padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? accent : Color(white: 0.2)).foregroundColor(selected ? .black : .white).cornerRadius(16)
        }.buttonStyle(.plain)
    }

    func voiceChip(_ t: String, id: String) -> some View {
        let sel = app.ttsVoice == id
        return Button { app.ttsVoice = id; tts.settingsChanged() } label: {
            Text(t).font(.subheadline).lineLimit(1).padding(.horizontal, 14).padding(.vertical, 7)
                .background(sel ? accent : Color(white: 0.2)).foregroundColor(sel ? .black : .white).cornerRadius(16)
        }.buttonStyle(.plain)
    }
}
