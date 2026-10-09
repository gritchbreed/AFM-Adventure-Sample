import Foundation
import YukemuriEngine
import YukemuriLLM

/// 最初から、発言を順に送って遊ぶ（実機のモデルを使う。試しプレイ用）
///
///   yukemuri play [--scenario path] <発言>...
///
/// 「行き先:場所」は行き先の一覧から選ぶ操作。それ以外は言葉の入力
enum Player {
    static func run(scenarioPath: String, inputs: [String]) async {
        Evaluator.checkAvailability()
        let rules = GameRules(scenario: loadScenario(scenarioPath))
        let session = GameSession(rules: rules, interpreter: RefinedInterpreter(inner: FoundationModelsInterpreter()),
                                  talker: FoundationModelsTalker(), memoryExtractor: FoundationModelsMemoryExtractor())
        await session.setMemoryObserver { print("    〔\($0)〕") }
        show(await session.start())
        for text in inputs {
            if text.hasPrefix("行き先:") {
                let place = String(text.dropFirst("行き先:".count))
                print("> （\(place)へ）")
                show(await session.perform(.move(place)).events)
                continue
            }
            let turn = await session.send(text)
            print("> \(text)　→ \(turn.input)（\(turn.interpretMs)ms）" + (turn.interpretError.map { "　解釈のエラー：\($0)" } ?? ""))
            show(turn.events)
            if let r = turn.reply { print("    〔返事 \(r.milliseconds)ms〕") }
            if let r = turn.reply, !(r.errors + r.problems).isEmpty {
                print("    （\(r.source.rawValue)：\((r.errors + r.problems).joined(separator: "、"))　弾いた返事：\(r.rejected.joined(separator: " ／ "))）")
            }
        }
        // 記憶の取り出しは返事の後に裏で終わるので、少し待ってから出す
        if !inputs.isEmpty { try? await Task.sleep(for: .seconds(4)) }
        let state = await session.state
        let present = rules.presentPersons(in: state).joined(separator: "・")
        print("-- 場面 \(state.scene ?? "-")（その場：\(present.isEmpty ? "なし" : present)）")
        let memory = await session.memory
        if !memory.isEmpty { print("-- 記憶：" + memory.map { "\($0.key)=\($0.value.value)" }.sorted().joined(separator: "、")) }
    }
}
