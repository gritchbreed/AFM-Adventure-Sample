import Foundation
import Observation
import SwiftUI
import YukemuriEngine
import YukemuriLLM

/// 画面の記録の1行
struct LogEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        /// 地の文
        case narration
        /// 人物の定型の台詞
        case dialogue(speaker: String)
        /// プレイヤーの入力
        case player
        /// 自由会話の台詞（LLM が生成した。定型文に戻したものを含む）
        case reply(speaker: String)
        /// 進行の知らせ（「ここにはいない」など）
        case system
    }

    let id = UUID()
    var kind: Kind
    var text: String
    /// 台詞の話し手の人物 ID（色に使う）
    var person: String? = nil
}

/// 舞台（背景と人物の絵）の状態
struct Stage: Equatable {
    struct Person: Identifiable, Equatable {
        /// 人物 ID
        let id: String
        /// 表情（通常・不安・笑顔・怒り・悲しみ）
        var expression: String
        /// `動かす:` で決めた位置（left・center・right。nil なら決まった位置）
        var position: String?
        /// 揺らした回数（増えるたびに揺れる）
        var shakes = 0
    }
    var sceneID: String?
    var background: String?
    var place: String?
    var people: [Person] = []
}

/// 舞台を変えること（記録の文字送りと同じ待ち行列で、順に行う）
enum StageChange: Equatable {
    /// 背景を切り替える（続けて出る人物は残し、いなくなる人物は消す）
    case enterScene(String)
    /// 場面の人物を出す（背景のフェードインの後）
    case scenePeople(String)
    case add(String)
    case remove(String)
    case expression(String, String)
    /// 表情を、その場面の初めの表情に戻す（プレイヤーの次の入力のとき。定型文で変えた表情は、その台詞の間だけ）
    case resetExpressions
    case shake(String)
    case move(String, String)
    /// 今の状態のその場の人物に合わせる（処理のまとまりの最後）
    case sync
}

/// プレイの画面の状態
@MainActor
@Observable
final class GameViewModel {
    enum Phase: Equatable {
        case loading
        /// モデルが使えない・台本が読めない
        case unavailable(String)
        case playing
    }

    private(set) var phase: Phase = .loading
    /// 出し終えた記録
    private(set) var log: [LogEntry] = []
    /// 文字送りの途中の記録と、出した文字数
    private(set) var typing: (entry: LogEntry, count: Int)?
    private(set) var busy = false
    /// 文字送りを待っている記録と、舞台の変化
    private enum QueueItem {
        case entry(LogEntry)
        case stage(StageChange)
    }
    private var queue: [QueueItem] = []
    /// 舞台（背景と人物の絵）
    private(set) var stage = Stage()
    private var revealTask: Task<Void, Never>?
    private var skipReveal = false
    /// メッセージ窓に出している行（文字送りの途中も、出し終えた後も、次の行が始まるまで残す）
    private(set) var currentLine: LogEntry?
    /// 返事を待つ間、窓の大きさと位置を残しておく前の行
    private(set) var previousLine: LogEntry?
    /// 次の行へ進むのを待っている（クリック・Enter・スペースか、オートの時間で進む）
    private(set) var waitingForAdvance = false
    private var advanceRequested = false
    /// 今の行の文字送りだけを飛ばす
    private var skipLine = false
    /// オート（文の長さに応じて、自動で次の行へ進む）の設定のキー
    static let autoAdvanceKey = "autoAdvance"
    private var autoAdvancing: Bool { UserDefaults.standard.object(forKey: Self.autoAdvanceKey) as? Bool ?? true }
    /// 窓の右下に、まだ行が続く印（▼）を出す
    var showsAdvanceMark: Bool { waitingForAdvance }

    /// 文字送りの途中か（終わるまで入力を受け付けない）
    var isRevealing: Bool { typing != nil || !queue.isEmpty }
    /// プレイヤーの入力を待っている（返事の処理も文字送りも終わっている）
    var awaitingInput: Bool { phase == .playing && !busy && !isRevealing }
    private(set) var state: GameState?
    /// 会話の記録（ログ）の画面
    var showLog = false
    var showDestinations = false
    var showDebug = false
    /// 画面内のメニューの板を開いている（GameMenu.swift）
    var showMenu = false
    /// 入力欄の話し相手（人物 ID。nil なら自動）
    var addressee: String?

    /// デバッグの画面の表示：直前の入力の解釈と返事
    struct LastTurn: Equatable {
        var text: String
        var candidates: [String]
        var interpreted: String
        var interpretMs: Int
        var interpretError: String?
        var lines: [String]
        var replySource: String?
        var replyMs: Int?
        var replyErrors: [String]
        var replyProblems: [String]
    }
    private(set) var lastTurn: LastTurn?
    /// 最後に台詞を作ったときに、モデルに渡した instructions
    private(set) var lastPrompt: String?
    /// 主人公の記憶（デバッグの画面に出す「項目＝値（聞いた人）」）
    private(set) var memory: [String] = []
    /// 呼び出しごとに、最後に使った文脈の大きさ（画面の上の札に出す）
    private(set) var contextUsage: [ContextUsage.Call: ContextUsage] = [:]

    /// 試作プレイのログ（入力ごとに、解釈と出た定型文を残す）
    let playLog = PlayLog()
    private var session: GameSession?
    private(set) var rules: GameRules?

    // MARK: - 始まり

    func load() async {
        let availability = ModelAvailability.system()
        guard availability.isAvailable else {
            phase = .unavailable(availability.reasonText)
            return
        }
        guard let url = Bundle.main.url(forResource: "scenario", withExtension: "json") else {
            phase = .unavailable("台本（scenario.json）がアプリに入っていません")
            return
        }
        do {
            let rules = GameRules(scenario: try Scenario.load(from: url))
            self.rules = rules
            Self.applyContextOverride()
            var memoryExtractor = FoundationModelsMemoryExtractor()
            memoryExtractor.usageObserver = usageObserver
            let (interpreter, talker) = makeModels()
            session = GameSession(rules: rules, interpreter: interpreter, talker: talker, memoryExtractor: memoryExtractor)
            // 主人公の記憶を取り出したことをログに残し、デバッグの画面に出す
            await session?.setMemoryObserver { [weak self] note in
                Task { @MainActor in
                    self?.recordUI(note)
                    await self?.refreshMemory()
                }
            }
            recordUI("文脈の大きさ：\(contextDescription)")
            await restart()
        } catch {
            phase = .unavailable("台本を読み込めません：\(error)")
        }
    }

    /// 画面の動きをログに残す（kind `ui`）
    func recordUI(_ text: String) {
        playLog.record(kind: "ui", text: text, before: nil, after: state, events: [])
    }

    /// 最初から遊ぶ
    func restart() async {
        guard let session else { return }
        resetLog()
        let events = await session.start()
        show(events)
        await refresh()
        await refreshMemory()
        playLog.record(kind: "start", text: "最初から", before: nil, after: state, events: events)
    }

    // MARK: - 入力

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session, !trimmed.isEmpty, !busy, !isRevealing else { return }
        busy = true
        defer { busy = false }
        // 返事を待つ間は、窓に読み込み中の印を出す（プレイヤーの入力は窓に出さず、ログだけに残す）
        holdWindowForReply()
        enqueue(LogEntry(kind: .player, text: trimmed))
        // 性的な語・差別語・暴言・連絡先を含む入力は、AFM に渡さず、地の文で受け流す。ログにも本文を残さない
        if ContentFilter.blocksInput(trimmed) {
            enqueue(LogEntry(kind: .narration, text: GameSession.blockedInputNarration))
            playLog.record(kind: "input", text: "（伏せた入力）", before: state, after: state, events: [])
            return
        }
        resetExpressionsIfNeeded()
        let before = state
        let candidates = before.flatMap { s in rules.map { InterpretChoices.make(rules: $0, state: s).options.map(\.input) } } ?? []
        let picked = addressee.flatMap { presentIDs.contains($0) ? $0 : nil }
        let turn = await session.send(trimmed, to: picked)
        show(turn.events)
        await refresh()
        let prompt = turn.reply == nil ? nil : await session.lastPrompt
        lastPrompt = prompt?.instructions ?? lastPrompt
        lastTurn = LastTurn(text: trimmed, candidates: candidates.map(\.description), interpreted: turn.input.description,
                            interpretMs: turn.interpretMs, interpretError: turn.interpretError,
                            lines: turn.events.compactMap { if case .line(let l, _) = $0 { l.id } else { nil } },
                            replySource: turn.reply.map { $0.source.rawValue }, replyMs: turn.reply?.milliseconds,
                            replyErrors: turn.reply?.errors ?? [], replyProblems: turn.reply?.problems ?? [])
        // つらさを打ち明けた入力は、人に見られたくない内容なので、ログに本文と、それを含むプロンプトを残さない
        let distress = ContentFilter.expressesDistress(trimmed)
        playLog.record(kind: "input", text: distress ? "（伏せた入力：つらさの打ち明け）" : trimmed, before: before, after: state,
                       candidates: candidates, turn: turn, events: turn.events, prompt: distress ? nil : prompt)
    }

    /// 行き先の一覧から行き先を選ぶ
    func move(to place: String) async {
        guard let session, !busy else { return }
        busy = true
        defer { busy = false }
        holdWindowForReply()
        enqueue(LogEntry(kind: .player, text: "（\(place)へ）"))
        resetExpressionsIfNeeded()
        let before = state
        let turn = await session.perform(.move(place))
        show(turn.events)
        await refresh()
        playLog.record(kind: "move", text: place, before: before, after: state, turn: turn, events: turn.events)
    }

    // MARK: - 表示

    /// 今いる場面
    var scene: YukemuriEngine.Scene? {
        guard let rules, let state else { return nil }
        return rules.currentScene(state)
    }

    /// その場にいる人物の表示名
    var people: [String] { presentIDs.map(displayName) }

    /// その場にいる人物の ID（話し相手の選択に使う）
    var presentIDs: [String] {
        guard let rules, let state else { return [] }
        return rules.presentPersons(in: state)
    }

    var destinations: [YukemuriEngine.Scene] {
        guard let rules, let state else { return [] }
        return rules.destinations(in: state)
    }

    /// 人物の表示名（ママ、葵）
    func displayName(_ person: String) -> String {
        rules?.scenario.person(person)?.speakerName ?? person
    }

    /// 人物の色の名前
    func colorName(of person: String?) -> String? {
        person.flatMap { rules?.scenario.person($0)?.color }
    }

    /// 人物の絵の ID（絵のない人物は nil。舞台に出さない）
    func sprite(of person: String) -> String? {
        rules?.scenario.person(person)?.sprite
    }

    var inputPlaceholder: String { "話しかける（ママ、葵）" }

    // MARK: - 文脈の大きさ

    /// 文脈の大きさの設定（0 は自動。4096・8192 は固定）。メニューの「開発」で切り替える
    static let contextKey = "contextSizeSetting"

    static func applyContextOverride() {
        let setting = UserDefaults.standard.integer(forKey: contextKey)
        ContextBudget.override = setting > 0 ? setting : nil
    }

    /// 今使っている文脈の大きさの説明（デバッグ画面とログ）
    var contextDescription: String {
        let budget = ContextBudget.system()
        return ContextBudget.override == nil ? "自動（端末の値 \(budget.contextSize)）" : "\(budget.contextSize) に固定"
    }

    /// 文脈の大きさの設定を、遊んでいる途中でも反映する（入力の解釈と台詞の生成を作り直す。会話の状態はそのまま）
    func applyContextSetting() async {
        Self.applyContextOverride()
        guard let session else { return }
        let (interpreter, talker) = makeModels()
        await session.replaceModels(interpreter: interpreter, talker: talker)
        contextUsage = [:]
        recordUI("文脈の大きさを切り替えた：\(contextDescription)")
    }

    /// 入力の解釈と台詞の生成（今の文脈の大きさで作り、使った量を知らせるようにする）
    private func makeModels() -> (any InputInterpreting, any Talking) {
        var interpreter = FoundationModelsInterpreter()
        interpreter.usageObserver = usageObserver
        var talker = FoundationModelsTalker()
        talker.usageObserver = usageObserver
        return (RefinedInterpreter(inner: interpreter), talker)
    }

    private var usageObserver: @Sendable (ContextUsage) -> Void {
        { [weak self] usage in Task { @MainActor in self?.contextUsage[usage.call] = usage } }
    }

    /// 使った文脈の大きさの説明（例「解釈 812/8,192 10%」。まだ呼んでいなければ「解釈 -」）
    var contextUsageText: String {
        ContextUsage.Call.allCases.map { call in
            guard let u = contextUsage[call] else { return "\(call.rawValue) -" }
            return "\(call.rawValue) \(u.used.formatted())/\(u.contextSize.formatted()) \(Int((u.ratio * 100).rounded()))%"
        }.joined(separator: "　")
    }

    var debugSummary: StateSummary? { state.map(StateSummary.init) }
    var debugCandidates: [String] {
        guard let rules, let state else { return [] }
        return InterpretChoices.make(rules: rules, state: state).options.map { "\($0.input)" }
    }

    private func refreshMemory() async {
        guard let session else { return }
        memory = await session.memory.sorted { $0.key < $1.key }.map { slot, item in
            "\(slot)＝\(item.value)（\(item.heardBy.map(displayName).joined(separator: "・"))）"
        }
    }

    // MARK: - 文字送り

    /// 1文字あたりの間（秒）。地の文は、台詞より少しゆっくり出す
    static func charDelay(for entry: LogEntry) -> Double {
        if case .narration = entry.kind { return 0.055 }
        return 0.04
    }

    /// 句読点のあとの間（秒）
    static func pause(after c: Character, narration: Bool) -> Double {
        let base: Double = switch c {
        case "、", "，": 0.18
        case "。", "！", "？", "!", "?": 0.32
        case "…", "―": 0.08
        default: 0
        }
        return narration ? base * 1.3 : base
    }

    /// 地の文と人物の台詞は1文字ずつ出す。入力・知らせは、まとめて出す
    static func typesOut(_ entry: LogEntry) -> Bool {
        switch entry.kind {
        case .dialogue, .reply, .narration: true
        default: false
        }
    }

    /// 画面に出す文面：句点（。）の後で改行する。閉じ括弧の直前と文の終わりでは改行しない
    static func lineBroken(_ text: String) -> String {
        let closers: Set<Character> = ["」", "』", "）", ")", "】"]
        let chars = Array(text)
        var result = ""
        for (i, c) in chars.enumerated() {
            result.append(c)
            guard c == "。", i + 1 < chars.count else { continue }
            let next = chars[i + 1]
            if closers.contains(next) || next == "\n" { continue }
            result.append("\n")
        }
        return result
    }

    private func enqueue(_ entry: LogEntry) {
        enqueue(item: .entry(entry))
    }

    /// 定型文で変えた表情を、プレイヤーの次の入力で場面の初めの表情に戻す
    /// （自由会話の返事では表情を変えないので、戻さないと言葉と表情がずれる）
    private func resetExpressionsIfNeeded() {
        if stage.people.contains(where: { $0.expression != defaultExpression(of: $0.id) }) { enqueueStage(.resetExpressions) }
    }

    private func enqueueStage(_ change: StageChange) {
        enqueue(item: .stage(change))
    }

    private func enqueue(item: QueueItem) {
        queue.append(item)
        guard revealTask == nil else { return }
        revealTask = Task { [weak self] in
            await self?.reveal()
        }
    }

    private func reveal() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            guard case .entry(let entry) = item else {
                if case .stage(let change) = item { await perform(change) }
                continue
            }
            if Self.typesOut(entry) && !skipReveal {
                let chars = Array(entry.text)
                let narration = entry.kind == .narration
                currentLine = entry
                skipLine = false
                typing = (entry, 0)
                for i in chars.indices {
                    if skipReveal || skipLine || Task.isCancelled { break }
                    typing = (entry, i + 1)
                    try? await Task.sleep(for: .seconds(Self.charDelay(for: entry) + Self.pause(after: chars[i], narration: narration)))
                }
                // 先に記録に加えてから、間を置く（間を置いてから加えると、その間だけ行が消えてちらつく）
                log.append(entry)
                typing = nil
                skipLine = false
                if !skipReveal && hasNextBeat { await waitForAdvance(after: entry) }
            } else {
                log.append(entry)
                if Self.showsInWindow(entry) {
                    currentLine = entry
                    if !skipReveal && hasNextBeat { await waitForAdvance(after: entry) }
                }
            }
        }
        skipReveal = false
        revealTask = nil
    }

    /// メッセージ窓に出す記録（プレイヤーの入力は、ログだけに残す）
    static func showsInWindow(_ entry: LogEntry) -> Bool {
        entry.kind != .player
    }

    /// 待ち行列に、窓の行を替えるか場面を変えるものが残っているか（残っていなければ、最後の行として待たずに入力へ移る）
    private var hasNextBeat: Bool {
        queue.contains { item in
            switch item {
            case .entry(let e): Self.showsInWindow(e)
            case .stage(let change): if case .enterScene = change { true } else { false }
            }
        }
    }

    /// 次の行へ進むのを待つ。手で送るときは押されるまで、オートのときは文の長さに応じた時間
    private func waitForAdvance(after entry: LogEntry) async {
        advanceRequested = false
        waitingForAdvance = true
        defer {
            waitingForAdvance = false
            advanceRequested = false
        }
        let clock = ContinuousClock()
        let end = clock.now + .seconds(Timing.autoBase + Timing.autoPerChar * Double(entry.text.count))
        while !advanceRequested, !skipReveal, !Task.isCancelled, !autoAdvancing || clock.now < end {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 台詞の窓を寄せる側（-1 左・0 中央・1 右）。話し手が舞台にいなければ中央
    func messageSide(of person: String?) -> Int {
        guard let person, let p = stage.people.first(where: { $0.id == person }) else { return 0 }
        switch p.position {
        case "left": return -1
        case "center": return 0
        case "right": return 1
        default: return isPartnerOnRight(person) ? 1 : -1
        }
    }

    /// 相棒を右に置くか（ほかの人物と並ぶときだけ右。相棒だけのときは左）
    func isPartnerOnRight(_ person: String) -> Bool {
        guard let partner = rules?.scenario.partner, person == partner else { return false }
        return stage.people.contains { $0.id != partner }
    }

    /// 返事を待つ間は窓の行を消し、窓の形は前の行のまま残す（窓の中に読み込み中の印を出す）
    private func holdWindowForReply() {
        previousLine = currentLine ?? previousLine
        currentLine = nil
    }

    /// プレイヤーの「次へ」（舞台のクリック・Enter・スペース）。文字送りの途中なら、その行だけを出し切る
    func advance() {
        if typing != nil {
            skipLine = true
        } else if waitingForAdvance {
            advanceRequested = true
        }
    }

    // MARK: - 舞台

    /// 人物の絵の高さ（舞台の高さに対する割合）
    static let spriteHeightRatio: CGFloat = 0.74

    /// 演出の長さ（秒）
    enum Timing {
        static let fade = 0.35
        static let people = 0.4
        /// オートで次の行へ進むまでの時間：基本の時間＋1文字あたりの時間（秒）
        static let autoBase = 0.6
        static let autoPerChar = 0.03
    }

    /// 早送りされるまで待つ
    private func pause(_ seconds: Double) async {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(seconds)
        while !skipReveal, clock.now < end {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 舞台を変える。フェードの後に待つものは、終わるまで次の記録を出さない（早送り中は、すぐに）
    private func perform(_ change: StageChange) async {
        func animate(_ duration: Double, _ body: () -> Void) {
            if skipReveal { body() } else { withAnimation(.easeInOut(duration: duration), body) }
        }
        switch change {
        case .enterScene:
            currentLine = nil
            animate(Timing.fade) { apply(change) }
            await pause(Timing.fade)
        case .scenePeople:
            animate(Timing.people) { apply(change) }
            await pause(Timing.people)
        default:
            animate(Timing.fade) { apply(change) }
        }
    }

    /// その場面での、人物の表情の初め（場面の `expressions`。書いていなければ通常）
    private func defaultExpression(of person: String) -> String {
        stage.sceneID.flatMap { rules?.scenario.scene($0)?.expressions?[person] } ?? "通常"
    }

    /// 場面に入ったときにいる人物（場面の人物と、相棒。絵のある人物だけ）
    private func scenePeople(_ scene: YukemuriEngine.Scene) -> [String] {
        var people = scene.person.map { [$0] } ?? []
        if scene.partner, let partner = rules?.scenario.partner { people.append(partner) }
        return ordered(people).filter { sprite(of: $0) != nil }
    }

    /// 相棒を最後（右）に並べる
    private func ordered(_ people: [String]) -> [String] {
        let partner = rules?.scenario.partner
        return people.filter { $0 != partner } + people.filter { $0 == partner }
    }

    private func apply(_ change: StageChange) {
        switch change {
        case .enterScene(let id):
            guard let scene = rules?.scenario.scene(id) else { return }
            let continuing = Set(scenePeople(scene))
            stage.sceneID = id
            stage.background = scene.background
            stage.place = scene.title
            // 続けて同じ場面にいる人物（相棒など）は残す
            stage.people = stage.people.filter { continuing.contains($0.id) }
                .map { Stage.Person(id: $0.id, expression: defaultExpression(of: $0.id), position: nil) }
        case .scenePeople(let id):
            guard let scene = rules?.scenario.scene(id) else { return }
            for p in scenePeople(scene) { apply(.add(p)) }
        case .add(let person):
            guard sprite(of: person) != nil, !stage.people.contains(where: { $0.id == person }) else { return }
            stage.people.append(Stage.Person(id: person, expression: defaultExpression(of: person)))
            let order = ordered(stage.people.map(\.id))
            stage.people.sort { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }
        case .remove(let person):
            stage.people.removeAll { $0.id == person }
        case .expression(let person, let name):
            if let i = stage.people.firstIndex(where: { $0.id == person }) { stage.people[i].expression = name }
        case .resetExpressions:
            for i in stage.people.indices { stage.people[i].expression = defaultExpression(of: stage.people[i].id) }
        case .shake(let person):
            if let i = stage.people.firstIndex(where: { $0.id == person }) { stage.people[i].shakes += 1 }
        case .move(let person, let position):
            if let i = stage.people.firstIndex(where: { $0.id == person }) { stage.people[i].position = position }
        case .sync:
            guard let rules, let state else { return }
            if let id = state.scene, id != stage.sceneID { apply(.enterScene(id)) }
            let present = rules.presentPersons(in: state).filter { sprite(of: $0) != nil }
            for p in stage.people.map(\.id) where !present.contains(p) { apply(.remove(p)) }
            for p in present { apply(.add(p)) }
        }
    }

    /// 文字送りを飛ばして、待っている記録をすべて出す
    func finishReveal() {
        guard isRevealing else { return }
        skipReveal = true
    }

    private func resetLog() {
        currentLine = nil
        previousLine = nil
        waitingForAdvance = false
        revealTask?.cancel()
        revealTask = nil
        queue = []
        typing = nil
        skipReveal = false
        log = []
        stage = Stage()
        lastTurn = nil
        lastPrompt = nil
    }

    private func refresh() async {
        guard let session else { return }
        state = await session.state
        enqueueStage(.sync)
        // 選んでいた話し相手がいなくなったら、自動に戻す
        if let a = addressee, !presentIDs.contains(a) { addressee = nil }
        phase = .playing
    }

    private func show(_ events: [SessionEvent]) {
        for event in events {
            switch event {
            case .line(let line, let text):
                // 表情・揺らす・動かすは、文面を出す前に、書いた順に
                for effect in line.effects {
                    switch effect {
                    case .expression(let person, let name): enqueueStage(.expression(person, name))
                    case .shake(let person): enqueueStage(.shake(person))
                    case .moveSprite(let person, let position): enqueueStage(.move(person, position))
                    default: break
                    }
                }
                switch line.kind {
                case .narration: enqueue(LogEntry(kind: .narration, text: Self.lineBroken(text)))
                case .dialogue:
                    enqueue(LogEntry(kind: .dialogue(speaker: displayName(line.speaker ?? "")), text: Self.lineBroken(text), person: line.speaker))
                }
                // 登場・退場は、文面を出した後に
                for effect in line.effects {
                    switch effect {
                    case .enterPerson(let person): enqueueStage(.add(person))
                    case .exitPerson(let person): enqueueStage(.remove(person))
                    default: break
                    }
                }
            case .reply(let speaker, let text, _):
                enqueue(LogEntry(kind: .reply(speaker: displayName(speaker)), text: Self.lineBroken(text), person: speaker))
            case .notice(let text):
                enqueue(LogEntry(kind: .system, text: text))
            case .rule(let rule):
                switch rule {
                case .sceneEntered(let id):
                    // 背景を先に、人物をその後に出す
                    enqueueStage(.enterScene(id))
                    enqueueStage(.scenePeople(id))
                case .destinationsRequested: showDestinations = true
                case .moveRejected(let place):
                    let moved = events.contains { if case .rule(.sceneEntered) = $0 { true } else { false } }
                    if !moved { enqueue(LogEntry(kind: .system, text: "（\(place)には、今は行けない）")) }
                case .freeTalk(nil): enqueue(LogEntry(kind: .system, text: "（ここには、話し相手がいない）"))
                default: break
                }
            }
        }
    }
}
