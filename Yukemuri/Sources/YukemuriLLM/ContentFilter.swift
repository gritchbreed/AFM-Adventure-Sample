import Foundation

/// ゲームの外にはみ出した言葉の検査（プレイヤーの入力と、自由会話の出力に使う）
///
/// 物語の言葉は止めない。止めるのは、性的な語、差別語、暴言と、実在の連絡先らしい文字列だけ。
/// 組み込みのガードレールの後ろに置く最後の網で、網羅は目指さない（2026-10-06 のユーザーの指示。リストは自作と、whym の CC0 のリストから選んだ語）。
/// 語は、ほかの語の一部として出にくいものだけを選ぶ（「犯す」は「罪を犯す」、「かたわ」は「かたわら」、ひらがなの「まんこ」は
/// 大分の言葉の「突っ込まんこと」、「土人」は「土人形」、「めくら」は「めくらず」、「害児」は「障害児」に当たるので入れない）。
public enum ContentFilter {
    /// 性的な語
    static let sexualWords = [
        "セックス", "性交", "エッチ", "えっち", "レイプ", "強姦", "おっぱい", "乳首", "陰部", "性器", "勃起", "射精", "自慰",
        "オナニー", "売春", "援交", "援助交際", "ポルノ", "アダルトビデオ", "ちんこ", "ちんぽ", "マンコ", "パイズリ", "フェラチオ",
    ]
    /// 差別語
    static let slurs = [
        "キチガイ", "きちがい", "気違い", "気狂い", "ガイジ", "池沼", "ニガー", "黒んぼ", "ジャップ", "支那人", "チョン公",
        "三国人", "穢多", "片輪", "つんぼ", "オカマ野郎", "ホモ野郎",
    ]
    /// 相手に向けた暴言（物語の中の「死んだ」などは当たらない）
    static let abuse = ["死ねよ", "死んでしまえ", "くたばれ", "自殺しろ", "消えろよ"]

    /// whym の Japanese bad words list（https://gist.github.com/whym/b5ac3feb2a78797c9d98、CC0 1.0。表示の義務はない）から選んだ語。
    /// 2026-10-06 に取り込んだ。軽い悪口（ばか、あほ、うざい など）は、物語の中の口げんかを止めないように入れない。
    /// 「シネ」（シネマ）、「しね」（〜しねえ）、「在日」（在日米軍）は、ほかの語に当たるので入れない
    static let whymWords = ["死ね", "やりまん", "ヤリマン", "まんこ", "痴女", "淫乱", "チョン", "支那"]

    /// 相手への性的な嫌がらせの言い方（2026-10-08 ユーザーと決定。人物への「制服の下が気になるな」に「はい、ありがとうございます」と
    /// 応じる返事が出た。「体に触」「体を触」は「遺体に触れた」に当たるので入れない）
    static let harassment = ["制服の下", "着物の下", "ドレスの下", "服の下", "下着", "スカートの中", "胸を触", "お尻", "裸を", "裸に", "服を脱",
                             "抱かせ", "抱きたい", "やらせて", "ヤらせ", "胸が大き", "スリーサイズ"]

    static let blockedWords = sexualWords + slurs + abuse + whymWords + harassment

    /// 英字の語（小文字にそろえて比べる。ほかの語の一部になりやすい rape（grape）などは入れない）
    static let englishWords = ["sex", "porn", "fuck"]

    /// 間に挟んで検査をすり抜けるのに使われる空白（「セ ッ ク ス」「服 の 下」。2026-10-09 のセキュリティの試しプレイで通った）
    static let spacers = CharacterSet.whitespacesAndNewlines

    /// 禁止語を含むが、問題のない言い方（先に伏せてから検査する）
    static let allowedPhrases = ["死ねな", "死ねば", "死ねる", "込まんこと", "チョンマゲ", "ちょんまげ", "支那そば", "支那竹"]

    /// 連絡先らしい文字列（電話番号、メールアドレス、URL）。英字を含む作り物の番号は当たらない
    static let contactPatterns = [
        #"0\d{1,4}[-ー－‐ ]?\d{1,4}[-ー－‐ ]?\d{3,4}"#,
        #"\d{10,}"#,
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
        #"https?://"#,
        #"www\."#,
    ]

    /// 当たった語（検査の結果やログに出す）
    /// 空白を詰めた形でも見る（空白を挟んだ書き方を通さない）。英字の語は、半角の小文字にそろえて見る
    public static func blockedWords(in text: String) -> [String] {
        var masked = text.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? text
        for phrase in allowedPhrases { masked = masked.replacingOccurrences(of: phrase, with: "＿") }
        let compact = String(String.UnicodeScalarView(masked.unicodeScalars.filter { !spacers.contains($0) }))
        let ascii = (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text).lowercased()
        let asciiCompact = String(String.UnicodeScalarView(ascii.unicodeScalars.filter { !spacers.contains($0) }))
        return blockedWords.filter { masked.contains($0) || compact.contains($0) }
            + englishWords.filter { asciiCompact.contains($0) }
    }

    /// 連絡先らしい文字列があるか（全角の数字も半角にそろえて見る）
    public static func containsContact(_ text: String) -> Bool {
        let halfwidth = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        return contactPatterns.contains { halfwidth.range(of: $0, options: .regularExpression) != nil }
    }

    /// 出力の問題（生成し直すか、定型文に戻す）
    public static func problems(_ text: String) -> [String] {
        var result = blockedWords(in: text).map { "使わない語「\($0)」" }
        if containsContact(text) { result.append("連絡先らしい文字列") }
        return result
    }

    /// つらさを打ち明ける言い方（2026-10-09 のセキュリティの試しプレイで、生成がガードレールに止められ、
    /// 「さあ、それはあたしの口からは言えないわね」という拒否の台詞が出た。この入力は規則で見つけて、相談窓口を案内する）
    static let distressPhrases = ["死にたい", "消えたい", "消えてしまいたい", "いなくなりたい", "自殺したい", "生きてるのがしんどい",
                                  "生きてるのがつらい", "生きているのがつらい", "生きるのがつらい", "生きるのがしんどい", "生きていたくない"]

    /// つらさを打ち明けているか
    public static func expressesDistress(_ text: String) -> Bool {
        let compact = String(String.UnicodeScalarView(text.unicodeScalars.filter { !spacers.contains($0) }))
        return distressPhrases.contains { compact.contains($0) }
    }

    /// 入力を AFM に渡さずに止めるか（禁止語か、連絡先らしい文字列がある）
    /// 止めた入力は、ログにも本文を残さない
    public static func blocksInput(_ text: String) -> Bool {
        !blockedWords(in: text).isEmpty || containsContact(text)
    }
}
