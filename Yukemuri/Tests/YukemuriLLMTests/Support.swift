import Foundation
import Testing
import YukemuriEngine
@testable import YukemuriLLM

/// 決まった入力を返す解釈（テスト用）
struct TableInterpreter: InputInterpreting {
    var table: [String: PlayerInput]
    func interpret(_ text: String, choices: InterpretChoices) async throws -> Interpretation {
        Interpretation(input: table[text] ?? .none, milliseconds: 0)
    }
}

/// 決まった返答を順に返す台詞の生成（テスト用。エラーも返せる）
final class ScriptedTalker: Talking, @unchecked Sendable {
    enum Answer { case text(String), error(LLMError) }
    private let lock = NSLock()
    private var answers: [Answer]
    private(set) var prompts: [TalkPrompt] = []
    private(set) var inputs: [String] = []

    init(_ answers: [Answer]) { self.answers = answers }

    func reply(to text: String, prompt: TalkPrompt) async throws -> TalkReply {
        let answer: Answer = lock.withLock {
            prompts.append(prompt)
            inputs.append(text)
            return answers.isEmpty ? .text("ええ。") : answers.removeFirst()
        }
        switch answer {
        case .text(let t): return TalkReply(text: t, truncated: false, milliseconds: 1)
        case .error(let e): throw e
        }
    }
}

/// 決まった記憶を返す取り出し（テスト用）
struct StubExtractor: MemoryExtracting {
    var facts: [ExtractedFact]
    func extractChat(from utterance: String) async throws -> [ExtractedFact] { facts }
}

/// テスト用の小さな台本（店内にママと相棒の葵、控え室に葵だけ）
enum Demo {
    static let json = #"""
    {
     "spec_version": 1,
     "protagonist": {"name": "吉永", "rules": ["主人公の見た目には触れない"]},
     "partner": "神楽坂葵",
     "place_aliases": {"店内": ["店に戻", "カウンター", "ママのところ"], "控え室": ["控室", "奥"]},
     "intents": [
      {"id": "ドア", "description": "ドアの話", "examples": ["あのドアは、あのままがいいと思う"], "words": ["ドア"]},
      {"id": "合図", "description": "合図", "examples": ["合図をする"]}
     ],
     "persons": [
      {"id": "赤尾妙子", "speaker_name": "ママ", "calls_protagonist": "{名前}さん",
       "profile": ["スナックのママ"], "personality": ["昭和歌謡が好き"],
       "speech": {"first_person": "あたし", "items": [{"name": "呼び方", "value": "主人公は「{名前}さん」"}],
                  "examples": [{"input": "元気？", "reply": "元気よ。"}]},
       "knowledge": [{"info": "客が減っている"}, {"info": "ドアは自分で選んだ", "condition": "意図:ドア"}],
       "fallbacks": [{"id": "ママ-拒1", "text": "さあ、どうかしら。"}, {"id": "ママ-拒2", "text": "{名前}さん、それより一杯どう？"},
                     {"id": "ママ-拒3", "text": "その話は、また今度ね。"}]},
      {"id": "神楽坂葵", "speaker_name": "葵", "calls_protagonist": "あなた",
       "profile": ["店の従業員"], "speech": {"first_person": "私", "items": [], "examples": []},
       "fallbacks": [{"id": "葵-拒1", "text": "……知らない。"}]}
     ],
     "scenes": [
      {"id": "S1", "place": "店内", "person": "赤尾妙子",
       "free_talk": {"赤尾妙子": ["グラスを拭きながら話す"], "神楽坂葵": ["からかい半分で口をはさむ"]},
       "lines": [
        {"id": "M01", "speaker": "赤尾妙子", "condition": "初回", "text": "おかえり、{名前}さん。"},
        {"id": "D1", "speaker": "赤尾妙子", "condition": "意図:ドア", "text": "あのドアがいいのよ。"},
        {"id": "G1", "speaker": "神楽坂葵", "condition": "意図:合図", "repeatable": true, "text": "了解。"}
       ]},
      {"id": "S2", "place": "控え室", "lines": [{"id": "K01", "condition": "初回", "text": "控え室に入った。"}]}
     ]
    }
    """#

    static func rules(_ edit: (String) -> String = { $0 }) throws -> GameRules {
        GameRules(scenario: try Scenario.load(from: Data(edit(json).utf8)))
    }

    static func session(_ talker: ScriptedTalker, table: [String: PlayerInput] = [:], memory: (any MemoryExtracting)? = nil,
                        edit: (String) -> String = { $0 }) async throws -> GameSession {
        let s = GameSession(rules: try rules(edit), interpreter: TableInterpreter(table: table), talker: talker, memoryExtractor: memory)
        _ = await s.start()
        return s
    }
}
