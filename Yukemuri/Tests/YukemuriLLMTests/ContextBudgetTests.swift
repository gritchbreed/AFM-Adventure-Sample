import Foundation
import Testing
@testable import YukemuriLLM

@Suite("文脈の大きさに収める")
struct ContextBudgetTests {
    let prompt = TalkPrompt(speaker: "葵", base: String(repeating: "あ", count: 100),
                            recentLines: (1...10).map { "主人公: 行\($0)" })

    @Test("収まるときは、直前のやりとりを削らない")
    func fitsAsIs() async {
        let fitted = await PromptFitter.fit(prompt, text: "入力", limit: 10_000) { $0.count }
        #expect(fitted?.recentLines.count == 10)
    }

    @Test("収まらないときは、古いほうから1往復ずつ削る")
    func dropsOldest() async {
        let full = (prompt.base + "\n" + prompt.message(for: "入力")).count
        let fitted = await PromptFitter.fit(prompt, text: "入力", limit: full - 20) { $0.count }
        let kept = fitted?.recentLines ?? []
        #expect(kept.count < 10 && kept.count % 2 == 0)
        #expect(kept.last == "主人公: 行10")
    }

    @Test("収まらないときは、主人公について聞いたことを、直前のやりとりより先に外す")
    func dropsFactsFirst() async {
        var p = prompt
        p.protagonistFacts = ["出身: 福岡", "趣味: 釣り"]
        let full = (p.base + "\n" + p.message(for: "入力")).count
        let fitted = await PromptFitter.fit(p, text: "入力", limit: full - 5) { $0.count }
        #expect(fitted?.protagonistFacts.isEmpty == true)
        #expect(fitted?.recentLines.count == 10)
    }

    @Test("直前のやりとりを全部削っても収まらなければ nil")
    func tooLarge() async {
        #expect(await PromptFitter.fit(prompt, text: "入力", limit: 50) { $0.count } == nil)
    }

    @Test("プロンプトに使える上限は、返答の分を空ける")
    func limit() {
        #expect(ContextBudget(contextSize: 8192, replyReserve: 400).promptLimit == 7792)
        #expect(ContextBudget(contextSize: 100, replyReserve: 400).promptLimit == 0)
    }
}
