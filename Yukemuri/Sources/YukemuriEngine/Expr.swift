import Foundation

/// 条件式
///
/// 台本の JSON では文字列で書く（「意図:赤いドア + !済:M01」など）。書き方は docs/scenario-data-spec.md の表のとおり。
/// `+` は「かつ」、`/` は「または」（`+` のほうが先に結びつく）、`!` は否定、`( )` でまとめる。
public indirect enum Expr: Sendable, Hashable {
    case and([Expr])
    case or([Expr])
    case not(Expr)
    /// 常に
    case always
    /// 初回（初めてこの場面に入ったとき）
    case firstVisit
    /// 開始（この場面に入るたび）
    case enter
    /// 済:定型文
    case shown(String)
    /// 場所:今いる場所
    case place(String)
    case flag(String)
    /// 直後:定型文
    case after(String)
    /// 次:定型文（その定型文の後の、次の入力）
    case next(String)
    /// 直前:定型文
    case before(String)
    /// 往復:起点:回数（起点が nil なら場面の始まりから）
    case turns(from: String?, n: Int)
    // 入力の条件
    case intent(String)
    case move(String)
    case leave

    /// 入力の条件か
    public var isInputAtom: Bool {
        switch self {
        case .next, .intent, .move, .leave: true
        default: false
        }
    }

    /// 式に含まれる原子（and・or・not を除いたもの）
    public var atoms: [Expr] {
        switch self {
        case .and(let items), .or(let items): items.flatMap(\.atoms)
        case .not(let item): item.atoms
        default: [self]
        }
    }

    /// 入力の条件を含むか
    public var containsInput: Bool { atoms.contains(where: \.isInputAtom) }

    /// この原子に当たる入力（入力の条件でなければ nil。`次:` は入力の中身を問わないので nil）
    public var matchingInput: PlayerInput? {
        switch self {
        case .intent(let id): .intent(id)
        case .move(let id): .move(id)
        case .leave: .leave
        default: nil
        }
    }
}

public enum ExprParseError: Error, CustomStringConvertible {
    case unexpected(String, in: String)
    case unknownAtom(String)

    public var description: String {
        switch self {
        case .unexpected(let token, let source): "条件「\(source)」の「\(token)」が読めない"
        case .unknownAtom(let atom): "未知の条件「\(atom)」"
        }
    }
}

extension Expr {
    /// 書き方から作る
    public init(notation: String) throws {
        var parser = ExprParser(source: notation)
        self = try parser.parse()
    }

    /// 原子1つ（「済:M01」「離脱」など）
    static func atom(_ raw: String) throws -> Expr {
        let s = raw.replacingOccurrences(of: "：", with: ":").trimmingCharacters(in: .whitespaces)
        switch s {
        case "常に": return .always
        case "初回": return .firstVisit
        case "開始": return .enter
        case "離脱": return .leave
        default: break
        }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[1].isEmpty else { throw ExprParseError.unknownAtom(s) }
        let value = parts[1]
        switch parts[0] {
        case "済": return .shown(value)
        case "場所": return .place(value)
        case "フラグ": return .flag(value)
        case "直後": return .after(value)
        case "次": return .next(value)
        case "直前": return .before(value)
        case "意図": return .intent(value)
        case "移動": return .move(value)
        case "往復":
            guard parts.count == 3, let n = Int(parts[2]) else { throw ExprParseError.unknownAtom(s) }
            return .turns(from: value == "場面" ? nil : value, n: n)
        default: throw ExprParseError.unknownAtom(s)
        }
    }
}

/// 条件の書き方の読み取り（`/` < `+` < `!` の順に強く結びつく）
private struct ExprParser {
    let source: String
    var tokens: [String] = []
    var i = 0

    init(source: String) {
        self.source = source
        var current = ""
        for c in source {
            if "+/!()".contains(c) {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { tokens.append(t) }
                current = ""
                tokens.append(String(c))
            } else {
                current.append(c)
            }
        }
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { tokens.append(t) }
    }

    mutating func parse() throws -> Expr {
        let e = try parseOr()
        guard i == tokens.count else { throw ExprParseError.unexpected(tokens[i], in: source) }
        return e
    }

    mutating func parseOr() throws -> Expr {
        var items = [try parseAnd()]
        while i < tokens.count, tokens[i] == "/" {
            i += 1
            items.append(try parseAnd())
        }
        return items.count == 1 ? items[0] : .or(items)
    }

    mutating func parseAnd() throws -> Expr {
        var items = [try parseUnary()]
        while i < tokens.count, tokens[i] == "+" {
            i += 1
            items.append(try parseUnary())
        }
        return items.count == 1 ? items[0] : .and(items)
    }

    mutating func parseUnary() throws -> Expr {
        guard i < tokens.count else { throw ExprParseError.unexpected("（終わり）", in: source) }
        let t = tokens[i]
        i += 1
        switch t {
        case "!": return .not(try parseUnary())
        case "(":
            let e = try parseOr()
            guard i < tokens.count, tokens[i] == ")" else { throw ExprParseError.unexpected(i < tokens.count ? tokens[i] : "（終わり）", in: source) }
            i += 1
            return e
        case "+", "/", ")": throw ExprParseError.unexpected(t, in: source)
        default: return try Expr.atom(t)
        }
    }
}

extension Expr: Decodable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        do {
            self = try Expr(notation: s)
        } catch {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "\(error)")
        }
    }
}

/// 効果（台本の JSON では「フラグ:名前」「揺らす:人物」などの文字列で書く）
public enum Effect: Sendable, Hashable {
    case flag(String)
    /// 人物が場に現れる・去る（場面を移ると元に戻る）
    case enterPerson(String)
    case exitPerson(String)
    // 演出（状態を変えない）
    case shake(String)
    /// 人物の位置を変える（left・center・right）
    case moveSprite(person: String, position: String)
    /// 人物の表情を変える（通常・不安・笑顔・怒り・悲しみ）
    case expression(person: String, name: String)

    /// 状態を変える効果か
    public var changesState: Bool {
        switch self {
        case .flag, .enterPerson, .exitPerson: true
        case .shake, .moveSprite, .expression: false
        }
    }

    public init(notation: String) throws {
        let parts = notation.replacingOccurrences(of: "：", with: ":").split(separator: ":").map(String.init)
        let positions = ["左": "left", "中央": "center", "右": "right"]
        switch (parts.first, parts.count) {
        case ("フラグ", 2): self = .flag(parts[1])
        case ("登場", 2): self = .enterPerson(parts[1])
        case ("退場", 2): self = .exitPerson(parts[1])
        case ("揺らす", 2): self = .shake(parts[1])
        case ("動かす", 3):
            guard let p = positions[parts[2]] else { throw ExprParseError.unknownAtom(notation) }
            self = .moveSprite(person: parts[1], position: p)
        case ("表情", 3): self = .expression(person: parts[1], name: parts[2])
        default: throw ExprParseError.unknownAtom(notation)
        }
    }
}

extension Effect: Decodable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        do {
            self = try Effect(notation: s)
        } catch {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "未知の効果「\(s)」")
        }
    }
}
