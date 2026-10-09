import Foundation
import YukemuriEngine
import YukemuriLLM

/// 主人公の記憶の評価（実機のモデルを使う）
///
/// - 取り出し：評価データ [{"slot": 項目, "text": 主人公の発言, "expect": "some" | "none"}]。expect は、その項目の値を残すべきか
/// - 雑談への反映（--talk）：記憶を入れた状態で相棒に話しかけ、返事に値が出るか（expect: "mention" | "silent"。value に記憶の値）
enum MemoryEvaluator {
    struct Case: Decodable {
        var slot: String
        var text: String
        var expect: String
        /// --talk のとき、記憶に入れる値
        var value: String?
    }

    static func load(_ path: String) -> [Case] {
        guard let data = FileManager.default.contents(atPath: path),
              let cases = try? JSONDecoder().decode([Case].self, from: data) else {
            print("評価データを読み込めません（\(path)）")
            exit(2)
        }
        return cases
    }

    static func run(evalPath: String, repeats: Int) async {
        Evaluator.checkAvailability()
        let cases = load(evalPath)
        let extractor = FoundationModelsMemoryExtractor()
        var ok = 0, total = 0
        for c in cases {
            for _ in 0..<repeats {
                total += 1
                var raw: String?
                var note = ""
                do {
                    let facts = try await extractor.extractChat(from: c.text)
                    raw = facts.first { $0.slot == c.slot }?.value
                    note = facts.isEmpty ? "" : "（取り出し全体：\(facts.map { "\($0.slot)=\($0.value)" }.joined(separator: "、"))）"
                } catch {
                    note = "（エラー \(LLMError.from(error).kind)）"
                }
                let value = MemorySlots.validate(raw, utterance: c.text)
                let pass = (value != nil) == (c.expect == "some")
                if pass { ok += 1 }
                print("\(pass ? "○" : "×") [\(c.slot)]「\(c.text)」→ 取り出し「\(raw ?? "-")」\(note) → \(value ?? "（残さない）")")
            }
        }
        print("== 期待どおり：\(ok)/\(total)")
    }

    /// 記憶を入れた状態で、店内の相棒に話しかける
    static func talk(evalPath: String, scenarioPath: String, repeats: Int) async {
        Evaluator.checkAvailability()
        let cases = load(evalPath)
        let rules = GameRules(scenario: loadScenario(scenarioPath))
        var ok = 0, total = 0
        for c in cases {
            for _ in 0..<repeats {
                total += 1
                let session = GameSession(rules: rules, interpreter: RefinedInterpreter(inner: FoundationModelsInterpreter()), talker: FoundationModelsTalker())
                _ = await session.start()
                // 始まりの話の続き（話題の振り）を先に出しておく（最初の入力で定型文が続き、返事が短くなるのを避ける）
                _ = await session.perform(.none)
                await session.setMemory(c.slot, c.value)
                let turn = await session.send(c.text, to: rules.scenario.partner)
                let reply = turn.reply?.text ?? turn.events.compactMap { if case .line(_, let t) = $0 { t } else { nil } }.joined()
                let mentioned = c.value.map { reply.contains($0) } ?? false
                let pass = mentioned == (c.expect == "mention")
                if pass { ok += 1 }
                print("\(pass ? "○" : "×") [\(c.slot)=\(c.value ?? "-")]「\(c.text)」→「\(reply)」")
            }
        }
        print("== 期待どおり：\(ok)/\(total)")
    }
}
