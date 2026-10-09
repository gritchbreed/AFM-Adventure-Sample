import Foundation
import YukemuriEngine
import YukemuriLLM

/// デバッグ用の状態の要約（ログと、デバッグの画面で使う）
struct StateSummary: Encodable, Equatable {
    var scene: String?
    var flags: [String]
    /// 出た定型文の数
    var shownCount: Int

    init(_ s: GameState) {
        scene = s.scene
        flags = s.flags.sorted()
        shownCount = s.shown.count
    }
}

/// 試作プレイのログ（1回の操作を1行の JSON にする）
///
/// 保存先は、アプリの Application Support の playlogs/（サンドボックスなので、アプリのコンテナの中。
/// ~/Library/Containers/<Bundle ID>/Data/Library/Application Support/playlogs/）。
/// 起動のたびに新しいファイルを作る。入力した文とプロンプトがそのまま残るので、扱いに注意する（外部には送らない）。
/// 記録するのはデバッグ版だけ（`enabled`）。
/// このファイルは `yukemuri replay` でそのまま流し直せる。行に `expect` などを書き足すと、回帰の確かめになる。
@MainActor
final class PlayLog {
    struct Record: Encodable {
        /// input（自由文）/ move（行き先の選択）/ start（最初から）/ ui（画面の動き）
        var kind: String
        var time: Date
        var text: String?
        /// 処理の前の場面
        var sceneBefore: String?
        /// その時点の解釈の候補（台本での書き方）
        var candidates: [String]?
        var interpreted: String?
        var interpretMs: Int?
        var interpretError: String?
        /// 出た定型文の ID
        var lines: [String]
        /// 規則で起きたこと（場面の切り替え、行き先の一覧など）
        var events: [String]
        var reply: Reply?
        /// 処理の後の状態
        var after: StateSummary?

        struct Reply: Encodable {
            var speaker: String
            var text: String
            var source: String
            var milliseconds: Int
            var errors: [String]
            var problems: [String]
            /// モデルに渡した instructions
            var prompt: String?
        }
    }

    /// 記録を残すかの設定（UserDefaults のキー）。デバッグ版の既定はオンで、メニューの「開発」で切り替える
    static let enabledKey = "playLogEnabled"
    /// リリース版（配布する dmg）では記録しない（「開発」メニューがなく、止める手段がないため）
    static var enabled: Bool {
        #if DEBUG
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        #else
        false
        #endif
    }

    let url: URL?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    init() {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            url = nil
            return
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        url = base.appendingPathComponent("playlogs", isDirectory: true).appendingPathComponent("play-\(f.string(from: Date())).jsonl")
    }

    /// 保存先のフォルダ
    var directory: URL? { url?.deletingLastPathComponent() }

    func write(_ record: Record) {
        // オフのときは何も書かない（フォルダも作らない）
        guard Self.enabled, let url, let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = data + Data("\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    /// 1回の操作の結果を残す
    func record(kind: String, text: String?, before: GameState?, after: GameState?,
                candidates: [PlayerInput]? = nil, turn: SessionTurn? = nil, events: [SessionEvent], prompt: TalkPrompt? = nil) {
        var reply: Record.Reply?
        for case .reply(let speaker, let replyText, let source) in events {
            reply = Record.Reply(speaker: speaker, text: replyText, source: source.rawValue,
                                 milliseconds: turn?.reply?.milliseconds ?? 0,
                                 errors: turn?.reply?.errors ?? [], problems: turn?.reply?.problems ?? [],
                                 prompt: prompt?.instructions)
        }
        var lines: [String] = []
        var others: [String] = []
        for event in events {
            switch event {
            case .line(let line, _): lines.append(line.id)
            case .rule(let rule): others.append(Self.describe(rule))
            case .notice(let t): others.append("知らせ:\(t)")
            case .reply: break
            }
        }
        if let addressee = turn?.addressee { others.append("宛先:\(addressee)") }
        write(Record(kind: kind, time: Date(), text: text, sceneBefore: before?.scene,
                     candidates: candidates?.map(\.description), interpreted: turn?.input.description,
                     interpretMs: turn?.interpretMs, interpretError: turn?.interpretError,
                     lines: lines, events: others.filter { !$0.isEmpty }, reply: reply, after: after.map(StateSummary.init)))
    }

    static func describe(_ event: RuleEvent) -> String {
        switch event {
        case .line: ""
        case .sceneEntered(let id): "場面:\(id)"
        case .presentation(let e): "演出:\(e)"
        case .freeTalk(let who): "自由会話:\(who ?? "答える人なし")"
        case .destinationsRequested: "行き先の一覧"
        case .moveRejected(let p): "移動できない:\(p)"
        }
    }
}
