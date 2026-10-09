import Foundation
import YukemuriEngine

/// 人物ごとの会話の履歴（自由会話のプロンプトの「直前のやりとり」）
///
/// その人物がその場で聞いた発言だけを持つ（控え室での話を、店内のママは知らない）。
public struct ConversationLog: Sendable, Codable {
    var byPerson: [String: [String]] = [:]
    /// 1人あたりに残す行数（実際にプロンプトに入れる量は、文脈の大きさに合わせて PromptFitter が決める）
    public var limit = 40

    public init() {}

    public mutating func record(_ line: String, heardBy persons: [String]) {
        var seen = Set<String>()
        for p in persons where seen.insert(p).inserted {
            var lines = byPerson[p, default: []]
            lines.append(line)
            if lines.count > limit { lines.removeFirst(lines.count - limit) }
            byPerson[p] = lines
        }
    }

    public func recent(for person: String) -> [String] { byPerson[person] ?? [] }
}

/// 画面に出すこと
public enum SessionEvent: Sendable, Equatable {
    /// 規則で起きたこと（定型文は `line` で、差し込みを埋めた文面と一緒に出す）
    case rule(RuleEvent)
    /// 定型文（`{名前}` を埋めた文面）
    case line(Line, text: String)
    /// 自由会話の台詞
    case reply(speaker: String, text: String, source: ReplySource)
    /// 進行の知らせ（規則の外で、セッションが出すもの。「今いるのは〜だ」など）
    case notice(String)
}

/// 1回の入力の結果
public struct SessionTurn: Sendable {
    public var input: PlayerInput
    public var interpretMs: Int
    /// 解釈がエラーになったとき（その場合は「どれにも当たらない入力」として進める）
    public var interpretError: String?
    public var events: [SessionEvent]
    public var reply: SafeReply?
    /// プレイヤーが名前を呼んだ相手（規則で判定。ログに残す）
    public var addressee: String? = nil
}

/// エンジン・入力の解釈・自由会話をつないだ、1人のプレイヤーのゲーム
public actor GameSession {
    public nonisolated let rules: GameRules
    private(set) var interpreter: any InputInterpreting
    private(set) var talker: SafeTalker
    /// 入力の解釈を待つ全体の上限（モデルのどこで止まっても、遊びが止まらないようにする）
    public var interpretDeadline = 45.0
    public private(set) var state = GameState()
    public private(set) var log = ConversationLog()
    /// 定型文を出した回数（言い換えを選ぶため。規則の状態には入れない）
    private var shownTimes: [String: Int] = [:]
    /// 人物ごとに使った「拒否されたときの台詞」（一巡するまで、使ったものを避ける）
    var usedFallbacks: [String: [String]] = [:]
    /// 自由会話のプロンプトに入れる直前のやりとりの行数（短い返事のときは briefHistoryLines）
    /// 長すぎると、小さいモデルが今の発言に集中できない（40 行入れると、誘いを取り違えた）
    public var historyLines = 12
    public var briefHistoryLines = 8
    /// 入力の直前に出た発言（定型文か自由会話の返事）
    var lastUtterance: String?
    /// 最後に台詞を作ったときのプロンプト（デバッグの表示とログに使う）
    public private(set) var lastPrompt: TalkPrompt?
    /// 主人公の記憶（項目 → 記憶）
    public private(set) var memory: [String: MemoryItem] = [:]
    /// 発言から記憶を取り出す（nil なら記憶しない）
    private var memoryExtractor: (any MemoryExtracting)?
    /// プレイヤーが言葉を入力した回数（記憶に触れた後、数往復のあいだ外すのに使う）
    private var turnCounter = 0
    /// 記憶の項目ごとに、返事の中で最後に触れた入力の回数
    private var memoryMentioned: [String: Int] = [:]
    /// 人物ごとの最近の自由会話の返事（話題の引きずりの判断に使う。直前のやりとりは、ほかの人の台詞が入ると短くなるため）
    private var recentReplies: [String: [String]] = [:]
    /// 記憶を取り出したこと・取り出せなかったことを知らせる（ログに残すため）
    private var memoryObserver: (@Sendable (String) -> Void)?

    public init(rules: GameRules, interpreter: any InputInterpreting, talker: any Talking,
                memoryExtractor: (any MemoryExtracting)? = nil) {
        self.rules = rules
        self.interpreter = interpreter
        self.talker = SafeTalker(inner: talker)
        self.memoryExtractor = memoryExtractor
    }

    public var protagonistName: String { rules.scenario.protagonist.name }

    /// 止めた入力への地の文
    public static let blockedInputNarration = "……その言葉は、口にしないでおいた。"

    /// つらさを打ち明けたときの案内（作品の外から、プレイヤーに向けて出す）
    public static let distressNotice = "（つらい気持ちのときは、ひとりで抱えずに、身近な信頼できる人や、「いのちの電話」などの相談窓口に話してみてください）"

    /// 記憶を取り出したことを知らせる先（ログ）
    public func setMemoryObserver(_ observer: (@Sendable (String) -> Void)?) {
        memoryObserver = observer
    }

    /// 記憶を直接入れる（評価用。聞いた人は、登場人物の全員にする。nil なら消す）
    public func setMemory(_ slot: String, _ value: String?) {
        memory[slot] = value.map { MemoryItem(value: $0, heardBy: rules.scenario.persons.map(\.id), utterance: $0) }
    }

    /// 聞いた人を指定して記憶を入れる（テスト用）
    func setMemory(_ slot: String, _ value: String, heardBy: [String]) {
        memory[slot] = MemoryItem(value: value, heardBy: heardBy, utterance: value)
    }

    /// 入力の解釈と台詞の生成を差し替える（文脈の大きさの設定を、遊んでいる途中で切り替えるため）
    public func replaceModels(interpreter: any InputInterpreting, talker: any Talking) {
        self.interpreter = interpreter
        self.talker = SafeTalker(inner: talker)
    }

    /// 始める（最初から）
    public func start() -> [SessionEvent] {
        state = GameState()
        log = ConversationLog()
        shownTimes = [:]
        usedFallbacks = [:]
        lastUtterance = nil
        memory = [:]
        memoryMentioned = [:]
        recentReplies = [:]
        turnCounter = 0
        return apply(rules.start())
    }

    /// 表示名（台詞の見出しと、直前のやりとりの名前）
    public nonisolated func displayName(_ person: String) -> String {
        rules.scenario.person(person)?.speakerName ?? person
    }

    /// プレイヤーの自由文を処理する
    /// - Parameter picked: 画面で選んだ話し相手（nil なら自動。文の頭で名前を呼んだときは、そちらを優先する）
    public func send(_ text: String, to picked: String? = nil) async -> SessionTurn {
        // 性的な語・差別語・暴言・連絡先を含む入力は、AFM に渡さず、履歴にも残さない（画面と CLI のどちらから来ても）
        if ContentFilter.blocksInput(text) {
            return SessionTurn(input: .none, interpretMs: 0, interpretError: nil, events: [.notice(Self.blockedInputNarration)], reply: nil)
        }
        var choices = InterpretChoices.make(rules: rules, state: state)
        choices.lastUtterance = lastUtterance
        // 今いる場所へ行こうとしたときは、解釈も規則も通さずに知らせる（往復にも数えない）
        if Addressing.movesToCurrentPlace(text, current: choices.place, aliases: choices.placeAliases),
           !choices.places.contains(where: { $0 != choices.place && Addressing.mentions(place: $0, in: text, aliases: choices.placeAliases) }),
           let place = choices.place {
            return SessionTurn(input: .none, interpretMs: 0, interpretError: nil, events: [.notice("（今いるのが、\(place)だ）")], reply: nil)
        }
        // その場にいない人物を名前で呼んだときは、ほかの人が代わりに答えないように知らせる
        let absent = Self.meetablePersons(rules.scenario).filter { !choices.present.contains($0) }
        if Addressing.vocative(text, callNames: choices.callNames, among: choices.present) == nil,
           let who = Addressing.vocative(text, callNames: choices.callNames, among: absent) {
            return SessionTurn(input: .none, interpretMs: 0, interpretError: nil,
                               events: [.notice("（\(displayName(who))は、ここにはいない）")], reply: nil)
        }
        // 名前を呼んだ相手が、ふだん答える人と違うときは、ほかの人が定型文で答える意図を候補から外す
        let explicit = picked.flatMap { choices.present.contains($0) ? $0 : nil }
        let addressee = Addressing.vocative(text, callNames: choices.callNames, among: choices.present)
            ?? explicit ?? choices.addressee(of: text)
        if let addressee, addressee != rules.respondent(in: state) {
            let state = self.state
            choices.options.removeAll { option in
                guard case .intent = option.input, let who = rules.responder(to: option.input, in: state) else { return false }
                return who != addressee
            }
        }
        // つらさを打ち明けたら、解釈を通さずに、その場の人物が自由会話で受け止める。相談窓口の案内を先に出し、
        // 生成が通らなかったときの拒否の台詞（突き放して聞こえる）は出さない
        if ContentFilter.expressesDistress(text) {
            var turn = await perform(.none, text: text, addressee: addressee, showsFallback: false)
            turn.events = [.notice(Self.distressNotice)] + turn.events.filter { event in
                if case .reply(_, _, .fallback) = event { return false }
                return true
            }
            turn.addressee = addressee
            return turn
        }
        var input = PlayerInput.none
        var ms = 0
        var interpretError: String?
        do {
            let interpreter = self.interpreter
            let deadline = interpretDeadline
            let choices = choices
            let result = try await withTimeout(seconds: deadline, timeoutError: LLMError.timeout(deadline)) {
                try await interpreter.interpret(text, choices: choices)
            }
            // 候補にない入力（話し相手で外した意図など）は、どれにも当たらない入力として扱う
            input = choices.options.contains { $0.input == result.input } ? result.input : .none
            ms = result.milliseconds
        } catch {
            interpretError = LLMError.from(error).kind
        }
        var turn = await perform(input, text: text, addressee: addressee)
        turn.interpretMs = ms
        turn.interpretError = interpretError
        turn.addressee = addressee
        return turn
    }

    /// 解釈を通さずに入力を渡す（行き先の一覧から選んだときなど）
    /// - Parameter text: 画面に出したプレイヤーの言葉（履歴と自由会話に使う。なければ nil）
    /// - Parameter addressee: プレイヤーが名前を呼んだ相手（その場にいれば、自由会話はその人が答える）
    /// - Parameter showsFallback: 自由会話が通らなかったとき、拒否されたときの台詞を履歴に残すか（出さない場合は false）
    public func perform(_ input: PlayerInput, text: String? = nil, addressee: String? = nil, showsFallback: Bool = true) async -> SessionTurn {
        if let text {
            // 直前のやりとりはプロンプトに1行ずつ入るので、改行で偽の行（「ママ: …」）を作らせない
            log.record("主人公: \(PromptQuote.player(text))", heardBy: rules.presentPersons(in: state))
            turnCounter += 1
        }
        defer { if let text { scheduleMemory(from: text) } }
        let step = rules.handle(input, in: state)
        let addressed = addressee.flatMap { rules.presentPersons(in: state).contains($0) ? $0 : nil }

        // 入力がどの意図にも当たらないのに決まった台詞が進むときは、その場の人物が先に短く返事をする
        // （こちらの言葉に関係なく話題が進む感じを和らげる）
        // 相づちだけの入力には返事をはさまない。返事が作れなかった（定型文に戻した）ときも、返事は出さずに定型文だけを出す
        if input == .none, let text, !step.lines.isEmpty, !ReplyChecker.isBackchannel(text),
           !step.lines.contains(where: \.noAck), let who = addressed ?? rules.respondent(in: state) {
            // このあと続く定型文を渡して、食い違わない返事にする
            let upcoming = step.lines.prefix(2).map { line in
                "\(line.speaker.map(displayName) ?? "地の文"): \(fill(line.text))"
            }
            let r = await generateReply(to: text, speaker: who, input: input, brief: true, recordFallback: false, upcoming: Array(upcoming))
            // 続く定型文を写しただけの返事は出さない
            let copies = Self.copiesUpcoming(r.text, lines: step.lines.prefix(2).map { fill($0.text) })
            let ack = r.source == .fallback || copies ? [] : [SessionEvent.reply(speaker: who, text: r.text, source: r.source)]
            return SessionTurn(input: input, interpretMs: 0, interpretError: nil, events: ack + apply(step), reply: r)
        }

        var events = apply(step)
        var reply: SafeReply?
        // 定型文が出た入力には、後ろに自由会話の返事を付けない（定型文が話を進めるので、返事が重なる）
        for case .freeTalk(let respondent?) in step.events where step.lines.isEmpty {
            let who = addressed ?? respondent
            let r = await generateReply(to: text ?? "……", speaker: who, input: input, brief: false, recordFallback: showsFallback)
            events.append(.reply(speaker: who, text: r.text, source: r.source))
            reply = r
        }
        return SessionTurn(input: input, interpretMs: 0, interpretError: nil, events: events, reply: reply)
    }

    /// どこかの場面で会える人物（場面の人物と、`登場` の効果で現れる人物）
    static func meetablePersons(_ scenario: Scenario) -> [String] {
        var ids = Set<String>()
        for scene in scenario.scenes {
            if let p = scene.person { ids.insert(p) }
            for line in scene.lines {
                for case .enterPerson(let p) in line.effects { ids.insert(p) }
            }
        }
        return scenario.persons.map(\.id).filter { ids.contains($0) }
    }

    /// 返事のどれかの文が、続く定型文を写しているか（句読点と空白は比べない）。6字以上の文がそのまま含まれるか、
    /// 10字以上の並びが共通していれば写したとみなす
    static func copiesUpcoming(_ reply: String, lines: [String]) -> Bool {
        func bare(_ t: String) -> String { t.filter { !"。、！？!?…「」『』 　,.ー〜".contains($0) } }
        let targets = lines.map(bare)
        return SentenceSplitter.split(reply).map(bare).contains { s in
            (s.count >= 6 && targets.contains { $0.contains(s) }) || targets.contains { commonRun(s, $0) >= 10 }
        }
    }

    /// 2つの文字列に共通する、いちばん長い並びの長さ
    static func commonRun(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: y.count + 1), best = 0
        for i in 1...x.count {
            var cur = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count where x[i - 1] == y[j - 1] {
                cur[j] = prev[j - 1] + 1
                best = max(best, cur[j])
            }
            prev = cur
        }
        return best
    }

    /// 今の状態で、その人物の自由会話の台詞を作る（拒否されたら定型文に戻す）。履歴にも残す
    /// - Parameter recordFallback: 定型文に戻したときも履歴に残すか（短い返事を出さないときは残さない）
    func generateReply(to text: String, speaker who: String, input: PlayerInput, brief: Bool, recordFallback: Bool = true,
                       upcoming: [String] = []) async -> SafeReply {
        let history = Array(log.recent(for: who).suffix(brief ? briefHistoryLines : historyLines))
        // 主人公の記憶：その人物が聞いたことのうち、今の発言の話題に合うもの
        // 短い返事（このあと決まった台詞が続く）には、覚えているかをはっきり聞かれたときだけ入れる
        var selection = MemorySelector.select(memory, speaker: who, input: text, turn: turnCounter, lastMentioned: memoryMentioned)
        if brief && !selection.asked { selection = MemorySelector.Selection(facts: [], asked: false) }
        let prompt = TalkPrompt.make(rules: rules, state: state, speaker: who, input: input,
                                     recentLines: history, brief: brief, upcoming: upcoming,
                                     protagonistFacts: selection.facts, recallAsked: selection.asked)
        let used = usedFallbacks[who] ?? []
        let fallback = rules.fallbackLine(of: who, in: state, avoiding: Set(used))
        var checked = prompt
        checked.ownRecentReplies = recentReplies[who] ?? []
        lastPrompt = checked
        let r = await talker.reply(to: text, prompt: checked, fallback: fallback.map { fill($0.text) })
        if r.source != .fallback { recentReplies[who] = Array(((recentReplies[who] ?? []) + [r.text]).suffix(5)) }
        if r.source == .fallback && !recordFallback { return r }
        if r.source == .fallback, let fallback {
            // 避けたものしか残っていなければ（一巡した）、そこから数え直す
            usedFallbacks[who] = used.contains(fallback.id) ? [fallback.id] : used + [fallback.id]
        }
        log.record("\(displayName(who)): \(r.text)", heardBy: rules.presentPersons(in: state))
        lastUtterance = r.text
        // 返事の中で触れた記憶は、数往復のあいだプロンプトに入れない（同じ話のくり返しを防ぐ）
        for (slot, item) in memory where r.text.contains(item.value) { memoryMentioned[slot] = turnCounter }
        return r
    }

    /// 発言から記憶を取り出す（返事を出した後に、裏で。取り出せたら memory に入れる）
    private func scheduleMemory(from text: String) {
        guard let extractor = memoryExtractor, !ContentFilter.blocksInput(text),
              let statements = MemorySlots.statements(in: text) else { return }
        // 発言を聞いたのは、そのときその場にいた人物（雑談のプロンプトに入れる相手を決める）
        let heard = rules.presentPersons(in: state)
        Task {
            let facts = (try? await extractor.extractChat(from: statements)) ?? []
            for fact in facts where MemorySlots.chat.contains(fact.slot) {
                self.storeMemory(fact.slot, raw: fact.value, utterance: statements, heardBy: heard)
            }
        }
    }

    private func storeMemory(_ slot: String, raw: String?, utterance: String, heardBy: [String]) {
        if let value = MemorySlots.validate(raw, utterance: utterance) {
            // 同じ値なら、前に聞いた人も覚えている。値が変わったら、今聞いた人だけにする
            let before = memory[slot]
            let heard = Array(Set(heardBy + (before?.value == value ? before!.heardBy : []))).sorted()
            memory[slot] = MemoryItem(value: value, heardBy: heard, utterance: utterance)
            memoryObserver?("記憶した：\(slot)＝\(value)（発言「\(utterance)」、聞いた人 \(heard.map(displayName).joined(separator: "・"))）")
        } else {
            memoryObserver?("記憶しなかった：\(slot)（取り出した値「\(raw ?? "-")」、発言「\(utterance)」）")
        }
    }

    /// 規則の結果を状態に反映し、定型文を履歴に残す
    func apply(_ step: Step) -> [SessionEvent] {
        state = step.state
        let present = rules.presentPersons(in: state)
        return step.events.map { event in
            guard case .line(let line) = event else {
                // 場面が変わったら、前の場面の人物の発言を「直前の相手の発言」として持ち越さない
                if case .sceneEntered = event { lastUtterance = nil }
                return .rule(event)
            }
            // 言い換えのある行は、出した回数で文面を選ぶ
            shownTimes[line.id, default: 0] += 1
            let text = fill(line.text(forTime: shownTimes[line.id]!))
            if line.kind == .dialogue { lastUtterance = text }
            let who = line.speaker.map(displayName) ?? "地の文"
            log.record("\(who): \(text)", heardBy: present + (line.speaker.map { [$0] } ?? []))
            return .line(line, text: text)
        }
    }

    /// `{名前}` を埋める
    public nonisolated func fill(_ text: String) -> String {
        text.replacingOccurrences(of: "{名前}", with: rules.scenario.protagonist.name)
    }
}
