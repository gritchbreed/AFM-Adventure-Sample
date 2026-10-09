import Foundation
import YukemuriEngine
import YukemuriLLM

/// 試作プレイのログ（アプリの playlogs/*.jsonl）の操作を、同じ順に流し直す（実機のモデルを使う）
///
/// 直したプロンプトや台本で、同じ入力にどう答えるかを確かめるために使う。
///
/// 回帰の確かめ：記録の行に、次のキーを書いておくと、流したあとに照らし合わせる（Evaluation/replay-*.jsonl）。
/// 生成した文は照らし合わせない。照らし合わせるのは、入力の解釈と、出た定型文の ID だけ。
/// - `expect`：入力の解釈（台本での書き方。文字列か、どれでもよい候補の配列）
/// - `lines`：出なければならない定型文の ID の配列
/// - `not_lines`：出てはならない定型文の ID の配列
/// - `fixed`：true なら、自由会話だけで答えてはならない（定型文が1つは出る）
/// - `no_reply`：true なら、自由会話の返事（定型文の前の短い返事も）が出てはならない
/// 照らし合わせの結果は最後にまとめて出し、外れがあれば終了コード 1 で終える
enum Replayer {
    /// 照らし合わせ（行の記録の期待と、実際に出たもの）
    struct Check {
        var total = 0
        var failures: [String] = []

        mutating func verify(_ obj: [String: Any], label: String, input: String?, lines: [String], hadReply: Bool) {
            var problems: [String] = []
            if let input {
                let accepted = (obj["expect"] as? [String]) ?? (obj["expect"] as? String).map { [$0] }
                if let accepted, !accepted.contains(input) { problems.append("解釈 \(input)（期待 \(accepted.joined(separator: " / "))）") }
            }
            for id in obj["lines"] as? [String] ?? [] where !lines.contains(id) { problems.append("\(id) が出ない") }
            for id in obj["not_lines"] as? [String] ?? [] where lines.contains(id) { problems.append("\(id) が出た") }
            if obj["fixed"] as? Bool == true, lines.isEmpty, hadReply { problems.append("自由会話だけで答えた") }
            if obj["no_reply"] as? Bool == true, hadReply { problems.append("自由会話の返事が出た") }
            let hasExpectation = ["expect", "lines", "not_lines", "fixed", "no_reply"].contains { obj[$0] != nil }
            guard hasExpectation else { return }
            total += 1
            if !problems.isEmpty {
                let line = "NG \(label)：\(problems.joined(separator: "、"))"
                print("  " + line)
                failures.append(line)
            }
        }
    }

    static func run(logPath: String, scenarioPath: String, showPrompt: Bool) async {
        Evaluator.checkAvailability()
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            print("ログを読めません: \(logPath)")
            exit(2)
        }
        let rules = GameRules(scenario: loadScenario(scenarioPath))
        let session = GameSession(rules: rules, interpreter: RefinedInterpreter(inner: FoundationModelsInterpreter()),
                                  talker: FoundationModelsTalker())
        var check = Check()
        func ids(_ events: [SessionEvent]) -> [String] {
            events.compactMap { if case .line(let line, _) = $0 { line.id } else { nil } }
        }
        func hasReply(_ events: [SessionEvent]) -> Bool {
            events.contains { if case .reply = $0 { true } else { false } }
        }
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let kind = obj["kind"] as? String else { continue }
            let t = obj["text"] as? String ?? ""
            switch kind {
            case "start":
                print("== 最初から")
                let events = await session.start()
                show(events)
                check.verify(obj, label: "最初から", input: nil, lines: ids(events), hadReply: false)
            case "input":
                let turn = await session.send(t)
                print("> \(t)　→ \(turn.input)（\(turn.interpretMs)ms）")
                show(turn.events)
                check.verify(obj, label: t, input: turn.input.description, lines: ids(turn.events), hadReply: hasReply(turn.events))
                if let r = turn.reply, r.source != .generated, !(r.errors + r.problems).isEmpty {
                    print("    （\(r.source.rawValue)：\((r.errors + r.problems).joined(separator: "、"))　弾いた返事：\(r.rejected.joined(separator: " ／ "))）")
                }
                if showPrompt, turn.reply != nil, let p = await session.lastPrompt {
                    print("----- プロンプト\n\(p.instructions)\n-----")
                }
            case "move":
                print("> （\(t)へ）")
                let events = await session.perform(.move(t)).events
                show(events)
                check.verify(obj, label: "（\(t)へ）", input: nil, lines: ids(events), hadReply: false)
            default:
                break
            }
        }
        if check.total > 0 {
            print("\n== 照らし合わせ：\(check.total - check.failures.count)/\(check.total) 件が期待どおり")
            for f in check.failures { print("  \(f)") }
            if !check.failures.isEmpty { exit(1) }
        }
    }
}
