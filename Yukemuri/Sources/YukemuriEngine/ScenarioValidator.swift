import Foundation

/// 台本の検査結果
public struct ValidationReport: Sendable {
    /// 遊べなくなる問題（ない定型文・人物・意図・場所を参照している など）
    public var errors: [String] = []
    /// 遊べるが意図と違う可能性がある問題（出ない定型文 など）
    public var warnings: [String] = []
    /// 探索した状態の数
    public var stateCount = 0

    public var isValid: Bool { errors.isEmpty }
}

/// 台本の検査
///
/// 1. 参照の検査：条件・効果・話者が、台本にある定型文・人物・意図・場所を指しているか
/// 2. 到達可能性の検査：始まりの状態から、入力の候補（`GameRules.inputCandidates` と「どれにも当たらない入力」）を
///    幅優先ですべて試し、出ない定型文がないかを確かめる（警告）
///
/// 状態を変えず、どこからも参照されない定型文（`GameRules.inertLines`）は、出たかどうかを状態に含めない（状態の数を抑えるため）。
/// その代わり、手順1でそうした行が選ばれたときは、その行がもう出ていた場合の分岐も試す。
public struct ScenarioValidator: Sendable {
    /// 探索する状態数の上限（台本が大きくなりすぎたときの安全装置）
    public var maxStates = 200_000

    public init() {}

    public func validate(_ scenario: Scenario) -> ValidationReport {
        var report = ValidationReport()
        report.errors = references(scenario)
        guard report.errors.isEmpty else { return report }

        let rules = GameRules(scenario: scenario)
        var seenLines = Set<String>()
        var index: [GameState: Int] = [:]
        var queue: [GameState] = []
        var overflow = false

        func add(_ state: GameState) {
            let key = normalize(state, rules: rules)
            guard index[key] == nil else { return }
            guard queue.count < maxStates else { overflow = true; return }
            index[key] = queue.count
            queue.append(key)
        }

        let start = rules.start()
        start.lines.forEach { seenLines.insert($0.id) }
        add(start.state)
        var head = 0
        while head < queue.count, !overflow {
            let s = queue[head]
            head += 1
            for input in rules.inputCandidates(in: s) + rules.answeredIntents(in: s) + [PlayerInput.none] {
                var skipping = Set<String>()
                while true {
                    let step = rules.handle(input, in: s, skipping: skipping)
                    step.lines.forEach { seenLines.insert($0.id) }
                    add(step.state)
                    guard let chosen = step.chosenLine, rules.inertLines.contains(chosen), !skipping.contains(chosen) else { break }
                    skipping.insert(chosen)
                }
            }
        }
        report.stateCount = queue.count
        if overflow {
            report.errors.append("状態が \(maxStates) を超えたので、探索を打ち切った（検査の結果は不完全）")
        }
        for scene in scenario.scenes {
            for line in scene.lines where !seenLines.contains(line.id) {
                report.warnings.append("出ない定型文 \(line.id)（場面 \(scene.id)）")
            }
        }
        return report
    }

    /// 参照の検査
    func references(_ scenario: Scenario) -> [String] {
        var errors: [String] = []
        let lineIDs = scenario.scenes.flatMap(\.lines).map(\.id)
        var seen = Set<String>()
        for id in lineIDs where !seen.insert(id).inserted { errors.append("定型文の ID \(id) が重なっている") }
        let persons = Set(scenario.persons.map(\.id))
        let intents = Set(scenario.intents.map(\.id))
        let places = Set(scenario.scenes.map(\.place))
        if !persons.contains(scenario.partner) { errors.append("相棒 \(scenario.partner) が人物にない") }

        func check(_ expr: Expr, at label: String) {
            for atom in expr.atoms {
                switch atom {
                case .shown(let id), .after(let id), .next(let id), .before(let id), .turns(let id?, _):
                    if !seen.contains(id) { errors.append("\(label)：定型文 \(id) がない") }
                case .intent(let id):
                    if !intents.contains(id) { errors.append("\(label)：意図 \(id) がない") }
                case .move(let p), .place(let p):
                    if !places.contains(p) { errors.append("\(label)：場所 \(p) がない") }
                default: break
                }
            }
        }
        for scene in scenario.scenes {
            if let p = scene.person, !persons.contains(p) { errors.append("場面 \(scene.id)：人物 \(p) がない") }
            if let c = scene.canEnter { check(c, at: "場面 \(scene.id) の行ける条件") }
            for who in scene.freeTalk.keys where !persons.contains(who) { errors.append("場面 \(scene.id) の自由会話の指示：人物 \(who) がない") }
            for line in scene.lines {
                check(line.condition, at: line.id)
                if let s = line.speaker, !persons.contains(s) { errors.append("\(line.id)：話者 \(s) がない") }
                for effect in line.effects {
                    switch effect {
                    case .enterPerson(let p), .exitPerson(let p), .shake(let p), .moveSprite(let p, _), .expression(let p, _):
                        if !persons.contains(p) { errors.append("\(line.id)：人物 \(p) がない") }
                    case .flag: break
                    }
                }
            }
        }
        for person in scenario.persons {
            for k in person.knowledge { if let c = k.condition { check(c, at: "\(person.id) の知っていること「\(k.info.prefix(12))…」") } }
            for f in person.fallbacks { if let c = f.condition { check(c, at: f.id) } }
        }
        return errors
    }

    /// 状態の比較用の形（進行に影響しない差を消す）
    func normalize(_ state: GameState, rules: GameRules) -> GameState {
        var s = state
        s.shown = s.shown.subtracting(rules.inertLines)
        s.currentTurnLines = s.currentTurnLines.intersection(rules.nextReferenced)
        s.lastTurnLines = []
        return s
    }
}
