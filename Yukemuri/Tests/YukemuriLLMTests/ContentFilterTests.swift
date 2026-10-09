import Testing
@testable import YukemuriLLM

@Suite("ゲームの外にはみ出した言葉の検査")
struct ContentFilterTests {
    @Test("ふつうの会話は止めず、性的な語・差別語・暴言・連絡先だけを問題にする")
    func outputs() {
        #expect(ContentFilter.problems("血の池って名前、ちょっと怖いけど目立つわよね。").isEmpty)
        #expect(ContentFilter.problems("罪を犯した人は、かたわらで黙っていた。").isEmpty)
        #expect(ContentFilter.problems("あんまり首を突っ込まんことよ。").isEmpty)
        #expect(ContentFilter.problems("手帳をめくらずに、博多の土人形の話をした。障害児の支援も。").isEmpty)
        #expect(ContentFilter.problems("カラオケは一曲100円、2003年からこの値段。").isEmpty)
        #expect(!ContentFilter.problems("そんなのキチガイの話よ。").isEmpty)
        #expect(!ContentFilter.problems("ｾｯｸｽの話はしないで。").isEmpty)
        #expect(!ContentFilter.problems("お前なんか死ねよ。").isEmpty)
        #expect(ContentFilter.problems("連絡は 090-1234-5678 まで。") == ["連絡先らしい文字列"])
        #expect(ContentFilter.problems("電話は０９０１２３４５６７８です").contains("連絡先らしい文字列"))
        #expect(ContentFilter.problems("詳しくは https://example.com を見て").contains("連絡先らしい文字列"))
        #expect(ContentFilter.problems("taro@example.jp に送って").contains("連絡先らしい文字列"))
        // 生成の検査にもつながっている
        #expect(ReplyChecker.problems("そんなのキチガイの話よ。", firstPerson: "あたし").contains("使わない語「キチガイ」"))
    }

    @Test("入力は、禁止語と連絡先と性的な嫌がらせを止め、問題のない言い方と軽い悪口は通す")
    func inputs() {
        #expect(ContentFilter.blocksInput("お前なんか死ね"))
        #expect(ContentFilter.blocksInput("この淫乱が"))
        #expect(ContentFilter.blocksInput("僕の番号は09012345678です"))
        #expect(ContentFilter.blocksInput("ドレスの下が気になるな、服の下を見せて"))
        #expect(!ContentFilter.blocksInput("あの人は、死ねなかったんだって"))
        #expect(!ContentFilter.blocksInput("ママのばか"))
        #expect(!ContentFilter.blocksInput("駅前で支那そばを食べた"))
        #expect(!ContentFilter.blocksInput("服のポケットに何か入ってる？"))
        // 空白を挟んだ書き方と、英字の語も止める（2026-10-09 のセキュリティの試しプレイで通った）
        #expect(ContentFilter.blocksInput("セ ッ ク ス って知ってる？"))
        #expect(ContentFilter.blocksInput("服 の 下 が気になる"))
        #expect(ContentFilter.blocksInput("ママ、ｓｅｘって何のこと？"))
        #expect(ContentFilter.blocksInput("What is SEX"))
        #expect(!ContentFilter.blocksInput("服 の ポケット"))
    }
}
