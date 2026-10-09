import Foundation

/// 台本（UI/UI/Resources/scenario.json。形は docs/scenario-data-spec.md）
public struct Scenario: Sendable, Decodable {
    public static let supportedSpecVersion = 1

    public var specVersion: Int
    /// 主人公（プレイヤー）
    public var protagonist: Protagonist
    /// 相棒の人物 ID（相棒のいる場面で、いつも一緒にいる）
    public var partner: String
    /// 入力の解釈の候補になる意図
    public var intents: [Intent]
    public var persons: [Person]
    /// 場所の別の呼び方（店内＝店 など）
    public var placeAliases: [String: [String]]
    /// 場面（最初の場面から始まる）
    public var scenes: [Scene]

    /// JSON を読み込む。spec_version が合わなければエラー
    public static func load(from data: Data) throws -> Scenario {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let scenario = try decoder.decode(Scenario.self, from: data)
        guard scenario.specVersion == supportedSpecVersion else {
            throw ScenarioError.unsupportedSpecVersion(scenario.specVersion)
        }
        guard !scenario.scenes.isEmpty else { throw ScenarioError.noScenes }
        return scenario
    }

    public static func load(from url: URL) throws -> Scenario {
        try load(from: Data(contentsOf: url))
    }

    public func person(_ id: String) -> Person? { persons.first { $0.id == id } }
    public func scene(_ id: String) -> Scene? { scenes.first { $0.id == id } }
    public func intent(_ id: String) -> Intent? { intents.first { $0.id == id } }
}

public enum ScenarioError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedSpecVersion(Int)
    case noScenes

    public var description: String {
        switch self {
        case .unsupportedSpecVersion(let v): "対応していないデータの版です: \(v)（対応は \(Scenario.supportedSpecVersion)）"
        case .noScenes: "場面がありません"
        }
    }
}

/// 主人公（プレイヤー）。名前は入力せず、台本で決める
public struct Protagonist: Sendable, Hashable, Decodable {
    public var name: String
    /// 自由会話の「守ること」に入れる、主人公の扱い（どの人物にも入る）
    public var rules: [String]
}

public struct Intent: Sendable, Hashable, Decodable {
    public var id: String
    public var description: String
    public var examples: [String]
    /// 含む語（入力にどれかが含まれていなければ、この意図にしない）
    public var words: [String]?
}

public struct Person: Sendable, Hashable, Decodable {
    public var id: String
    /// 名札と自由会話のプロンプトに出す名前
    public var speakerName: String
    /// 表の顔（プロンプトに入る文）
    public var profile: [String]
    /// 人となり（プロンプトに入る雑談の素材）
    public var personality: [String]
    /// 知っていること・考え（条件を満たす行だけがプロンプトに入る）
    public var knowledge: [Knowledge]
    public var speech: Speech?
    /// 台詞の生成が拒否されたときの台詞（上から、条件を満たすもの）
    public var fallbacks: [FallbackLine]
    /// 台詞の色の名前（紫、桃 など。画面がどの色にするかを決める）
    public var color: String?
    /// 人物の絵の ID（CH09 など。絵のない人物は nil）
    public var sprite: String?
    /// 自由会話で主人公を呼ぶ言い方（`{名前}さん`、`あなた` など）
    public var callsProtagonist: String?

    private enum CodingKeys: String, CodingKey {
        case id, speakerName, profile, personality, knowledge, speech, fallbacks, color, sprite, callsProtagonist
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        speakerName = try c.decodeIfPresent(String.self, forKey: .speakerName) ?? id
        profile = try c.decodeIfPresent([String].self, forKey: .profile) ?? []
        personality = try c.decodeIfPresent([String].self, forKey: .personality) ?? []
        knowledge = try c.decodeIfPresent([Knowledge].self, forKey: .knowledge) ?? []
        speech = try c.decodeIfPresent(Speech.self, forKey: .speech)
        fallbacks = try c.decodeIfPresent([FallbackLine].self, forKey: .fallbacks) ?? []
        color = try c.decodeIfPresent(String.self, forKey: .color)
        sprite = try c.decodeIfPresent(String.self, forKey: .sprite)
        callsProtagonist = try c.decodeIfPresent(String.self, forKey: .callsProtagonist)
    }
}

/// 話し方
public struct Speech: Sendable, Hashable, Decodable {
    public struct Item: Sendable, Hashable, Decodable {
        public var name: String
        public var value: String
    }

    public struct Example: Sendable, Hashable, Decodable {
        public var input: String
        public var reply: String
    }

    /// 一人称（生成した台詞の検査に使う）
    public var firstPerson: String
    /// 項目（呼び方、丁寧さ、語尾・口癖 など）
    public var items: [Item]
    public var examples: [Example]
}

/// 台詞の生成が拒否されたときの台詞
public struct FallbackLine: Sendable, Hashable, Decodable {
    public var id: String
    public var condition: Expr?
    public var text: String
}

/// 人物が知っていること・考え（条件がなければいつも、`意図:` を含む条件なら、その意図の入力のときだけプロンプトに入る）
public struct Knowledge: Sendable, Hashable, Decodable {
    public var info: String
    public var condition: Expr?
}

public struct Scene: Sendable, Decodable {
    public var id: String
    public var title: String
    public var place: String
    public var background: String?
    /// その場にいる人物（相棒は含めない）
    public var person: String?
    /// 相棒がいるか
    public var partner: Bool
    /// 行ける条件（なければいつでも行ける）
    public var canEnter: Expr?
    /// 定型文（表の順。選ぶ順番の基準）
    public var lines: [Line]
    /// 自由会話の指示（人物 ID → その人物のプロンプトに入る文）
    public var freeTalk: [String: [String]]
    /// 場面に入ったときの人物の表情（人物 ID → 表情。書いていない人物は「通常」）
    public var expressions: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case id, title, place, background, person, partner, canEnter, lines, freeTalk, expressions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        place = try c.decode(String.self, forKey: .place)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? place
        background = try c.decodeIfPresent(String.self, forKey: .background)
        person = try c.decodeIfPresent(String.self, forKey: .person)
        partner = try c.decodeIfPresent(Bool.self, forKey: .partner) ?? true
        canEnter = try c.decodeIfPresent(Expr.self, forKey: .canEnter)
        lines = try c.decodeIfPresent([Line].self, forKey: .lines) ?? []
        freeTalk = try c.decodeIfPresent([String: [String]].self, forKey: .freeTalk) ?? [:]
        expressions = try c.decodeIfPresent([String: String].self, forKey: .expressions)
    }
}

/// 定型文
public struct Line: Sendable, Hashable, Decodable {
    public enum Kind: String, Sendable, Hashable, Decodable {
        case narration, dialogue
    }

    public var id: String
    public var kind: Kind
    /// 台詞の話者（人物 ID。地の文は nil）
    public var speaker: String?
    public var condition: Expr
    public var effects: [Effect]
    /// 何度でも出るか
    public var repeatable: Bool
    public var text: String
    /// この行そのものがプレイヤーへの返事なので、前に短い返事をはさまない
    public var noAck: Bool
    /// 言い換え（2回目以降に出すときの文面）
    public var variants: [String]

    private enum CodingKeys: String, CodingKey {
        case id, speaker, condition, effects, repeatable, text, noAck, variants
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
        kind = speaker == nil ? .narration : .dialogue
        condition = try c.decode(Expr.self, forKey: .condition)
        effects = try c.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        repeatable = try c.decodeIfPresent(Bool.self, forKey: .repeatable) ?? false
        text = try c.decode(String.self, forKey: .text)
        noAck = try c.decodeIfPresent(Bool.self, forKey: .noAck) ?? false
        variants = try c.decodeIfPresent([String].self, forKey: .variants) ?? []
    }

    /// n 回目（1から）に出すときの文面。1回目は元の文面、その後は言い換えを順に使い、一巡したら元に戻る
    public func text(forTime n: Int) -> String {
        let all = [text] + variants
        return all[(max(n, 1) - 1) % all.count]
    }
}
