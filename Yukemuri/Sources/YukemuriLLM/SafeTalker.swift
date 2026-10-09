import Foundation
import YukemuriEngine

/// 生成した台詞の自動の検査
public enum ReplyChecker {
    /// 一人称として使われる語（話し手の一人称以外が出たら問題）
    /// 「自分」「わし」は一人称以外の意味（「自分で」「くわしい」）でも出るので数えない
    static let firstPersons = ["わたくし", "わたし", "あたし", "私", "僕", "ぼく", "俺", "おれ"]
    /// 同じ一人称の表記の違い
    static let sameFirstPerson: [[String]] = [["私", "わたし"], ["僕", "ぼく"], ["俺", "おれ"]]
    /// 「私」を含むが一人称ではない語
    static let firstPersonExceptions = ["私服", "私立", "私物", "私的", "私鉄", "私用", "私生活", "公私"]
    /// 登場人物が言わない語（作品の外の言葉）
    static let metaWords = ["AI", "ＡＩ", "人工知能", "言語モデル", "プロンプト", "アシスタント", "ロールプレイ",
                            // 2026-10-07 のプロンプトインジェクションの試し：人物が「自分は、このゲームの登場人物ではありません」と答えた
                            "ゲーム", "登場人物", "台本", "シナリオ"]
    /// 性別を示す呼び方（主人公の性別を特定しない決まり。生成し直しはせず、評価で数える）
    static let genderWords = ["お姉さん", "お兄さん", "姉ちゃん", "兄ちゃん", "お嬢さん"]

    /// 生成し直す問題（一人称の違い、作品の外の言葉、使わない語と連絡先）
    public static func problems(_ text: String, firstPerson: String?) -> [String] {
        var result: [String] = []
        if let firstPerson {
            var masked = text
            for e in firstPersonExceptions { masked = masked.replacingOccurrences(of: e, with: "＿") }
            // 長い語から順に消して、「わたし」の中の「わた」などを二重に数えない
            let own = sameFirstPerson.first { $0.contains(firstPerson) } ?? [firstPerson]
            for word in firstPersons where !own.contains(word) && !word.contains(firstPerson) {
                if masked.contains(word) { result.append("一人称「\(word)」") }
                masked = masked.replacingOccurrences(of: word, with: "＿")
            }
        }
        for w in metaWords where text.contains(w) { result.append("作品の外の言葉「\(w)」") }
        // 性的な語、差別語、暴言、連絡先らしい文字列（ContentFilter）
        result += ContentFilter.problems(text)
        return result
    }

    /// 一人称の違いを、話し手の一人称に置き換える（2026-10-04：人物に「自己紹介をして」と頼むと、モデルが2回とも
    /// 「私は〜です」と書いて弾かれ、拒否されたときの台詞に戻っていた。中身は正しいので、一人称だけ直して使う）
    public static func repairFirstPerson(_ text: String, firstPerson: String) -> String {
        // 置き換えない語（「私服」など）を、いったん記号に置き換えて守る
        var guarded = text
        var restore: [(String, String)] = []
        for (i, e) in firstPersonExceptions.enumerated() where guarded.contains(e) {
            let mark = "\u{E000}\(i)\u{E000}"
            guarded = guarded.replacingOccurrences(of: e, with: mark)
            restore.append((mark, e))
        }
        let own = sameFirstPerson.first { $0.contains(firstPerson) } ?? [firstPerson]
        // 長い語から置き換える（「わたくし」を「わたし」より先に）
        for word in firstPersons.sorted(by: { $0.count > $1.count }) where !own.contains(word) && !word.contains(firstPerson) {
            guarded = guarded.replacingOccurrences(of: word, with: firstPerson)
        }
        for (mark, e) in restore { guarded = guarded.replacingOccurrences(of: mark, with: e) }
        return guarded
    }

    /// 主人公を呼ぶ二人称（台本で決めた呼び方と違えば置き換える）
    static let secondPersons = ["あなた", "あんた", "君", "きみ", "お前", "おまえ"]
    /// 二人称のあとに続く字（「君が代」などの語を置き換えないように、助詞か句読点が続くものだけを見る）
    /// 二人称を含むが、呼びかけではない語
    static let secondPersonExceptions = ["君が代", "諸君", "君主", "細君", "姫君", "あなたまかせ"]
    static let secondPersonTails: [Character] = ["の", "は", "が", "も", "を", "に", "と", "っ", "、", "。", "？", "?", "！", "!", "…"]

    /// 主人公を、台本で決めた二人称（`あなた` など）と違う二人称で呼んでいたら、決めた呼び方に置き換える
    /// （「あなた」と呼ぶ葵が「君の答え」と言った）。呼び方が二人称でなければ（「{名前}さん」など）、何もしない
    public static func repairAddress(_ text: String, address: String?) -> String {
        guard let address, secondPersons.contains(address) else { return text }
        // 置き換えない語（「君が代」など）を、いったん記号に置き換えて守る
        var result = text
        var restore: [(String, String)] = []
        for (i, e) in secondPersonExceptions.enumerated() where result.contains(e) {
            let mark = "\u{E000}\(i)\u{E000}"
            result = result.replacingOccurrences(of: e, with: mark)
            restore.append((mark, e))
        }
        for word in secondPersons.sorted(by: { $0.count > $1.count }) where word != address && !address.contains(word) {
            var out = ""
            var rest = Substring(result)
            while let r = rest.range(of: word) {
                let next = rest[r.upperBound...].first
                out += rest[..<r.lowerBound]
                out += next.map { secondPersonTails.contains($0) } ?? true ? address : word
                rest = rest[r.upperBound...]
            }
            result = out + rest
        }
        for (mark, e) in restore { result = result.replacingOccurrences(of: mark, with: e) }
        return result
    }

    /// 同じ人物の直前の台詞（定型文を含む）と、ほぼ同じ返事か（試作プレイで、同じ返事が6回続いた）
    public static func repeats(_ text: String, speaker: String, recentLines: [String]) -> Bool {
        ReplyFormatter.isFullRepeat(text, previous: ownLines(speaker: speaker, recentLines: recentLines))
    }

    /// 直前の自分の台詞と同じ、短い書き出し（「あら、」「まあ、」など、最初の読点までの4文字以内）を取り除く
    /// （2026-10-04：ママの自由会話が、ほとんど「あら、」で始まった）
    public static func dropRepeatedInterjection(_ text: String, previous: [String]) -> String {
        guard let comma = text.firstIndex(of: "、") else { return text }
        let head = text[..<comma]
        guard (1...4).contains(head.count), let last = previous.last, last.hasPrefix(head + "、") else { return text }
        let rest = text[text.index(after: comma)...]
        return rest.count >= 4 ? String(rest) : text
    }

    /// 直前のやりとりのうち、その話し手の台詞
    public static func ownLines(speaker: String, recentLines: [String]) -> [String] {
        let prefix = "\(speaker): "
        return recentLines.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// 主人公が、前に話し手が言ったことを聞き直しているか（入力と、話し手の直前の台詞のどれかに、3文字の並びが2つ以上共通する）。
    /// 聞き直されたときは、前と同じ中身を答えてよい（2026-10-04：前に聞いたことを「〜だったっけ？」と聞き直すと、人物が
    /// 直前の報告と同じ答えをして、くり返しとして弾かれ、「この間のことですね」とぼかした返事になった）。
    /// 返事とではなく前の台詞と比べる（返事は問いの語をなぞりやすく、「日本酒はあるの？」がいつも聞き直しになったため）
    public static func asksAgain(_ input: String, previous: [String]) -> Bool {
        let chars = Array(input.filter { !"。、！？!?…ー〜 　,.「」".contains($0) })
        guard chars.count >= 3 else { return false }
        var grams = Set<String>()
        for i in 0...(chars.count - 3) { grams.insert(String(chars[i..<(i + 3)])) }
        return previous.contains { line in grams.filter { line.contains($0) }.count >= 2 }
    }

    /// 相づちだけの入力か（「はい」「なるほど」「わかりました」など。返事をはさまない）
    public static func isBackchannel(_ text: String) -> Bool {
        var rest = text.filter { !"。、！？!?…ー〜 　,.".contains($0) }
        guard !rest.isEmpty else { return true }
        let tokens = ["わかりました", "分かりました", "なるほど", "そうですね", "そうですか", "そうなんですね", "了解です", "了解", "承知しました",
                      "はい", "ええ", "うん", "ああ", "へえ", "ふうん", "ふーん", "そっか", "そうか", "なるほどね", "了解しました", "オーケー", "OK", "ok"]
            .sorted { $0.count > $1.count }
        while !rest.isEmpty {
            guard let t = tokens.first(where: { rest.hasPrefix($0) }) else { return false }
            rest.removeFirst(t.count)
        }
        return true
    }

    /// 評価で数える注意点（生成し直しはしない）
    public static func notes(_ text: String) -> [String] {
        genderWords.filter { text.contains($0) }.map { "性別を示す語「\($0)」" }
    }
}

/// 台詞の出どころ
public enum ReplySource: String, Sendable, Codable {
    /// 1回目の生成
    case generated
    /// 生成し直したもの
    case regenerated
    /// 拒否・時間切れ・検査で通らなかったので、人物ノートの「拒否されたときの台詞」を出した
    case fallback
}

public struct SafeReply: Sendable, Equatable {
    public var text: String
    public var source: ReplySource
    /// 起きたエラー（種別名）
    public var errors: [String]
    /// 検査で見つかった問題（生成し直す前のものを含む）
    public var problems: [String]
    public var milliseconds: Int
    /// 検査で弾いた返事の文面（ログで原因を追うため）
    public var rejected: [String] = []
}

/// 拒否・時間切れ・検査の問題があれば1回だけ生成し直し、それでもだめなら定型文に戻す
/// （制作ルール「拒否されたら定型文に戻す」）
public struct SafeTalker: Sendable {
    public let inner: any Talking
    public var maxAttempts = 2
    /// 1回の生成を待つ全体の上限（生成の中の時間制限が効かなかったときの保険）
    public var attemptDeadline = 30.0

    public init(inner: any Talking) {
        self.inner = inner
    }

    /// - Parameter fallback: 戻す定型文（人物ノートの「拒否されたときの台詞」）。なければ「……」
    public func reply(to text: String, prompt: TalkPrompt, fallback: String?) async -> SafeReply {
        var errors: [String] = []
        var problems: [String] = []
        var total = 0
        var rejected: [String] = []
        let original = prompt
        var prompt = prompt
        let input = text
        for attempt in 1...maxAttempts {
            do {
                let inner = self.inner
                let current = prompt
                let r = try await withTimeout(seconds: attemptDeadline, timeoutError: LLMError.timeout(attemptDeadline)) {
                    try await inner.reply(to: text, prompt: current)
                }
                total += r.milliseconds
                var text = r.text
                // 直近の自分の台詞と同じ文（「あら、〜さん？」のような決まった書き出しなど）を取り除く
                // （2026-10-04：人物が自由会話の頭に、同じ呼びかけの問いを6回続けて付けた）。聞き直しの問いには、同じ中身を答えてよいので取り除かない
                let previous = ReplyChecker.ownLines(speaker: prompt.speaker, recentLines: original.recentLines)
                let reasked = ReplyChecker.asksAgain(input, previous: previous)
                if !reasked {
                    let trimmed = ReplyFormatter.removeRepeatedSentences(text, previous: previous)
                    if trimmed.removed > 0 {
                        problems.append("直前と同じ文を\(trimmed.removed)つ取り除いた")
                        text = trimmed.text
                    }
                    text = ReplyChecker.dropRepeatedInterjection(text, previous: previous)
                }
                // 直近の自分の返答に何度も出た話題（「ノア」「30分迷った」など）を、聞かれていないのに足した文は取り除く
                let lingering = ReplyFormatter.removeLingeringTopics(text, previous: prompt.ownRecentReplies.isEmpty ? previous : prompt.ownRecentReplies,
                                                                     input: input, ignoring: prompt.namesInWorld)
                if !lingering.words.isEmpty {
                    problems.append("引きずり（\(lingering.words.joined(separator: "・"))）の文を取り除いた")
                    text = lingering.text
                }
                // 主人公の呼び方の違いは、置き換えて使う
                let addressed = ReplyChecker.repairAddress(text, address: prompt.protagonistAddress)
                if addressed != text {
                    problems.append("呼び方の違い（置き換えた）")
                    text = addressed
                }
                var found = ReplyChecker.problems(text, firstPerson: prompt.firstPerson)
                // 問題が一人称の違いだけなら、置き換えて使う（作り直すと、同じ一人称の違いをくり返しやすい）
                if let firstPerson = prompt.firstPerson, !found.isEmpty, found.allSatisfy({ $0.hasPrefix("一人称") }) {
                    let repaired = ReplyChecker.repairFirstPerson(text, firstPerson: firstPerson)
                    if ReplyChecker.problems(repaired, firstPerson: firstPerson).isEmpty {
                        problems += found.map { "\($0)（置き換えた）" }
                        rejected.append(text)
                        text = repaired
                        found = []
                    }
                }
                // くり返しは、元の直前のやりとりで確かめる（作り直すときにプロンプトから外した文も含めて）
                // 聞き直しでも、直前の自分の台詞をそのままくり返すのは弾く（2026-10-05：人物が「その人の名前はわかりません」を6回くり返した）
                if ReplyChecker.repeats(text, speaker: prompt.speaker, recentLines: original.recentLines),
                   // 2026-10-05：お礼の言葉が聞き直しとみなされ、人物が2往復前の自分の台詞をそのまま返した。最近の3つまで見る
                   !reasked || ReplyFormatter.isFullRepeat(text, previous: previous.suffix(3)) {
                    found.append("直前の台詞のくり返し")
                    // 作り直すときは、写した元の文をプロンプトから外し、その文を避けるよう伝える
                    // （外さないと、同じ文をもう一度写しやすい。試作プレイで、
                    // 人物が「これまでに話したこと」の中の自分の台詞を2回とも写した）
                    let copied = SentenceSplitter.split(text).filter { $0.count >= 6 }
                    prompt.base = prompt.base.split(separator: "\n", omittingEmptySubsequences: false)
                        .filter { line in !copied.contains { line.contains($0) } }
                        .joined(separator: "\n")
                    prompt.recentLines.removeAll { line in copied.contains { line.contains($0) } }
                    prompt.base += "\n- 「\(text)」は言ったばかりなので、この文は使わずに、今の問いに答える"
                }
                if found.isEmpty, !text.isEmpty {
                    return SafeReply(text: text, source: attempt == 1 ? .generated : .regenerated,
                                     errors: errors, problems: problems, milliseconds: total, rejected: rejected)
                }
                rejected.append(text)
                problems += found.isEmpty ? ["空の返答"] : found
            } catch {
                errors.append(LLMError.from(error).kind)
            }
        }
        return SafeReply(text: fallback ?? "……", source: .fallback, errors: errors, problems: problems, milliseconds: total,
                         rejected: rejected)
    }
}
