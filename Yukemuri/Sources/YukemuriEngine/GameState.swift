import Foundation

/// プレイヤーの入力1回の解釈
///
/// 1回の入力に当たるのは1つだけ。どれにも当たらなければ `.none`（自由会話になる）。
public enum PlayerInput: Sendable, Hashable, CustomStringConvertible {
    case none
    case intent(String)
    case move(String)
    case leave

    /// 台本での書き方
    public var description: String {
        switch self {
        case .none: "なし"
        case .intent(let id): "意図:\(id)"
        case .move(let id): "移動:\(id)"
        case .leave: "離脱"
        }
    }

    /// 台本での書き方から作る（「なし」は .none）。読めなければ nil
    public init?(notation: String) {
        let s = notation.replacingOccurrences(of: "：", with: ":")
        switch s {
        case "なし": self = .none; return
        case "離脱": self = .leave; return
        default: break
        }
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let kind = String(s[..<colon])
        let value = String(s[s.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        switch kind {
        case "意図": self = .intent(value)
        case "移動": self = .move(value)
        default: return nil
        }
    }
}

/// ゲームの状態
///
/// 主人公の記憶と会話の履歴はエンジンの外（GameSession）で持つ。
public struct GameState: Sendable, Hashable, Codable {
    /// 今いる場面
    public var scene: String?
    public var flags: Set<String> = []
    /// 出た定型文
    public var shown: Set<String> = []
    /// 入った場面
    public var visited: Set<String> = []
    /// 効果で現れた・去った人物（場面を移ると元に戻る）
    public var personsAdded: Set<String> = []
    public var personsRemoved: Set<String> = []
    /// 場面に入ってからの入力の回数（条件に書いた数で止める）
    public var sceneTurns = 0
    /// 定型文を出してからの入力の回数（往復の起点になる定型文だけ。条件に書いた数で止める）
    public var turnsSince: [String: Int] = [:]
    /// 前の入力の処理で出た定型文（`次:` の判定に使う）
    public var lastTurnLines: Set<String> = []
    /// 今の入力の処理で出ている定型文
    public var currentTurnLines: Set<String> = []

    public init() {}
}
