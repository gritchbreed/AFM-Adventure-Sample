import Foundation
import FoundationModels

/// 文脈の大きさ（モデルが1回に扱える入力と出力のトークン数）
///
/// OS 27 では `SystemLanguageModel.contextSize` で実行時に取得できる。値は端末やモデルによって変わるので、
/// 固定の値を前提にしない（2026-10-02 の調査で、OS 26 の 4,096 から、OS 27 の例では 8,192）。
public struct ContextBudget: Sendable, Equatable {
    public var contextSize: Int
    /// 返答のために空けておくトークン数
    public var replyReserve: Int

    public init(contextSize: Int, replyReserve: Int = 400) {
        self.contextSize = contextSize
        self.replyReserve = replyReserve
    }

    /// プロンプト（instructions と入力）に使える上限
    public var promptLimit: Int { max(0, contextSize - replyReserve) }

    /// 試作用：文脈の大きさを固定する（nil なら端末のモデルの値）。アプリの「試作」メニューと、CLI の `--context` で設定する
    /// （2026-10-04：iPhone の機種によって文脈の大きさが違うかもしれないので、4,096 の端末で噛み合うかを確かめるため）。
    /// 固定しても、モデルそのものは変わらない。プロンプトをこの大きさに収まるよう削ることで、その端末と同じ条件にする
    nonisolated(unsafe) public static var override: Int?

    /// 端末のモデルの文脈の大きさ（`override` があれば、その値）
    public static func system(_ model: SystemLanguageModel = .default, replyReserve: Int = 400) -> ContextBudget {
        ContextBudget(contextSize: override ?? model.contextSize, replyReserve: replyReserve)
    }
}

/// トークン数を数える（数えられないとき・時間がかかるときは文字数で見積もる。日本語はおおむね 1 文字 1 トークン前後）
public enum TokenCounter {
    /// 数えるのを待つ上限（2026-10-03 の評価で、解釈 1 回に 15 分かかった。数える処理が時間制限の外にあった）
    public static let timeoutSeconds = 2.0

    public static func count(_ text: String, model: SystemLanguageModel = .default) async -> Int {
        let estimate = text.count
        return (try? await withTimeout(seconds: timeoutSeconds, timeoutError: LLMError.timeout(timeoutSeconds)) {
            try await model.tokenCount(for: Prompt(text))
        }) ?? estimate
    }
}

/// 自由会話のプロンプトを、文脈の大きさに収める
public enum PromptFitter {
    /// 上限に収める。まず主人公について聞いたことを外し、次に直前のやりとりを古いほうから削る。すべて削っても収まらなければ nil
    /// - Parameter text: 主人公の今の発言
    /// - Parameter count: 実際に渡す instructions と入力を合わせた文字列のトークン数を返す
    public static func fit(_ prompt: TalkPrompt, text: String, limit: Int,
                           count: (String) async -> Int) async -> TalkPrompt? {
        func size(_ p: TalkPrompt) async -> Int { await count(p.base + "\n" + p.message(for: text)) }
        if await size(prompt) <= limit { return prompt }
        let lean = prompt.withoutFacts()
        var keep = lean.recentLines.count
        while true {
            let candidate = lean.keepingRecent(keep)
            if await size(candidate) <= limit { return candidate }
            if keep == 0 { return nil }
            // 1往復（2行）ずつ削る
            keep = max(0, keep - 2)
        }
    }
}

/// 1回の呼び出しで使った文脈の大きさ（画面に出すため）
///
/// 呼び出しごとに新しいセッションを作るので、使った量は呼び出しごとに決まる（遊ぶほど溜まっていくものではない）。
/// 数えるのは instructions・入力・出力の合計。構造化出力のスキーマの分は数えられないので入らない
public struct ContextUsage: Sendable, Equatable {
    public enum Call: String, Sendable, CaseIterable {
        case interpret = "解釈"
        case talk = "会話"
        case memory = "記憶"
    }

    public var call: Call
    public var used: Int
    public var contextSize: Int

    public init(call: Call, used: Int, contextSize: Int) {
        self.call = call
        self.used = used
        self.contextSize = contextSize
    }

    /// 使用率（0〜1）
    public var ratio: Double { contextSize > 0 ? Double(used) / Double(contextSize) : 0 }

    /// 使った量を数えて知らせる（返事を遅らせないように、裏で数える）
    static func report(_ call: Call, input: String, output: String, contextSize: Int, model: SystemLanguageModel,
                       to observer: (@Sendable (ContextUsage) -> Void)?) {
        guard let observer else { return }
        Task {
            let used = await TokenCounter.count(input, model: model) + TokenCounter.count(output, model: model)
            observer(ContextUsage(call: call, used: used, contextSize: contextSize))
        }
    }
}
