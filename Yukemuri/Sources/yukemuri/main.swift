import Foundation
import YukemuriEngine
import YukemuriLLM

/// 台本の検査と、入力の解釈・自由会話の評価
///
/// 使い方（リポジトリの直下で）:
///   yukemuri validate [scenario.json]                       台本の参照と到達可能性の検査（LLM を使わない）
///   yukemuri trace [--scenario path] <入力>...              入力の並びで規則だけを動かす（LLM を使わない）
///     入力は台本での書き方（意図:赤いドア、移動:控え室、離脱、なし）
///   yukemuri play [--scenario path] <発言>...               最初から、発言を順に送って遊ぶ（実機のモデルを使う）
///     「行き先:控え室」は行き先の一覧から選ぶ操作。それ以外は言葉の入力
///   yukemuri replay <playlogs/*.jsonl> [--scenario path] [--show-prompt]   試作プレイのログの操作を流し直す
///   yukemuri eval-interpret <評価データ.json> [--scenario path] [--repeat N]   入力の解釈の精度
///   yukemuri eval-guardrail <評価データ.json> [--scenario path] [--repeat N]   解釈と台詞の生成が拒否されないか、はみ出さないか
///   yukemuri eval-memory <評価データ.json> [--repeat N] [--talk [--scenario path]]   主人公の記憶の取り出し（--talk は雑談への反映）
///   どのコマンドにも --context 4096 を付けると、文脈の大きさを固定する（文脈の小さい端末と同じ条件で確かめる）
let defaultPath = "UI/UI/Resources/scenario.json"

// 評価のログをファイルに書くときも、1行ずつ出す（止まった箇所がわかるように）
setvbuf(stdout, nil, _IOLBF, 0)

func loadScenario(_ path: String) -> Scenario {
    do {
        return try Scenario.load(from: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("台本を読み込めません（\(path)）：\(error)\n".utf8))
        exit(2)
    }
}

func describe(_ event: RuleEvent) -> String? {
    switch event {
    case .line(let l):
        let who = l.speaker.map { "\($0)「" } ?? ""
        let close = l.speaker == nil ? "" : "」"
        return "  \(l.id) \(who)\(l.text.replacingOccurrences(of: "\n", with: " "))\(close)"
    case .sceneEntered(let id): return "― 場面 \(id)"
    case .presentation(let e): return "  （演出：\(e)）"
    case .freeTalk(let who): return "  （自由会話：\(who ?? "答える人がいない")）"
    case .destinationsRequested: return "  （行き先の一覧）"
    case .moveRejected(let p): return "  （\(p) には今は行けない）"
    }
}

/// セッションの出来事を出す（定型文、自由会話の返事、知らせ）
func show(_ events: [SessionEvent]) {
    for event in events {
        switch event {
        case .line(let line, let t):
            let who = line.speaker.map { "\($0)「" } ?? ""
            print("  \(line.id) \(who)\(t.replacingOccurrences(of: "\n", with: " "))\(line.speaker == nil ? "" : "」")")
        case .reply(let speaker, let t, let source):
            print("  ＊\(speaker)「\(t)」（\(source.rawValue)）")
        case .notice(let t):
            print("  \(t)")
        case .rule(let rule):
            if let d = describe(rule), !d.hasPrefix("  （自由会話"), !d.hasPrefix("  （演出") { print(d) }
        }
    }
}

/// `--scenario path` を取り出す
func takeScenario(_ args: inout [String]) -> String {
    guard let i = args.firstIndex(of: "--scenario"), i + 1 < args.count else { return defaultPath }
    let path = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return path
}

/// `--repeat N` を取り出す
func takeRepeat(_ args: inout [String]) -> Int {
    guard let i = args.firstIndex(of: "--repeat"), i + 1 < args.count else { return 1 }
    let n = max(1, Int(args[i + 1]) ?? 1)
    args.removeSubrange(i...(i + 1))
    return n
}

var args = Array(CommandLine.arguments.dropFirst())
// `--context 4096` で、文脈の大きさを固定する（どのコマンドでも）
if let i = args.firstIndex(of: "--context"), i + 1 < args.count, let size = Int(args[i + 1]) {
    ContextBudget.override = size
    args.removeSubrange(i...(i + 1))
    FileHandle.standardError.write("文脈の大きさを \(size) に固定\n".data(using: .utf8)!)
}
guard let command = args.first else {
    print("使い方: yukemuri validate | trace | play | replay | eval-interpret | eval-guardrail | eval-memory（くわしくは Sources/yukemuri/main.swift の頭）")
    exit(2)
}
args.removeFirst()

switch command {
case "validate":
    let scenario = loadScenario(args.first ?? defaultPath)
    let report = ScenarioValidator().validate(scenario)
    print("== 状態 \(report.stateCount)、エラー \(report.errors.count)、警告 \(report.warnings.count)")
    for e in report.errors { print("ERR  \(e)") }
    for w in report.warnings { print("WARN \(w)") }
    exit(report.isValid ? 0 : 1)

case "trace":
    let rules = GameRules(scenario: loadScenario(takeScenario(&args)))
    func flush(_ step: Step) { step.events.compactMap(describe).forEach { print($0) } }
    var step = rules.start()
    flush(step)
    var state = step.state
    for raw in args {
        guard let input = PlayerInput(notation: raw) else {
            print("読めない入力: \(raw)")
            exit(2)
        }
        print("> \(input)")
        step = rules.handle(input, in: state)
        flush(step)
        state = step.state
    }
    print("\n今の場面：\(state.scene ?? "-")")
    print("入力の候補：\(rules.inputCandidates(in: state).map(\.description).joined(separator: "、"))")
    print("答え済みの意図：\(rules.answeredIntents(in: state).map(\.description).joined(separator: "、"))")

case "play":
    let scenarioPath = takeScenario(&args)
    await Player.run(scenarioPath: scenarioPath, inputs: args)

case "replay":
    guard let logPath = args.first else {
        print("ログのファイル（playlogs/*.jsonl）を指定してください")
        exit(2)
    }
    var rest = Array(args.dropFirst())
    let showPrompt = rest.contains("--show-prompt")
    rest.removeAll { $0 == "--show-prompt" }
    await Replayer.run(logPath: logPath, scenarioPath: takeScenario(&rest), showPrompt: showPrompt)

case "eval-memory":
    guard let evalPath = args.first else {
        print("評価データを指定してください")
        exit(2)
    }
    let repeats = takeRepeat(&args)
    if args.contains("--talk") {
        await MemoryEvaluator.talk(evalPath: evalPath, scenarioPath: takeScenario(&args), repeats: repeats)
    } else {
        await MemoryEvaluator.run(evalPath: evalPath, repeats: repeats)
    }

case "eval-interpret", "eval-guardrail":
    guard let evalPath = args.first else {
        print("評価データを指定してください")
        exit(2)
    }
    var rest = Array(args.dropFirst())
    let scenarioPath = takeScenario(&rest)
    let repeats = takeRepeat(&rest)
    if let unknown = rest.first {
        print("未知のオプション \(unknown)")
        exit(2)
    }
    if command == "eval-interpret" {
        await Evaluator.interpret(scenarioPath: scenarioPath, evalPath: evalPath, repeats: repeats)
    } else {
        await Evaluator.guardrail(scenarioPath: scenarioPath, evalPath: evalPath, repeats: repeats)
    }

default:
    print("未知のコマンド \(command)")
    exit(2)
}
