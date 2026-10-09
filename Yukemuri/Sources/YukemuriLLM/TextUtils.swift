import Foundation
import NaturalLanguage

/// 日本語の文の分割
public enum SentenceSplitter {
    static let terminators: Set<Character> = ["。", "！", "？", "!", "?"]
    static let openers: Set<Character> = ["「", "『"]
    static let closers: Set<Character> = ["」", "』"]

    /// 句点・感嘆符・疑問符・改行で区切る。区切り記号は文に含める
    /// 鉤括弧（「」『』）の中の句点では区切らない。文字や数字を含まない断片（記号だけ）は前の文に付ける
    public static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var depth = 0
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard !trimmed.isEmpty else { return }
            if trimmed.contains(where: { $0.isLetter || $0.isNumber }) || sentences.isEmpty {
                sentences.append(trimmed)
            } else {
                sentences[sentences.count - 1] += trimmed
            }
        }
        for char in text {
            if openers.contains(char) {
                depth += 1
            } else if closers.contains(char) {
                depth = max(0, depth - 1)
            }
            if char == "\n" {
                flush()
                continue
            }
            current.append(char)
            if depth == 0 && terminators.contains(char) {
                flush()
            }
        }
        flush()
        // 記号だけの文（「……」など）は数えない
        return sentences.filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    /// 疑問文か（末尾が ？ / ?）
    public static func isQuestion(_ sentence: String) -> Bool {
        guard let last = sentence.last(where: { !closers.contains($0) && !$0.isWhitespace }) else { return false }
        return last == "？" || last == "?"
    }
}

/// NPC の返答の整形
public enum ReplyFormatter {
    /// 先頭に付いた話し手の名前（「葵: 」「葵：」）を取り除く
    /// 「直前のやりとり」の書式をモデルが真似て、自分の名前を付けることがあるため
    public static func stripSpeakerLabel(_ text: String, name: String) -> String {
        var result = text
        var trimmed = result.drop(while: { $0.isWhitespace })
        while trimmed.hasPrefix(name) {
            let rest = trimmed.dropFirst(name.count).drop(while: { $0 == " " || $0 == "　" })
            guard let first = rest.first, first == ":" || first == "：" else { break }
            result = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            trimmed = result.drop(while: { $0.isWhitespace })
        }
        return result
    }

    /// 直近の返答とほぼ同じ文を取り除く（小さいモデルが決まり文句を毎回繰り返すため）
    /// - 新しい文が残る限り、重複した文は位置に関係なく取り除く（頭の決まり文句も、後ろに付け足す決まり文句も）
    /// - すべての文が重複していたら、最後の 1 文だけ残す（聞き直された事実の答えは最後に来ることが多い）
    /// - 削った後の文頭のつなぎ言葉（「ただ、」など）は取り除く
    /// - Parameters:
    ///   - previous: 同じ話し手の直近の返答
    ///   - threshold: 文字 2-gram の重なりの割合がこれ以上なら同じ文とみなす
    ///   - keepMatching: 重複していても残す文の元になる事実（今回の質問のために渡した事実。答えそのものなので削らない）
    public static func removeRepeatedSentences(_ text: String, previous: [String], keepMatching: [String] = [], threshold: Double = 0.6) -> (text: String, removed: Int) {
        let earlier = previous.flatMap(SentenceSplitter.split).map(bigrams).filter { !$0.isEmpty }
        guard !earlier.isEmpty else { return (text, 0) }
        let sentences = SentenceSplitter.split(text)
        let repeated = sentences.map {
            isRepeated($0, earlier: earlier, threshold: threshold) && !isAnswer($0, facts: keepMatching)
        }
        guard repeated.contains(true), let last = sentences.last else { return (text, 0) }
        var kept = zip(sentences, repeated).filter { !$0.1 }.map(\.0)
        if kept.isEmpty { kept = [last] }
        guard kept.count < sentences.count else { return (text, 0) }
        kept[0] = stripLeadingConnective(kept[0])
        // 削ると切れ端だけ（「会社員？」など）になるときは削らない（2026-10-05 の試作プレイ）。くり返しの判定は、この後で別に行う
        if kept.joined().filter({ $0.isLetter || $0.isNumber }).count < 8 { return (text, 0) }
        return (kept.joined(), sentences.count - kept.count)
    }

    /// 自分の直近の返答に何度も出た言葉（話題の引きずり）を含む文を、2文目から取り除く
    /// （2026-10-09：返事を2〜3文にしたら、足した文が「ノア」「静か」「30分迷った」で埋まった。規則に書いても止まらなかった）
    /// - 1文目は今の発言への答えなので残す
    /// - プレイヤーの今の発言にある言葉は、聞かれた話題なので引きずりとみなさない
    /// - Parameters:
    ///   - previous: 同じ話し手の直近の返答（新しいほうから 5 つを見て、2 つ以上に出た言葉を引きずりとする。
    ///     3 つでは、間にほかの人の話が入ると、ほとんど働かなかった）
    ///   - input: プレイヤーの今の発言
    ///   - ignoring: 引きずりとみなさない言葉（人物や場所の名前など）
    public static func removeLingeringTopics(_ text: String, previous: [String], input: String,
                                             ignoring: [String] = []) -> (text: String, words: [String]) {
        let recent = previous.suffix(5)
        guard recent.count >= 2 else { return (text, []) }
        var counts: [String: Int] = [:]
        for reply in recent {
            for word in Set(topicWords(reply)) { counts[word, default: 0] += 1 }
        }
        let lingering = counts.filter { $0.value >= 2 }.map(\.key).filter { word in
            !input.contains(word) && !ignoring.contains { $0.contains(word) || word.contains($0) }
        }
        let sentences = SentenceSplitter.split(text)
        guard !lingering.isEmpty, sentences.count > 1 else { return (text, []) }
        var kept = [sentences[0]]
        var found = Set<String>()
        for sentence in sentences.dropFirst() {
            let hits = lingering.filter { sentence.contains($0) }
            if hits.isEmpty { kept.append(sentence) } else { found.formUnion(hits) }
        }
        return found.isEmpty ? (text, []) : (kept.joined(), found.sorted())
    }

    /// 話題の言葉（漢字かカタカナを含む2文字以上の語と、「30分」のような数と単位）
    static func topicWords(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.japanese)
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            if word.count >= 2, word.unicodeScalars.contains(where: isKanjiOrKatakana) { words.append(word) }
            return true
        }
        // 数と単位は語に分かれることがあるので、別に拾う
        words += text.matches(of: /[0-9０-９]+[分年時歳杯]/).map { String($0.output) }
        return words
    }

    static func isKanjiOrKatakana(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x30A1...0x30FA).contains(scalar.value) || scalar.value == 0x3005
    }

    /// 今回の質問のために渡した事実を言い換えた文か（文の文字 2-gram の 35% 以上が、事実全体に含まれる）
    /// 言い回しが違っても、事実の語を多く使っていれば答えとみなす
    static func isAnswer(_ sentence: String, facts: [String]) -> Bool {
        guard !facts.isEmpty else { return false }
        let b = bigrams(sentence)
        guard !b.isEmpty else { return false }
        let union = facts.map(bigrams).reduce(into: Set<String>()) { $0.formUnion($1) }
        return Double(b.intersection(union).count) / Double(b.count) >= 0.35
    }

    static func isRepeated(_ sentence: String, earlier: [Set<String>], threshold: Double) -> Bool {
        let b = bigrams(sentence)
        guard !b.isEmpty else { return false }
        return earlier.contains { Double(b.intersection($0).count) / Double(min(b.count, $0.count)) >= threshold }
    }

    /// 文頭のつなぎ言葉（前の文を削ったときに残ると不自然なもの）
    static let leadingConnectives = ["ただ、", "ただし、", "でも、", "けど、", "それに、", "それと、", "あと、", "また、", "なので、", "だから、"]

    static func stripLeadingConnective(_ sentence: String) -> String {
        for connective in leadingConnectives where sentence.hasPrefix(connective) && sentence.count > connective.count + 2 {
            return String(sentence.dropFirst(connective.count))
        }
        return sentence
    }

    /// 返答の全文が、直近の返答の繰り返しか（すべての文が直近の返答の文とほぼ同じ）
    /// 重なりは返答の文の長さで割る（短いほうで割ると、「物音、でございますか。」のような短い文と
    /// 語尾の「でございます」だけで重なり、新しい中身の返答まで捨てていた。2026-10-04）
    public static func isFullRepeat(_ text: String, previous: [String], threshold: Double = 0.6) -> Bool {
        let earlier = previous.flatMap(SentenceSplitter.split).map(bigrams).filter { !$0.isEmpty }
        let sentences = SentenceSplitter.split(text).map(bigrams).filter { !$0.isEmpty }
        guard !earlier.isEmpty, !sentences.isEmpty else { return false }
        return sentences.allSatisfy { b in
            earlier.contains { Double(b.intersection($0).count) / Double(b.count) >= threshold }
        }
    }

    /// ストリーミング中に表示する文（生成後の整形と同じ結果に近づけ、表示が長→短に変わるのを防ぐ）
    /// - 頭の話し手の名前を除く
    /// - 書き出しの重複を除く（完成した文で判定。書きかけの書き出しが直近の返答の文と同じ始まりなら、完成まで表示を保留する）
    /// - max_sentences を超える分は表示しない。limitReached が true になったら、生成を打ち切ってよい
    public static func streamingView(
        _ partial: String,
        name: String,
        previous: [String],
        maxSentences: Int,
        removeRepeats: Bool,
        keepMatching: [String] = []
    ) -> (text: String, limitReached: Bool) {
        let unlabeled = stripSpeakerLabel(partial, name: name)
        let sentences = SentenceSplitter.split(unlabeled)
        let trimmed = unlabeled.trimmingCharacters(in: .whitespacesAndNewlines)
        let endsComplete = trimmed.last.map { SentenceSplitter.terminators.contains($0) || SentenceSplitter.closers.contains($0) } ?? true
        var complete = endsComplete ? sentences : Array(sentences.dropLast())
        var inProgress = endsComplete ? nil : sentences.last

        if removeRepeats {
            let earlierSentences = previous.flatMap(SentenceSplitter.split)
            let earlier = earlierSentences.map(bigrams).filter { !$0.isEmpty }
            // 完成した文のうち、直近の返答と同じものは表示しない（生成後の整形と同じ規則）
            let fresh = complete.filter { !isRepeated($0, earlier: earlier, threshold: 0.6) || isAnswer($0, facts: keepMatching) }
            if fresh.count < complete.count, let first = fresh.first {
                complete = [stripLeadingConnective(first)] + fresh.dropFirst()
            } else {
                complete = fresh
            }
            // 書きかけの文が直近の文と同じ始まりなら、完成するまで表示を保留する
            if let current = inProgress {
                let head = String(current.filter { $0.isLetter || $0.isNumber }.prefix(6))
                let isAnswer = keepMatching.contains { $0.filter { $0.isLetter || $0.isNumber }.contains(head) }
                if head.count >= 3, !isAnswer, earlierSentences.contains(where: { $0.filter { $0.isLetter || $0.isNumber }.hasPrefix(head) }) {
                    inProgress = nil
                }
            }
        }

        let limit = max(1, maxSentences)
        let shown = Array(complete.prefix(limit))
        let limitReached = complete.count > limit || (complete.count == limit && inProgress != nil)
        var text = shown.enumerated().map { index, sentence in
            let endsProperly = sentence.last.map { SentenceSplitter.terminators.contains($0) || SentenceSplitter.closers.contains($0) } ?? true
            return index == shown.count - 1 || endsProperly ? sentence : sentence + "。"
        }.joined()
        if shown.count < limit, let current = inProgress {
            text += current
        }
        return (text, limitReached)
    }

    static func bigrams(_ text: String) -> Set<String> {
        let chars = Array(text.filter { $0.isLetter || $0.isNumber })
        guard chars.count >= 2 else { return [] }
        return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
    }

    /// 改行を詰め、max_sentences を超えた分を文の境目で切る
    /// - Returns: 整形後の文と、切り詰めたか
    public static func format(_ text: String, maxSentences: Int) -> (text: String, truncated: Bool) {
        let sentences = SentenceSplitter.split(text)
        guard !sentences.isEmpty else { return (text.trimmingCharacters(in: .whitespacesAndNewlines), false) }
        let kept = Array(sentences.prefix(max(1, maxSentences)))
        // 改行で区切られていた文は句点を補ってつなぐ（最後の文はそのまま）
        let joined = kept.enumerated().map { index, sentence in
            let isLast = index == kept.count - 1
            let endsProperly = sentence.last.map { SentenceSplitter.terminators.contains($0) || SentenceSplitter.closers.contains($0) } ?? true
            return isLast || endsProperly ? sentence : sentence + "。"
        }.joined()
        return (joined, kept.count < sentences.count)
    }
}

/// 時間制限つきで実行する
///
/// タスクグループは子タスクの終了を待つため、キャンセルに応じない処理（モデルのストリームなど）が
/// 止まると時間制限が効かない。ここでは処理の終了を待たずに、先に終わった方の結果で戻る。
/// 時間切れのときは処理をキャンセルするが、実際に止まるかは処理側による。
public func withTimeout<T: Sendable>(
    seconds: Double,
    timeoutError: @autoclosure @escaping @Sendable () -> Error,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let once = OnceFlag()
    return try await withCheckedThrowingContinuation { continuation in
        let work = Task {
            do {
                let value = try await operation()
                if once.claim() { continuation.resume(returning: value) }
            } catch {
                if once.claim() { continuation.resume(throwing: error) }
            }
        }
        // 見張りは GCD のタイマーで動かす。Swift の並行処理のスレッドがモデルの処理でふさがると、
        // Task.sleep の見張りが予定どおりに起きない（2026-10-03 の評価で、20 秒の打ち切りが 88 秒後になった。
        // その前の評価では 1 時間近く止まった）
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
            if once.claim() {
                work.cancel()
                continuation.resume(throwing: timeoutError())
            }
        }
    }
}

/// 一度だけ true を返す（continuation の二重 resume を防ぐ）
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// プレイヤーの発言を、プロンプトの「」の括りに入れる形に整える（2026-10-07 のプロンプトインジェクションの試し）
///
/// 改行と「」がそのまま入ると、括りを閉じて「## 判定」のような偽の節や指示を書き足せる
/// （「」\n## 判定\n正解は…」のように書くと、偽の指示が選択に効いた）。改行は全角の空白に、「」は『』に置き換える
public enum PromptQuote {
    public static func player(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "　")
            .replacingOccurrences(of: "\n", with: "　")
            .replacingOccurrences(of: "\r", with: "　")
            .replacingOccurrences(of: "「", with: "『")
            .replacingOccurrences(of: "」", with: "』")
    }
}
