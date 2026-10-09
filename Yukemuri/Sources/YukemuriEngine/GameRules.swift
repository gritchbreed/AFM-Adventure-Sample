import Foundation

/// 規則の処理で起きたこと（画面に出す順）
public enum RuleEvent: Sendable, Hashable {
    /// 定型文を出した
    case line(Line)
    case sceneEntered(String)
    /// 演出（揺らす・動かす・表情）
    case presentation(Effect)
    /// 当たる定型文がなかったので、その場の人物が自由会話で答える（nil なら答える人がいない）
    case freeTalk(respondent: String?)
    /// 今の場所を離れようとしたので、行き先の一覧を出す
    case destinationsRequested
    /// その場所には今は行けない
    case moveRejected(String)
}

/// 1回の処理の結果
public struct Step: Sendable {
    public var state: GameState
    public var events: [RuleEvent]
    /// 入力の条件を含む行のうち、選ばれた定型文
    public var chosenLine: String?

    /// 出した定型文
    public var lines: [Line] {
        events.compactMap { if case .line(let l) = $0 { l } else { nil } }
    }
}

/// 条件を評価するときの文脈
struct EvalContext {
    /// 入力（nil なら入力のない処理。入力の条件はすべて偽）
    var input: PlayerInput?
    /// 直前に出した定型文（`直後:` の判定）
    var justShown: String?
    /// これから出す定型文（`直前:` の判定）
    var beforeTarget: String?
    /// 場面に入ったとき（`初回`・`開始` の判定）
    var entry: Entry?

    struct Entry {
        var first = false
    }
}

/// ゲームの規則（定型文の選び方）
///
/// 状態を受け取り、新しい状態と起きたことを返す（状態は持たない）。
/// LLM は使わない。入力の解釈（意図の判定など）は呼び出し側が行い、`PlayerInput` で渡す。
///
/// 選び方：
/// 1. 入力の条件を含む行のうち、条件を満たす最初の1行を出す
/// 2. 入力の条件を含まない行を、入力の条件を偽として表の順にすべて出す（`直前:`・`直後:` の行は、その行の前後に続けて出す）
/// 3. 移動・離脱の入力なら、場面を移る・行き先の一覧を出す
/// 4. 当たる行がなければ、その場の人物の自由会話にする
public struct GameRules: Sendable {
    public let scenario: Scenario
    /// 往復の起点になる定型文と、数える上限（条件に書いた最大の回数）
    let turnCaps: [String: Int]
    /// 場面ごとの、場面に入ってからの往復を数える上限
    let sceneTurnCaps: [String: Int]
    /// `次:` で参照される定型文
    public let nextReferenced: Set<String>
    /// 条件から参照される定型文
    public let referencedLines: Set<String>
    /// 状態を変えず、どこからも参照されない定型文（出たかどうかが進行に影響しない）
    public let inertLines: Set<String>

    public init(scenario: Scenario) {
        self.scenario = scenario
        let allLines = scenario.scenes.flatMap(\.lines)
        var exprs = allLines.map(\.condition)
        exprs += scenario.scenes.compactMap(\.canEnter)

        var caps: [String: Int] = [:]
        var next = Set<String>()
        var referenced = Set<String>()
        for atom in exprs.flatMap(\.atoms) {
            switch atom {
            case .shown(let id), .after(let id), .before(let id): referenced.insert(id)
            case .next(let id): referenced.insert(id); next.insert(id)
            case .turns(let from?, let n): referenced.insert(from); caps[from] = max(caps[from] ?? 0, n)
            default: break
            }
        }
        turnCaps = caps
        nextReferenced = next
        referencedLines = referenced
        inertLines = Set(allLines.filter { line in
            !referenced.contains(line.id) && !line.effects.contains(where: \.changesState)
        }.map(\.id))

        var sceneCaps: [String: Int] = [:]
        for scene in scenario.scenes {
            sceneCaps[scene.id] = scene.lines.flatMap(\.condition.atoms).compactMap { atom -> Int? in
                if case .turns(nil, let n) = atom { n } else { nil }
            }.max() ?? 0
        }
        sceneTurnCaps = sceneCaps
    }

    // MARK: - 始まり

    /// ゲームを始める（最初の場面に入る）
    public func start() -> Step {
        var run = Run(rules: self, state: GameState(), input: nil)
        run.enterScene(scenario.scenes[0].id)
        return run.finish()
    }

    // MARK: - 入力

    /// プレイヤーの入力1回を処理する
    /// - Parameter skipping: 手順1で、出ていないものとして飛ばす定型文（検査で使う）
    public func handle(_ input: PlayerInput, in state: GameState, skipping: Set<String> = []) -> Step {
        guard let scene = currentScene(state) else {
            return Step(state: state, events: [], chosenLine: nil)
        }
        var run = Run(rules: self, state: beginTurn(state), input: input)
        let startScene = scene.id

        // 手順1：入力の条件を含む行のうち、条件を満たす最初の1行
        let chosen = scopeLines(run.state).first { line in
            line.condition.containsInput && !skipping.contains(line.id) && run.eligible(line)
                && evaluate(line.condition, in: run.state, EvalContext(input: input))
        }
        if let chosen {
            run.chosenLine = chosen.id
            run.emit(chosen)
        }

        // 手順2：入力の条件を含まない行（と、手順1で選ばれなかった混ぜ書きの行）を、入力の条件を偽として表の順にすべて
        // 別の場所へ移る入力のときは出さない（「控え室に行こう」に、店内の話の続きが出てから移ることのないように）
        var leaving = false
        if case .move(let place) = input, destination(place, in: run.state) != nil { leaving = true }
        for line in scopeLines(run.state) where line.id != chosen?.id && !leaving {
            if run.state.scene != startScene { break }
            if run.eligible(line), evaluate(line.condition, in: run.state, EvalContext()) {
                run.emit(line)
            }
        }

        // 手順3：移動
        var moved = false
        if run.state.scene == startScene {
            switch input {
            case .move(let place):
                if let target = destination(place, in: run.state) {
                    run.enterScene(target.id)
                    moved = true
                } else {
                    run.events.append(.moveRejected(place))
                }
            case .leave:
                run.events.append(.destinationsRequested)
            default:
                break
            }
        }

        // 手順4：当たる行がなければ自由会話
        if chosen == nil, !moved, run.state.scene == startScene {
            run.events.append(.freeTalk(respondent: respondent(in: run.state)))
        }
        return run.finish()
    }

    /// 入力の処理の始めに、往復を数え、`次:` の基準を前の処理に移す
    func beginTurn(_ state: GameState) -> GameState {
        var s = state
        s.lastTurnLines = s.currentTurnLines
        s.currentTurnLines = []
        if let scene = s.scene {
            s.sceneTurns = min(s.sceneTurns + 1, sceneTurnCaps[scene] ?? 0)
        }
        for (k, v) in s.turnsSince {
            s.turnsSince[k] = min(v + 1, turnCaps[k] ?? 0)
        }
        return s
    }

    // MARK: - 問い合わせ

    public func currentScene(_ state: GameState) -> Scene? {
        state.scene.flatMap(scenario.scene)
    }

    /// 今の場面で効く定型文
    public func scopeLines(_ state: GameState) -> [Line] {
        currentScene(state)?.lines ?? []
    }

    /// 相棒がその場にいるか
    public func partnerPresent(in state: GameState) -> Bool {
        currentScene(state)?.partner ?? false
    }

    /// その場にいる人物（相棒を含む。相棒は最後）
    public func presentPersons(in state: GameState) -> [String] {
        var result: [String] = []
        if let p = currentScene(state)?.person, !state.personsRemoved.contains(p) { result.append(p) }
        result += state.personsAdded.sorted().filter { !result.contains($0) && !state.personsRemoved.contains($0) }
        if partnerPresent(in: state), !state.personsRemoved.contains(scenario.partner) {
            result.removeAll { $0 == scenario.partner }
            result.append(scenario.partner)
        }
        return result
    }

    /// 自由会話で答える人（その場の人物、いなければ相棒）
    public func respondent(in state: GameState) -> String? {
        let present = presentPersons(in: state)
        return present.first { $0 != scenario.partner } ?? present.first
    }

    /// 移動できる行き先の場面（行ける条件を満たすもの）
    public func destinations(in state: GameState) -> [Scene] {
        guard let scene = currentScene(state) else { return [] }
        return scenario.scenes.filter { s in
            s.id != scene.id && s.place != scene.place && (s.canEnter.map { evaluate($0, in: state, EvalContext()) } ?? true)
        }
    }

    func destination(_ place: String, in state: GameState) -> Scene? {
        destinations(in: state).first { $0.place == place }
    }

    /// 場所の名前（場面の順）
    public var places: [String] {
        var result: [String] = []
        for place in scenario.scenes.map(\.place) where !result.contains(place) { result.append(place) }
        return result
    }

    /// 意図の判定の候補
    ///
    /// その時点で、何かの定型文を起こしうる入力だけを返す。移動できる行き先も含む。
    /// `.none`（どれにも当たらない）は含まない。
    public func inputCandidates(in state: GameState) -> [PlayerInput] {
        guard currentScene(state) != nil else { return [] }
        let s = beginTurn(state)
        let exprs = scopeLines(s).filter { $0.repeatable || !s.shown.contains($0.id) }.map(\.condition)
        var result: [PlayerInput] = []
        var tried = Set<PlayerInput>()
        let noneCtx = EvalContext(input: PlayerInput.none)
        for atom in exprs.flatMap(\.atoms) {
            guard let input = atom.matchingInput, tried.insert(input).inserted else { continue }
            let ctx = EvalContext(input: input)
            // `次:` の行は入力の中身を問わず真になるので、「どれにも当たらない入力」と結果が違うものだけを候補にする
            if exprs.contains(where: { evaluate($0, in: s, ctx) && !evaluate($0, in: s, noneCtx) }) { result.append(input) }
        }
        for target in destinations(in: state) where !result.contains(.move(target.place)) {
            result.append(.move(target.place))
        }
        // その場を離れる入力（行き先の一覧を出す）は、行き先があればいつでも
        if !destinations(in: state).isEmpty, !result.contains(.leave) { result.append(.leave) }
        return result
    }

    /// 定型文をもう出し終えた意図（場面の定型文の条件に書かれているが、今は結果の変わらないもの）と、
    /// 定型文のない意図（知っていること・考えにだけ書かれた意図）
    ///
    /// 入力の解釈の候補に残して、同じ話題をもう一度聞かれたときに、近い別の意図に取り違えないようにする。
    /// 選ばれると、当たる行がないので自由会話になる（知っていること・考えの `意図:` の行が、プロンプトに入る）。
    public func answeredIntents(in state: GameState) -> [PlayerInput] {
        let candidates = Set(inputCandidates(in: state))
        let present = Set(presentPersons(in: state))
        // まだ出ていない行を前提にする行（`次:`・`直後:`・`済:`・`往復:` で、出ていない行を指す）の意図は残さない
        func prerequisites(_ e: Expr) -> [String] {
            switch e {
            case .and(let items): items.flatMap(prerequisites)
            case .next(let id), .after(let id), .shown(let id): [id]
            case .turns(let from?, _): [from]
            default: []
            }
        }
        let lines = scopeLines(state).filter { line in
            prerequisites(line.condition).allSatisfy { state.shown.contains($0) }
                && (line.kind != .dialogue || line.speaker.map(present.contains) ?? true)
        }
        var atoms = lines.flatMap(\.condition.atoms)
        for person in present {
            atoms += scenario.person(person)?.knowledge.compactMap(\.condition).flatMap(\.atoms) ?? []
        }
        var result: [PlayerInput] = []
        for atom in atoms {
            guard let input = atom.matchingInput, case .intent = input,
                  !candidates.contains(input), !result.contains(input) else { continue }
            result.append(input)
        }
        return result
    }

    /// その入力に、最初に定型文で答える人物（地の文や、当たる行がないときは nil）
    public func responder(to input: PlayerInput, in state: GameState) -> String? {
        for event in handle(input, in: state).events {
            if case .line(let line) = event { return line.kind == .dialogue ? line.speaker : nil }
        }
        return nil
    }

    /// その人物が、もう話した台詞（出した順ではなく、表の順）
    public func spokenLines(of person: String, in state: GameState) -> [Line] {
        scenario.scenes.flatMap(\.lines).filter { $0.kind == .dialogue && $0.speaker == person && state.shown.contains($0.id) }
    }

    /// 人物のプロンプトに入れる知っていること・考え（条件を満たすもの。`意図:` を含む行は、その意図の入力のときだけ）
    public func promptKnowledge(of person: String, in state: GameState, input: PlayerInput? = nil) -> [String] {
        guard let p = scenario.person(person) else { return [] }
        let ctx = EvalContext(input: input ?? PlayerInput.none)
        return p.knowledge.filter { k in
            k.condition.map { evaluate($0, in: state, ctx) } ?? true
        }.map(\.info)
    }

    /// 台詞の生成が拒否されたときの台詞（条件を満たすもののうち、避けたい ID 以外の最初の1つ。なければ避けたものも使う）
    public func fallbackLine(of person: String, in state: GameState, avoiding: Set<String> = []) -> FallbackLine? {
        let usable = scenario.person(person)?.fallbacks.filter { f in
            f.condition.map { evaluate($0, in: state, EvalContext()) } ?? true
        } ?? []
        return usable.first { !avoiding.contains($0.id) } ?? usable.first
    }

    // MARK: - 条件の評価

    /// 文脈のせいで真になったか（`直後:`・`直前:`・場面に入ったときの行を、状態だけで真の行と区別する）
    func triggered(_ expr: Expr, in s: GameState, _ c: EvalContext, baseline: EvalContext) -> Bool {
        evaluate(expr, in: s, c) && !evaluate(expr, in: s, baseline)
    }

    func evaluate(_ expr: Expr, in s: GameState, _ c: EvalContext) -> Bool {
        switch expr {
        case .and(let items): return items.allSatisfy { evaluate($0, in: s, c) }
        case .or(let items): return items.contains { evaluate($0, in: s, c) }
        case .not(let item): return !evaluate(item, in: s, c)
        case .always: return true
        case .firstVisit: return c.entry?.first == true
        case .enter: return c.entry != nil
        case .shown(let id): return s.shown.contains(id)
        case .place(let id): return currentScene(s)?.place == id
        case .flag(let id): return s.flags.contains(id)
        case .after(let id): return c.justShown == id
        case .before(let id): return c.beforeTarget == id
        case .next(let id): return c.input != nil && s.lastTurnLines.contains(id)
        case .turns(let from, let n):
            if let from { return (s.turnsSince[from] ?? -1) >= n }
            return s.sceneTurns >= n
        case .intent(let id): return c.input == .intent(id)
        case .move(let id): return c.input == .move(id)
        case .leave: return c.input == .leave
        }
    }
}

/// 1回の処理の作業領域
struct Run {
    let rules: GameRules
    var state: GameState
    let input: PlayerInput?
    var events: [RuleEvent] = []
    var chosenLine: String?
    /// 処理中の定型文（互いを `直前:`・`直後:` で参照する行を二重に出さない）
    var inProgress = Set<String>()

    init(rules: GameRules, state: GameState, input: PlayerInput?) {
        self.rules = rules
        self.state = state
        self.input = input
    }

    func eligible(_ line: Line) -> Bool {
        line.repeatable || !state.shown.contains(line.id)
    }

    /// 定型文を出す（`直前:` の行を先に出し、効果を適用し、`直後:` の行を続けて出す）
    mutating func emit(_ line: Line) {
        guard !inProgress.contains(line.id) else { return }
        inProgress.insert(line.id)
        defer { inProgress.remove(line.id) }

        for other in rules.scopeLines(state) where other.id != line.id && !inProgress.contains(other.id) && eligible(other) {
            if rules.triggered(other.condition, in: state, EvalContext(beforeTarget: line.id), baseline: EvalContext()) {
                emit(other)
            }
        }
        // `直前:` の行の連鎖の中で、この行がもう出ていれば出さない
        if !line.repeatable && state.shown.contains(line.id) { return }

        show(line)
        afterChain(of: line.id)
    }

    /// `直後:` の行を表の順にすべて出す
    mutating func afterChain(of id: String) {
        for other in rules.scopeLines(state) {
            guard !inProgress.contains(other.id), eligible(other) else { continue }
            if rules.triggered(other.condition, in: state, EvalContext(justShown: id), baseline: EvalContext()) {
                emit(other)
            }
        }
    }

    /// 定型文を出したことを記録し、効果を適用する
    mutating func show(_ line: Line) {
        state.shown.insert(line.id)
        state.currentTurnLines.insert(line.id)
        if rules.turnCaps[line.id] != nil { state.turnsSince[line.id] = 0 }
        events.append(.line(line))
        for effect in line.effects {
            switch effect {
            case .flag(let id): state.flags.insert(id)
            case .enterPerson(let p):
                state.personsAdded.insert(p)
                state.personsRemoved.remove(p)
            case .exitPerson(let p):
                state.personsRemoved.insert(p)
                state.personsAdded.remove(p)
            case .shake, .moveSprite, .expression:
                events.append(.presentation(effect))
            }
        }
    }

    /// 場面に入る（その場面の、入ったときに出る行を表の順に出す）
    mutating func enterScene(_ id: String) {
        guard let scene = rules.scenario.scene(id) else { return }
        state.scene = id
        state.sceneTurns = 0
        state.personsAdded = []
        state.personsRemoved = []
        let entry = EvalContext.Entry(first: state.visited.insert(id).inserted)
        events.append(.sceneEntered(id))
        for line in scene.lines {
            if eligible(line), rules.triggered(line.condition, in: state, EvalContext(entry: entry), baseline: EvalContext()) {
                emit(line)
            }
        }
    }

    func finish() -> Step {
        Step(state: state, events: events, chosenLine: chosenLine)
    }
}
