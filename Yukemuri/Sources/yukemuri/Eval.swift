import Foundation
import YukemuriEngine
import YukemuriLLM

/// 評価データ（Yukemuri/Evaluation/*.json）
///
/// 評価用の発言は、解釈のプロンプトに入る台本の発言例と重ならないように書く（同じ言い方では、数字が甘くなる）。
struct EvalFile: Decodable {
    struct Setup: Decodable {
        /// 始まりからの入力（台本での書き方）
        var inputs: [String]
        /// たどり着くはずの場面（書いておくと、台本の変更で準備の入力が古くなったことに気づける）
        var scene: String?
    }

    struct Case: Decodable {
        var id: String
        var setup: String
        var text: String
        /// 正解の入力（どれか1つに当たればよい。台本での書き方）。ガードレールの評価では省略
        var expect: [String]?
        var category: String
        /// 答える人物（ガードレールの評価。省略時はその場の人物、いなければ相棒）
        var speaker: String?
        /// 直前のやりとり（ガードレールの評価。「主人公: …」「人物: …」の形。前の発言に仕込んだ指示を試すため）
        var history: [String]?
        var note: String?
    }

    var setups: [String: Setup]
    var cases: [Case]
}

/// 1件の結果（results/*.jsonl に書く）
struct EvalRecord: Encodable {
    var id: String
    var category: String
    var run: Int
    var text: String
    var expect: [String]?
    var interpreted: String?
    var interpretMs: Int?
    var interpretError: String?
    var correct: Bool?
    var speaker: String?
    var reply: String?
    var replyMs: Int?
    var replyError: String?
    var replyErrorDetail: String?
    /// generated / regenerated / fallback
    var replySource: String?
    /// 検査で見つかった問題（生成し直しの理由）
    var replyProblems: [String]?
    /// 評価で数える注意点（性別を示す語など）
    var replyNotes: [String]?
    /// 入力の検査（ContentFilter）で、ゲームでは AFM に渡さずに止める入力か
    var blocked: Bool?
}

enum Evaluator {
    static func load(_ path: String) -> EvalFile {
        do {
            return try JSONDecoder().decode(EvalFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            FileHandle.standardError.write(Data("評価データを読み込めません（\(path)）：\(error)\n".utf8))
            exit(2)
        }
    }

    /// 準備の入力を適用した状態
    static func prepare(_ setup: EvalFile.Setup, rules: GameRules) throws -> GameState {
        var state = rules.start().state
        for raw in setup.inputs {
            guard let input = PlayerInput(notation: raw) else { throw EvalError.badInput(raw) }
            state = rules.handle(input, in: state).state
        }
        if let expected = setup.scene, state.scene != expected {
            throw EvalError.wrongScene(expected: expected, actual: state.scene ?? "-")
        }
        return state
    }

    enum EvalError: Error, CustomStringConvertible {
        case badInput(String)
        case unknownSetup(String)
        case wrongScene(expected: String, actual: String)
        var description: String {
            switch self {
            case .badInput(let s): "読めない入力: \(s)"
            case .wrongScene(let e, let a): "準備の入力で場面 \(e) にたどり着かない（今は \(a)。台本の変更で入力が古くなった）"
            case .unknownSetup(let s): "準備 \(s) がない"
            }
        }
    }

    static func resultsURL(_ name: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = URL(fileURLWithPath: "Yukemuri/results", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name)-\(f.string(from: Date())).jsonl")
    }

    static func checkAvailability() {
        let availability = ModelAvailability.system()
        guard availability.isAvailable else {
            print("モデルを使えません：\(availability.reasonText)")
            exit(2)
        }
    }

    /// 入力の解釈の精度
    static func interpret(scenarioPath: String, evalPath: String, repeats: Int) async {
        checkAvailability()
        let rules = GameRules(scenario: loadScenario(scenarioPath))
        let file = load(evalPath)
        let interpreter = RefinedInterpreter(inner: FoundationModelsInterpreter())
        let out = resultsURL("interpret")
        var records: [EvalRecord] = []
        var states: [String: GameState] = [:]
        for c in file.cases {
            guard let setup = file.setups[c.setup] else { print("SKIP \(c.id): \(EvalError.unknownSetup(c.setup))"); continue }
            if states[c.setup] == nil {
                do { states[c.setup] = try prepare(setup, rules: rules) } catch { print("SKIP \(c.id): \(error)"); continue }
            }
            let state = states[c.setup]!
            let choices = InterpretChoices.make(rules: rules, state: state)
            for run in 1...repeats {
                var r = EvalRecord(id: c.id, category: c.category, run: run, text: c.text, expect: c.expect)
                do {
                    let result = try await interpreter.interpret(c.text, choices: choices)
                    r.interpreted = result.input.description
                    r.interpretMs = result.milliseconds
                    r.correct = c.expect.map { $0.contains(result.input.description) }
                } catch {
                    let e = LLMError.from(error)
                    r.interpretError = e.kind
                    r.correct = false
                }
                let mark = r.correct == true ? "OK " : "NG "
                print("\(mark)\(c.id)#\(run) [\(c.category)] 「\(c.text)」→ \(r.interpreted ?? "ERR(\(r.interpretError ?? ""))")（期待 \(c.expect?.joined(separator: "/") ?? "-")）")
                records.append(r)
            }
        }
        write(records, to: out)
        // 集計
        print("\n== 入力の解釈")
        let total = records.count
        let ok = records.filter { $0.correct == true }.count
        print("正解率: \(ok)/\(total)（\(percent(ok, total))）  エラー: \(records.filter { $0.interpretError != nil }.count)")
        for (cat, rs) in Dictionary(grouping: records, by: \.category).sorted(by: { $0.key < $1.key }) {
            let k = rs.filter { $0.correct == true }.count
            print("  \(cat): \(k)/\(rs.count)")
        }
        let ms = records.compactMap(\.interpretMs).sorted()
        if !ms.isEmpty { print("時間: 中央値 \(ms[ms.count / 2])ms / 最大 \(ms.last!)ms") }
        print("結果: \(out.path)")
    }

    /// ガードレール（解釈と台詞の生成が拒否されないか、悪意のある入力で物語の外にはみ出さないか）
    static func guardrail(scenarioPath: String, evalPath: String, repeats: Int) async {
        checkAvailability()
        let rules = GameRules(scenario: loadScenario(scenarioPath))
        let file = load(evalPath)
        let interpreter = RefinedInterpreter(inner: FoundationModelsInterpreter())
        let talker = SafeTalker(inner: FoundationModelsTalker())
        let out = resultsURL("guardrail")
        var records: [EvalRecord] = []
        var states: [String: GameState] = [:]
        for c in file.cases {
            guard let setup = file.setups[c.setup] else { print("SKIP \(c.id): \(EvalError.unknownSetup(c.setup))"); continue }
            if states[c.setup] == nil {
                do { states[c.setup] = try prepare(setup, rules: rules) } catch { print("SKIP \(c.id): \(error)"); continue }
            }
            let state = states[c.setup]!
            let choices = InterpretChoices.make(rules: rules, state: state)
            guard let speaker = c.speaker ?? rules.respondent(in: state) else { print("SKIP \(c.id): 答える人がいない"); continue }
            for run in 1...repeats {
                var r = EvalRecord(id: c.id, category: c.category, run: run, text: c.text, speaker: speaker)
                var input = PlayerInput.none
                do {
                    let result = try await interpreter.interpret(c.text, choices: choices)
                    input = result.input
                    r.interpreted = result.input.description
                    r.interpretMs = result.milliseconds
                } catch {
                    r.interpretError = LLMError.from(error).kind
                }
                var prompt = TalkPrompt.make(rules: rules, state: state, speaker: speaker, input: input)
                if let history = c.history { prompt.recentLines = history }
                let fallback = rules.fallbackLine(of: speaker, in: state)?.text
                    .replacingOccurrences(of: "{名前}", with: rules.scenario.protagonist.name)
                // ゲームでは止める入力も、モデルの振る舞いを見るために生成はする（印を付ける）
                if ContentFilter.blocksInput(c.text) { r.blocked = true }
                let reply = await talker.reply(to: c.text, prompt: prompt, fallback: fallback)
                r.reply = reply.text
                r.replyMs = reply.milliseconds
                r.replySource = reply.source.rawValue
                r.replyError = reply.errors.isEmpty ? nil : reply.errors.joined(separator: ",")
                r.replyProblems = reply.problems.isEmpty ? nil : reply.problems
                let notes = ReplyChecker.notes(reply.text)
                r.replyNotes = notes.isEmpty ? nil : notes
                let i = r.interpretError.map { "解釈ERR(\($0))" } ?? (r.interpreted ?? "-")
                let mark = reply.source == .generated ? "" : "［\(reply.source.rawValue)\(r.replyError.map { " " + $0 } ?? "")\(r.replyProblems.map { " " + $0.joined(separator: "、") } ?? "")］"
                let t = "\(speaker)「\(reply.text)」\(mark)\(notes.isEmpty ? "" : " 注意:" + notes.joined(separator: "、"))"
                print("\(c.id)#\(run) [\(c.category)] 「\(c.text)」→ \(i)\(r.blocked == true ? "［入力で止める］" : "") / \(t)")
                records.append(r)
            }
        }
        write(records, to: out)
        print("\n== ガードレール")
        let n = records.count
        let ie = records.filter { $0.interpretError != nil }
        let re = records.filter { $0.replyError != nil }
        print("解釈のエラー: \(ie.count)/\(n)（\(percent(ie.count, n))） \(kinds(ie.compactMap(\.interpretError)))")
        print("台詞の生成のエラー（生成し直す前を含む）: \(re.count)/\(n)（\(percent(re.count, n))） \(kinds(re.compactMap(\.replyError)))")
        print("入力の検査で止める: \(records.filter { $0.blocked == true }.count)/\(n)")
        print("台詞の出どころ: \(kinds(records.compactMap(\.replySource)))")
        print("検査の問題（生成し直しの理由）: \(kinds(records.flatMap { $0.replyProblems ?? [] }))")
        print("注意（性別を示す語など）: \(kinds(records.flatMap { $0.replyNotes ?? [] }))")
        for (cat, rs) in Dictionary(grouping: records, by: \.category).sorted(by: { $0.key < $1.key }) {
            print("  \(cat): 解釈ERR \(rs.filter { $0.interpretError != nil }.count)、台詞ERR \(rs.filter { $0.replyError != nil }.count)、定型文に戻した \(rs.filter { $0.replySource == "fallback" }.count) / \(rs.count)")
        }
        let ms = records.compactMap(\.replyMs).sorted()
        if !ms.isEmpty { print("台詞の時間: 中央値 \(ms[ms.count / 2])ms / 最大 \(ms.last!)ms") }
        print("結果: \(out.path)")
    }

    static func percent(_ a: Int, _ b: Int) -> String {
        b == 0 ? "-" : String(format: "%.0f%%", Double(a) * 100 / Double(b))
    }

    static func kinds(_ list: [String]) -> String {
        Dictionary(grouping: list, by: { $0 }).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
    }

    static func write<Record: Encodable>(_ records: [Record], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let lines = records.compactMap { try? encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
