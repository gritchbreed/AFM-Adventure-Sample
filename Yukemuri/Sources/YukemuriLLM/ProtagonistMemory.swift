import Foundation
import FoundationModels
import YukemuriEngine

/// 主人公の記憶（プレイヤーが話した、主人公自身のこと）の項目と検査
///
/// プレイヤーが自分の好みを話したら、LLM で短い言葉に取り出し、検査を通ったものだけを残す。
/// 残した記憶は、その発言を聞いた人物の雑談のプロンプトにだけ入る（聞いていない人は知らない）。
/// 判定や進行には使わない。
public enum MemorySlots {
    /// 雑談の発言からまとめて取り出す項目（店の話題で出やすいもの）
    public static let chat = ["好きな食べ物", "好きな飲み物", "好きな音楽", "好きな映画", "好きな店の雰囲気", "出身", "趣味", "苦手なもの"]

    /// 自分のことを話しているかの目安（この語がない発言では、モデルに問い合わせない）
    static let selfDisclosureWords = ["私は", "僕は", "俺は", "自分は", "わたし", "出身", "生まれ", "育ち", "地元", "実家",
                                      "趣味", "好き", "好物", "苦手", "嫌い", "よく飲", "よく行", "よく聴", "よく聞", "よく見"]
    /// 「覚えてる？」のように、覚えているかを聞く語
    static let recallTriggers = ["覚えて", "知ってる", "知ってた", "言ったっけ", "話したっけ", "何だっけ", "なんだっけ"]
    /// 項目ごとの話題の語（発言にこの語があれば、その項目を雑談のプロンプトに入れる）
    static let keywords: [String: [String]] = [
        "好きな食べ物": ["好物", "食べ", "ご飯", "ごはん", "料理", "つまみ", "メニュー", "名物", "夕飯"],
        "好きな飲み物": ["飲み", "お酒", "酒", "コーヒー", "お茶", "カクテル", "ビール", "焼酎", "乾杯", "メニュー"],
        "好きな音楽": ["音楽", "曲", "歌", "カラオケ", "レコード", "BGM", "流す", "かける"],
        "好きな映画": ["映画", "洋画", "シネマ"],
        "好きな店の雰囲気": ["店", "雰囲気", "静か", "にぎやか", "一人で", "常連", "落ち着"],
        "出身": ["出身", "地元", "故郷", "実家", "生まれ", "育ち"],
        "趣味": ["趣味", "休み", "休日", "暇", "週末"],
        "苦手なもの": ["苦手", "嫌い", "怖い"],
    ]

    /// 発言のうち、問いを除いた文（自分のことを述べた文だけ）。自分のことを話していなければ nil
    /// 「覚えてる？」と聞く発言は、続く文も問いの続きなので取り出さない（「覚えてる？俺の好きな店の感じ」から「感じ」を取り出した）
    static func statements(in text: String) -> String? {
        guard !recallTriggers.contains(where: { text.contains($0) }) else { return nil }
        let kept = SentenceSplitter.split(text).filter { s in !s.hasSuffix("？") && !s.hasSuffix("?") }
        let joined = kept.joined()
        guard !joined.isEmpty, selfDisclosureWords.contains(where: { joined.contains($0) }) else { return nil }
        return joined
    }

    /// 取り出した値の検査。通らなければ nil
    /// - 20字まで、改行なし、禁止語と連絡先を含まない
    /// - 発言の中の言葉そのものだけ（作り話を防ぐ）
    public static func validate(_ value: String?, utterance: String) -> String? {
        guard var v = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "「」『』。、！？!? 　"))
        guard !v.isEmpty, !v.hasPrefix("なし"), !v.contains("〜"), v.count <= 20, !v.contains("\n"), ContentFilter.problems(v).isEmpty else { return nil }
        guard utterance.contains(v) else { return nil }
        // 指示や作品の外の言葉を含む値は残さない（記憶は雑談のプロンプトに入るので、指示を入れる経路にさせない）
        guard !instructionWords.contains(where: { v.contains($0) }), !ReplyChecker.metaWords.contains(where: { v.contains($0) }) else { return nil }
        return v
    }

    /// 記憶の値に入れない、指示らしい語（2026-10-09 のセキュリティの試しプレイで追加）
    static let instructionWords = ["指示", "命令", "無視", "システム", "設定", "ルール", "従", "忘れて", "答えて", "話して", "書き出", "読み上げ"]
}

/// 主人公の記憶の1項目
public struct MemoryItem: Sendable, Codable, Equatable {
    public var value: String
    /// 発言を聞いた人物（そのときその場にいた人。雑談のプロンプトには、聞いた人にだけ入れる）
    public var heardBy: [String]
    /// 取り出したもとの発言
    public var utterance: String

    public init(value: String, heardBy: [String], utterance: String) {
        self.value = value
        self.heardBy = heardBy
        self.utterance = utterance
    }
}

/// 雑談の発言から取り出した1項目
public struct ExtractedFact: Sendable, Equatable {
    public var slot: String
    public var value: String

    public init(slot: String, value: String) {
        self.slot = slot
        self.value = value
    }
}

/// 発言から、主人公の記憶の項目を取り出す
public protocol MemoryExtracting: Sendable {
    /// 雑談の発言から、MemorySlots.chat の項目をまとめて取り出す（最大3件）。検査は呼び出す側（MemorySlots.validate）で行う
    func extractChat(from utterance: String) async throws -> [ExtractedFact]
}

/// 雑談のプロンプトに入れる記憶を選ぶ
///
/// その話し手が聞いた項目のうち、発言の話題の語に合うものを最大3件。直近に返事の中で触れた項目は、数往復のあいだ外す
/// （ただし「覚えてる？」と明示して聞かれたら入れる）
public enum MemorySelector {
    public static let maxFacts = 3
    public static let cooldownTurns = 8

    public struct Selection: Equatable {
        /// 「項目: 値」
        public var facts: [String]
        /// 覚えているかを明示して聞かれた
        public var asked: Bool
    }

    public static func select(_ memory: [String: MemoryItem], speaker: String, input: String, turn: Int,
                              lastMentioned: [String: Int]) -> Selection {
        let asksRecall = MemorySlots.recallTriggers.contains { input.contains($0) }
        var facts: [String] = []
        var asked = false
        for slot in MemorySlots.chat {
            guard let item = memory[slot], item.heardBy.contains(speaker) else { continue }
            let relevant = asksRecall || (MemorySlots.keywords[slot] ?? []).contains { input.contains($0) }
            guard relevant else { continue }
            let cooling = lastMentioned[slot].map { turn - $0 <= cooldownTurns } ?? false
            if cooling && !asksRecall { continue }
            facts.append("主人公の\(slot): \(item.value)")
            if asksRecall { asked = true }
            if facts.count >= maxFacts { break }
        }
        return Selection(facts: facts, asked: asked)
    }
}

/// Foundation Models で取り出す（人物の設定なしの別のセッション。温度 0）
public struct FoundationModelsMemoryExtractor: MemoryExtracting {
    private let model: SystemLanguageModel
    public var timeoutSeconds: Double
    /// 呼び出しごとに使った文脈の大きさを知らせる先（画面の表示）
    public var usageObserver: (@Sendable (ContextUsage) -> Void)?

    public init(model: SystemLanguageModel = .default, timeoutSeconds: Double = 15) {
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    static let chatInstructions = """
    あなたは発言の分析係です。ゲームの主人公（話者）が自分自身について述べた事実だけを、決められた項目に分類して取り出します。

    ## 項目
    \(MemorySlots.chat.map { "- \($0)" }.joined(separator: "\n"))

    ## 取り出すもの
    - 話者自身についての、本気の事実の表明だけ
    - 値は、発言の中にある語をそのまま使う短い名詞。発言にない語は作らない

    ## 取り出さないもの（何も取り出さない）
    - 質問、他人の話（母は〜が好き など）、仮定や願望（もし〜なら、いつか〜したい）、冗談
    - 話題に出ただけの地名や物、相手の話、項目に当てはまらない話

    ## 例
    - 「好きな食べ物はオムライスなんだよね」→ 好きな食べ物=オムライス
    - 「静かな店のほうが好きだな」→ 好きな店の雰囲気=静かな店
    - 「生まれは福岡です」→ 出身=福岡
    - 「オムライスって好き？」→ なし
    """

    public func extractChat(from utterance: String) async throws -> [ExtractedFact] {
        let fact = DynamicGenerationSchema(name: "Fact", properties: [
            .init(name: "slot", description: "項目", schema: DynamicGenerationSchema(name: "Slot", anyOf: MemorySlots.chat)),
            .init(name: "value", description: "発言の中の語そのまま", schema: DynamicGenerationSchema(type: String.self)),
        ])
        let root = DynamicGenerationSchema(name: "Facts", properties: [
            .init(name: "facts", description: "話者自身の事実（なければ空）", schema: DynamicGenerationSchema(arrayOf: fact, maximumElements: 3)),
        ])
        let schema = try GenerationSchema(root: root, dependencies: [])
        let model = self.model
        let prompt = "発言:「\(PromptQuote.player(utterance))」"
        let content: GeneratedContent = try await withTimeout(seconds: timeoutSeconds, timeoutError: LLMError.timeout(timeoutSeconds)) {
            let session = LanguageModelSession(model: model, instructions: Self.chatInstructions)
            do {
                let content = try await session.respond(to: prompt, schema: schema, options: GenerationOptions(temperature: 0)).content
                ContextUsage.report(.memory, input: Self.chatInstructions + "\n" + prompt, output: content.jsonString,
                                    contextSize: ContextBudget.system(model).contextSize, model: model, to: usageObserver)
                return content
            } catch {
                throw LLMError.from(error)
            }
        }
        var items: [GeneratedContent] = []
        if case .structure(let properties, _) = content.kind, let value = properties["facts"], case .array(let list) = value.kind {
            items = list
        }
        return items.compactMap { item in
            guard let slot = try? item.value(String.self, forProperty: "slot"),
                  let value = try? item.value(String.self, forProperty: "value") else { return nil }
            return ExtractedFact(slot: slot, value: value)
        }
    }
}
