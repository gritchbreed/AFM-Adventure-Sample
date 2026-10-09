import Foundation
import FoundationModels
import YukemuriEngine

/// 入力の解釈の選択肢（その時点で結果の変わる入力だけ。`GameRules.inputCandidates` から作る）
public struct InterpretChoices: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        /// スキーマで使う短い記号（A1 など）
        public var token: String
        public var input: PlayerInput
        /// 選択肢の説明
        public var label: String
        public var examples: [String]
        /// 入力にどれかが含まれていなければ選べない語（意図の「含む語」。空なら制限なし）
        public var requiredWords: [String] = []

        /// 入力の文が、含む語の決まりに合うか
        public func allows(_ text: String) -> Bool {
            requiredWords.isEmpty || requiredWords.contains { text.contains($0) }
        }
    }

    public var options: [Option]
    /// 今いる場所（プロンプトの手がかり）
    public var place: String?
    /// その場にいる人物の表示名
    public var people: [String]
    /// 自由会話で答える人（代名詞「あなた」などが指す相手）
    public var respondent: String?
    /// 人物の呼び名（呼びかけの判定に使う）
    public var callNames: [String: [String]]
    /// その場にいる人物の ID（呼びかけの判定に使う）
    public var present: [String]
    /// 相棒の人物 ID
    public var partner: String?
    /// 場所の名前（移動の行き先の言い方の確かめに使う）
    public var places: [String]
    /// 場所の別の呼び方（店内＝店 など）
    public var placeAliases: [String: [String]] = [:]
    /// 人物がいる場所（「ママに会いに行こう」を、その場所への移動にするのに使う）
    public var personPlaces: [String: String] = [:]
    /// 入力の直前に出た発言（定型文か自由会話の返事。「行ってみよう」がどこを指すかに使う）
    public var lastUtterance: String?

    public init(options: [Option], place: String?, people: [String], respondent: String? = nil, callNames: [String: [String]] = [:],
                present: [String] = [], partner: String? = nil, places: [String] = [], placeAliases: [String: [String]] = [:]) {
        self.options = options
        self.place = place
        self.people = people
        self.respondent = respondent
        self.callNames = callNames
        self.present = present
        self.partner = partner
        self.places = places
        self.placeAliases = placeAliases
    }

    public static func make(rules: GameRules, state: GameState) -> InterpretChoices {
        let scenario = rules.scenario
        func name(_ person: String) -> String {
            guard let p = scenario.person(person) else { return person }
            return p.speakerName == p.id ? p.id : "\(p.id)（\(p.speakerName)）"
        }
        var options: [Option] = []
        // 答え済みの意図も候補に残す（選ばれたら自由会話になる。近い別の意図への取り違えを防ぐ）
        for (i, input) in (rules.inputCandidates(in: state) + rules.answeredIntents(in: state)).enumerated() {
            let token = "A\(i + 1)"
            var label: String
            var examples: [String] = []
            var requiredWords: [String] = []
            switch input {
            case .intent(let id):
                let intent = scenario.intent(id)
                label = intent?.description ?? id
                examples = intent?.examples ?? []
                requiredWords = intent?.words ?? []
            case .move(let place):
                let aliases = scenario.placeAliases[place] ?? []
                label = "場所を移る：「\(place)」へ行く" + (aliases.isEmpty ? "" : "（\(aliases.joined(separator: "・"))とも言う）")
            case .leave:
                label = "今いる場所を離れる（「そろそろ出よう」「ちょっと失礼」「お邪魔しました」など、その場を離れる言葉があるときだけ。相づちや、話の中身への返事は当たらない）"
            case .none:
                continue
            }
            options.append(Option(token: token, input: input, label: label, examples: examples, requiredWords: requiredWords))
        }
        var callNames: [String: [String]] = [:]
        for p in scenario.persons {
            callNames[p.id] = p.speakerName == p.id ? [p.id] : [p.id, p.speakerName]
        }
        var choices = InterpretChoices(
            options: options,
            place: rules.currentScene(state)?.place,
            people: rules.presentPersons(in: state).map(name),
            respondent: rules.respondent(in: state),
            callNames: callNames,
            present: rules.presentPersons(in: state),
            partner: scenario.partner,
            places: rules.places,
            placeAliases: scenario.placeAliases
        )
        for scene in scenario.scenes {
            if let person = scene.person, choices.personPlaces[person] == nil { choices.personPlaces[person] = scene.place }
        }
        return choices
    }

    /// 入力が向けられた人物（文の頭で名前を呼んでいる人。相棒に、その場の人物のことを第三者として尋ねているときは相棒）
    ///
    /// 決まらなければ nil（いつもどおり、その場の人物が答える）。
    public func addressee(of text: String) -> String? {
        if let p = Addressing.vocative(text, callNames: callNames, among: present) { return p }
        // 「葵はどう思う？」のように、その場の1人に意見を尋ねていれば、その人
        let asked = present.filter { Addressing.asksOpinion(text, names: callNames[$0] ?? [$0]) }
        if asked.count == 1 { return asked[0] }
        if let partner, present.contains(partner),
           present.contains(where: { $0 != partner && Addressing.mentionsAsThirdPerson(text, names: callNames[$0] ?? [$0]) }) {
            return partner
        }
        return nil
    }
}

/// 呼びかけと、第三者としての言及の判定（規則）
public enum Addressing {
    /// 呼びかけの名前のあとに続く文字
    static let separators: Set<Character> = ["、", "。", "，", ",", " ", "　", "！", "!", "？", "?", "…", "っ"]
    static let honorifics = ["さん", "くん", "君", "ちゃん", ""]
    /// 第三者として話題にする言い方（名前と敬称のあとに続く）
    static let thirdPersonTails = ["に聞いた", "に聞いて", "から聞いた", "から聞いて", "からは", "から何", "が言って", "が言った",
                                   "の話では", "はなんて", "は何て", "って何て"]
    /// その人に意見を尋ねる言い方（名前と敬称のあとに続く）
    static let opinionTails = ["はどう思", "はどう？", "はどう?", "はどうなの", "の意見", "の考え", "はどっち", "ならどう"]

    /// 文の頭で名前を呼ばれている人物
    public static func vocative(_ text: String, callNames: [String: [String]], among persons: [String]) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in persons {
            for name in (callNames[p] ?? [p]).sorted(by: { $0.count > $1.count }) {
                for h in honorifics {
                    let head = name + h
                    guard t.hasPrefix(head) else { continue }
                    let rest = t.dropFirst(head.count)
                    // 「ママって」は話題に出しているだけ（その場にいない人への呼びかけにすると、返事がなくなる）
                    if rest.hasPrefix("って") { continue }
                    if let c = rest.first, separators.contains(c) { return p }
                    if rest.isEmpty { return p }
                }
            }
        }
        return nil
    }

    /// 名前が第三者として出ているか（「ママから聞いたんだけど」など）
    public static func mentionsAsThirdPerson(_ text: String, names: [String]) -> Bool {
        for name in names {
            for h in honorifics {
                if thirdPersonTails.contains(where: { text.contains(name + h + $0) }) { return true }
            }
        }
        return false
    }

    /// その人に意見を尋ねているか（「葵はどう思う？」「ママの意見は？」）
    public static func asksOpinion(_ text: String, names: [String]) -> Bool {
        names.contains { name in honorifics.contains { h in opinionTails.contains { text.contains(name + h + $0) } } }
    }

    /// 場所を指す言い方（場所の名前、別の呼び方、「の」の後ろ）
    public static func placeWords(_ place: String, aliases: [String: [String]] = [:]) -> [String] {
        var result = [place] + (aliases[place] ?? []).filter { !$0.isEmpty }
        if let last = place.components(separatedBy: "の").last, last.count >= 2, last != place { result.append(last) }
        return result
    }

    public static func mentions(place: String, in text: String, aliases: [String: [String]] = [:]) -> Bool {
        matchLength(place: place, in: text, aliases: aliases) > 0
    }

    /// 漢字にはさまれたひらがな1文字を除く（「控え室」と「控室」を同じに扱う）
    static func normalize(_ text: String) -> String {
        let chars = Array(text)
        func isKanji(_ c: Character) -> Bool {
            c.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || $0.value == 0x3005 }
        }
        func isHiragana(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) } }
        var result: [Character] = []
        for (i, c) in chars.enumerated() {
            if isHiragana(c), i > 0, i + 1 < chars.count, isKanji(chars[i - 1]), isKanji(chars[i + 1]) { continue }
            result.append(c)
        }
        return String(result)
    }

    /// 入力の中で、その場所を指すいちばん長い言い方の長さ（当たらなければ 0）
    static func matchLength(place: String, in text: String, aliases: [String: [String]] = [:]) -> Int {
        let t = normalize(text)
        return placeWords(place, aliases: aliases).map(normalize).filter { t.contains($0) }.map(\.count).max() ?? 0
    }

    /// 入力がいちばんはっきり指している場所（長い言い方で当たった場所。同じ長さで複数あれば nil）
    public static func clearestPlace(in text: String, among places: [String], aliases: [String: [String]] = [:]) -> String? {
        let top = clearestPlaces(in: text, among: places, aliases: aliases)
        return top.count == 1 ? top[0] : nil
    }

    /// 入力がいちばん長い言い方で指している場所（同じ長さなら複数。どれにも当たらなければ空）
    public static func clearestPlaces(in text: String, among places: [String], aliases: [String: [String]] = [:]) -> [String] {
        var unique: [String] = []
        for p in places where !unique.contains(p) { unique.append(p) }
        let scored = unique.map { ($0, matchLength(place: $0, in: text, aliases: aliases)) }.filter { $0.1 > 0 }
        guard let best = scored.map(\.1).max() else { return [] }
        return scored.filter { $0.1 == best }.map(\.0)
    }

    /// 場所を言わずに、行くことに同意しているか（「行ってみよう」「そうしよう、行こう」）。問い（「行ったの？」）は含めない
    public static func agreesToGo(_ text: String) -> Bool {
        let goes = ["行こう", "行きましょう", "行ってみよう", "行ってみましょう", "行きます", "行ってくる", "向かおう", "そうしよう", "そうしましょう"]
        return goes.contains { text.contains($0) } && !RefinedInterpreter.isQuestion(text)
    }

    /// 行く言い方のほかに、行き先の手がかりになる言葉がない（「行ってみよう」「じゃあ、行こう」）
    public static func isBareGo(_ text: String) -> Bool {
        guard agreesToGo(text) else { return false }
        var rest = text
        for w in ["行ってみましょう", "行ってみよう", "行きましょう", "行こう", "行きます", "向かおう", "そうしよう", "そうしましょう",
                  "では", "じゃあ", "それじゃ", "よし", "はい", "うん", "ええ", "そうだね", "とりあえず", "まず"] {
            rest = rest.replacingOccurrences(of: w, with: "")
        }
        return rest.filter { !"。、！？!?…ー〜 　,.".contains($0) }.count <= 1
    }

    /// 今いる場所へ行こうとしているか（店内で「店に戻ろう」と言ったとき）
    public static func movesToCurrentPlace(_ text: String, current: String?, aliases: [String: [String]] = [:]) -> Bool {
        guard let current, mentions(place: current, in: text, aliases: aliases) else { return false }
        return ["行", "向か", "戻", "移動"].contains { text.contains($0) }
    }
}

/// 入力の解釈の結果
public struct Interpretation: Sendable, Equatable {
    public var input: PlayerInput
    /// モデルを呼んだ時間（ミリ秒。呼ばなかったときは 0）
    public var milliseconds: Int
}

/// プレイヤーの自由文を、選択肢の中から1つの入力に解釈する
public protocol InputInterpreting: Sendable {
    func interpret(_ text: String, choices: InterpretChoices) async throws -> Interpretation
}

/// Foundation Models による入力の解釈
///
/// 選択肢は状態ごとに変わるので、DynamicGenerationSchema の anyOf で毎回組み立てる。
/// モデルに文を作らせず、記号を1つ選ばせるだけにする（温度 0）。
public struct FoundationModelsInterpreter: InputInterpreting {
    private let model: SystemLanguageModel
    public var timeoutSeconds: Double
    /// 文脈の大きさ（端末のモデルから実行時に取得する）
    public var budget: ContextBudget
    /// 呼び出しごとに使った文脈の大きさを知らせる先（画面の表示）
    public var usageObserver: (@Sendable (ContextUsage) -> Void)?

    public init(model: SystemLanguageModel = .default, timeoutSeconds: Double = 20, budget: ContextBudget? = nil) {
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.budget = budget ?? .system(model, replyReserve: 64)
    }

    static let none = "none"

    static let instructions = """
    あなたは会話アドベンチャーゲームの入力解析係です。主人公（プレイヤー）の発言が、下の選択肢のどれに当たるかを1つだけ選びます。
    - 発言例と同じ意味なら、その選択肢を選ぶ（言い回しが違っても意味で判断する）
    - 「場所を移る」は、行き先の一部の言い方（「奥」「店」など）でも、そこへ行こうとする発言なら選ぶ
    - 選択肢の説明にある話題・行動に当たるときだけ選ぶ。あいさつ、相手への気づかい、感想、選択肢にない話は none
    - 「うん」「そうしよう」などの短い返事は、直前の相手の発言（誘いや問いかけ）への答えとして判断する
    - 迷ったら none（会話として扱えば、ゲームは止まらない）
    """

    static func prompt(_ text: String, choices: InterpretChoices, withExamples: Bool = true) -> String {
        var lines = ["## 選択肢"]
        for o in choices.options {
            let ex = o.examples.isEmpty || !withExamples ? "" : " 例「\(o.examples.joined(separator: "」「"))」"
            lines.append("- \(o.token): \(o.label)\(ex)")
        }
        lines.append("")
        lines.append("## 今の場面")
        lines.append("- 場所: \(choices.place ?? "-")")
        lines.append("- その場の人物: \(choices.people.isEmpty ? "（主人公だけ）" : choices.people.joined(separator: "、"))")
        // 直前の相手の発言（短い返事が何への答えかを判断するため）
        if let last = choices.lastUtterance {
            lines.append("- 直前の相手の発言:「\(last)」")
        }
        lines.append("")
        lines.append("発言:「\(PromptQuote.player(text))」")
        return lines.joined(separator: "\n")
    }

    public func interpret(_ text: String, choices: InterpretChoices) async throws -> Interpretation {
        guard !choices.options.isEmpty else { return Interpretation(input: .none, milliseconds: 0) }
        let root = DynamicGenerationSchema(name: "InputChoice", properties: [
            .init(name: "choice", description: "選択肢の記号。当てはまらなければ none",
                  schema: DynamicGenerationSchema(name: "ChoiceToken", anyOf: choices.options.map(\.token) + [Self.none])),
        ])
        let schema = try GenerationSchema(root: root, dependencies: [])
        let model = self.model
        // 選択肢が多くて文脈の大きさを超えるときは、発言例を外す
        let full = Self.prompt(text, choices: choices)
        let used = await TokenCounter.count(Self.instructions + "\n" + full, model: model)
        let fits = used <= budget.promptLimit
        if ProcessInfo.processInfo.environment["YUKEMURI_DEBUG_PROMPT"] != nil {
            FileHandle.standardError.write("解釈のプロンプト：\(used) トークン（上限 \(budget.promptLimit)、選択肢 \(choices.options.count)）\(fits ? "" : "→ 発言例を外した")\n".data(using: .utf8)!)
        }
        let prompt = fits ? full : Self.prompt(text, choices: choices, withExamples: false)
        let clock = ContinuousClock()
        let start = clock.now
        let token: String? = try await withTimeout(seconds: timeoutSeconds, timeoutError: LLMError.timeout(timeoutSeconds)) {
            let session = LanguageModelSession(model: model, instructions: Self.instructions)
            do {
                let response = try await session.respond(to: prompt, schema: schema, options: GenerationOptions(temperature: 0))
                ContextUsage.report(.interpret, input: Self.instructions + "\n" + prompt, output: response.content.jsonString,
                                    contextSize: budget.contextSize, model: model, to: usageObserver)
                return try? response.content.value(String.self, forProperty: "choice")
            } catch {
                throw LLMError.from(error)
            }
        }
        let input = choices.options.first { $0.token == token }?.input ?? .none
        if ProcessInfo.processInfo.environment["YUKEMURI_DEBUG_PROMPT"] != nil {
            FileHandle.standardError.write("解釈：モデルの選択 \(token ?? "-") → \(input)\n".data(using: .utf8)!)
        }
        return Interpretation(input: input, milliseconds: start.duration(to: clock.now).milliseconds)
    }
}

/// モデルの解釈を、規則で補正する
///
/// モデルは選択肢の並びや直前の発言につられて揺れるので、言葉ではっきりわかるもの（行き先の名前、別れのあいさつ、
/// 発言例とほぼ同じ文）は、規則で決める。
public struct RefinedInterpreter: InputInterpreting {
    public let inner: any InputInterpreting

    public init(inner: any InputInterpreting) {
        self.inner = inner
    }

    /// その場を離れることを表す言葉（どれもなければ「離脱」にしない）
    static let leaveWords = ["行ってく", "行ってみ", "行きます", "行きましょう", "行こう", "行く", "出かけ", "出発", "出ます", "出よう",
                             "向かう", "向かお", "失礼", "移動", "お邪魔しました", "おいとま", "出ましょう"]
    /// 場所を見たい・行きたいと頼む言い方（モデルが「どれにも当たらない」にしたときの移動の補正に使う）
    static let moveRequestWords = ["見に行", "行きたい", "入りたい", "戻りたい", "連れて行", "連れていって"]
    /// 行くと言い切る言い方（疑問でないときだけ、上と同じ補正に使う）
    static let moveGoWords = ["行きます", "行こう", "行きましょう", "行ってみ", "向かおう", "入ろう", "戻ろう", "戻ります"]
    /// 場所を言わずに移ろうとする、そのほかの言い方（モデルが移動を選んだとき、移動として残す手がかりに使う）
    static let moveOtherWords = ["移ろう", "移りましょう", "場所を変え", "戻る", "戻ろ", "あっちで", "向こうで"]
    /// 別れのあいさつ（発言がこれで終わっていれば、モデルが選ばなくても離脱にする）。
    /// 「失礼します」は入るときのあいさつにもなるので、終わりだけを見る
    static let farewellEndings = ["お邪魔しました", "おじゃましました", "失礼します", "失礼しました", "おいとまします", "出ましょう"]
    /// 疑問の言い方（「？」がなくても疑問とみなす）
    static let questionEndings = ["か", "かな", "かい", "の", "のか", "っけ"]
    /// 人に会いに行く言い方（「ママに会いに行こう」）
    static let visitWords = ["会いに", "会おう", "会いましょう", "会いたい", "話を聞こう", "話を聞きに", "聞きに行", "のところへ", "のところに"]

    public func interpret(_ text: String, choices: InterpretChoices) async throws -> Interpretation {
        // 含む語に合わない意図は、はじめから候補に入れない
        var narrowed = choices
        narrowed.options = choices.options.filter { $0.allows(text) }
        var result = try await inner.interpret(text, choices: narrowed)
        result.input = Self.refine(result.input, text: text, choices: choices)
        return result
    }

    public static func refine(_ input: PlayerInput, text: String, choices: InterpretChoices) -> PlayerInput {
        // 意図の発言例とほぼ同じ文なら、モデルの選択よりその意図を優先する（候補の並びしだいで、近い別の意図に取られるため）
        if let matched = nearExample(text, choices: choices) { return matched }
        // その場にいない人物を名指しして会いに行く言い方は、その人物の場所への移動にする
        if Addressing.clearestPlaces(in: text, among: choices.places, aliases: choices.placeAliases).isEmpty,
           let visit = visitingPerson(text: text, choices: choices) {
            return visit
        }
        let refined = refineChoice(input, text: text, choices: choices)
        guard refined == .none else { return refined }
        return requestedMove(text: text, choices: choices) ?? .none
    }

    /// 発言例とほぼ同じ文（句読点と空白を除いて、共通する文字の並びが長いほうの9割以上）の意図。1つに決まらなければ nil
    static func nearExample(_ text: String, choices: InterpretChoices) -> PlayerInput? {
        func bare(_ t: String) -> [Character] { Array(t.filter { !"。、！？!?…「」『』 　,.ー〜".contains($0) }) }
        let t = bare(text)
        guard t.count >= 6 else { return nil }
        var hits = Set<PlayerInput>()
        for option in choices.options {
            guard case .intent = option.input, option.allows(text) else { continue }
            for example in option.examples {
                let e = bare(example)
                if Double(lcs(t, e)) / Double(max(t.count, e.count)) >= 0.9 { hits.insert(option.input) }
            }
        }
        return hits.count == 1 ? hits.first : nil
    }

    /// 2つの文字の並びの、いちばん長い共通部分列の長さ
    static func lcs(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count { cur[j] = a[i - 1] == b[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1]) }
            prev = cur
        }
        return prev[b.count]
    }

    /// 行き先の場所（行ける場所の名前）
    static func destinations(_ choices: InterpretChoices) -> [String] {
        choices.options.compactMap { o -> String? in if case .move(let p) = o.input { p } else { nil } }
    }

    /// その場にいない人物を名指しして会いに行こうとしたら、その人物のいる場所（行ける場所に限る）への移動にする
    static func visitingPerson(text: String, choices: InterpretChoices) -> PlayerInput? {
        guard visitWords.contains(where: { text.contains($0) }), !isQuestion(text) else { return nil }
        let targets = Set(choices.personPlaces.compactMap { person, place -> String? in
            guard !choices.present.contains(person), destinations(choices).contains(place),
                  (choices.callNames[person] ?? [person]).contains(where: { text.contains($0) }) else { return nil }
            return place
        })
        return targets.count == 1 ? .move(targets.first!) : nil
    }

    /// モデルが「どれにも当たらない」にしても、行ける場所をはっきり名指しして、行きたい・行くと言っていれば、その場所への移動にする
    static func requestedMove(text: String, choices: InterpretChoices) -> PlayerInput? {
        guard moveRequestWords.contains(where: { text.contains($0) })
                || (!isQuestion(text) && moveGoWords.contains(where: { text.contains($0) })) else { return nil }
        let all = choices.places + (choices.place.map { [$0] } ?? [])
        let named = Addressing.clearestPlaces(in: text, among: all, aliases: choices.placeAliases).filter { $0 != choices.place }
        guard named.count == 1, destinations(choices).contains(named[0]) else { return nil }
        return .move(named[0])
    }

    static func refineChoice(_ input: PlayerInput, text: String, choices: InterpretChoices) -> PlayerInput {
        let all = choices.places + (choices.place.map { [$0] } ?? [])
        // 行く言葉と、今行ける場所の名前がはっきりあれば、モデルの選択にかかわらず移動にする
        // （直前の台詞につられて、移動にならないことがあるため）
        if Addressing.agreesToGo(text) || leaveWords.contains(where: { text.contains($0) }), !isQuestion(text),
           let named = Addressing.clearestPlace(in: text, among: all, aliases: choices.placeAliases),
           destinations(choices).contains(named) {
            return .move(named)
        }
        switch input {
        case .intent:
            let option = choices.options.first { $0.input == input }
            return option?.allows(text) == false ? .none : input
        case .none where choices.options.contains(where: { $0.input == .leave }) && endsWithFarewell(text):
            return .leave
        case .leave, .none:
            // 場所を言わずに「行ってみよう」と答えたときは、直前の発言が勧めた行ける場所へ移る
            if Addressing.agreesToGo(text), Addressing.clearestPlaces(in: text, among: all, aliases: choices.placeAliases).isEmpty,
               let last = choices.lastUtterance,
               let suggested = Addressing.clearestPlace(in: last, among: all, aliases: choices.placeAliases),
               destinations(choices).contains(suggested) {
                return .move(suggested)
            }
            // その場を離れる言葉のない相づちや返事は、離脱にしない
            if input == .leave, !leaveWords.contains(where: { text.contains($0) }) { return .none }
            return input
        case .move(let place):
            // 入力がはっきり指している場所を優先する。行ける場所ならそこへ、今いる場所なら移動にしない
            let top = Addressing.clearestPlaces(in: text, among: all, aliases: choices.placeAliases)
            // 行ける場所の名前のない問いは、移動にしない
            if top.isEmpty, isQuestion(text) || SentenceSplitter.split(text).contains(where: { isQuestion($0) }) { return .none }
            if top.isEmpty {
                // 場所を言わずに「行ってみよう」と答えたときは、直前の発言が勧めた行ける場所へ
                if Addressing.agreesToGo(text), let last = choices.lastUtterance,
                   let suggested = Addressing.clearestPlace(in: last, among: all, aliases: choices.placeAliases),
                   destinations(choices).contains(suggested) {
                    return .move(suggested)
                }
                // 行き先の手がかりのない「行こう」だけなら、勝手に移らない
                if Addressing.isBareGo(text) { return .none }
                // 場所の名前も、移る言い方もない文（「今度一緒に映画見ようよ」など）は、移動にしない
                // （どの意図の語も含まない文では、候補が移動だけになり、誘う言い方につられて移動が選ばれるため）
                if !(leaveWords + moveGoWords + moveRequestWords + moveOtherWords).contains(where: { text.contains($0) }) { return .none }
                return input
            }
            guard top.count == 1 else { return top.contains(place) ? input : .none }
            let named = top[0]
            return named == choices.place ? .none : .move(named)
        }
    }

    /// 発言の最後の文が、別れのあいさつで終わっているか（疑問は除く）
    static func endsWithFarewell(_ text: String) -> Bool {
        guard !isQuestion(text) else { return false }
        let last = SentenceSplitter.split(text).last ?? text
        let body = last.trimmingCharacters(in: CharacterSet(charactersIn: "。！!…　 "))
        return farewellEndings.contains { body.hasSuffix($0) }
    }

    static func isQuestion(_ text: String) -> Bool {
        let last = SentenceSplitter.split(text).last ?? text
        if SentenceSplitter.isQuestion(last) { return true }
        let body = last.trimmingCharacters(in: CharacterSet(charactersIn: "。！!…　 "))
        return questionEndings.contains { body.hasSuffix($0) }
    }
}
