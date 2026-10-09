import Foundation
import Testing
@testable import YukemuriEngine

@Suite("ゲームの規則")
struct GameRulesTests {
    let rules: GameRules

    init() throws {
        rules = GameRules(scenario: try Fixtures.scenario())
    }

    /// 入力を順に処理して、最後の状態と、出た定型文の ID を返す
    func play(_ inputs: [PlayerInput], from state: GameState? = nil) -> (GameState, [String]) {
        var s = state ?? rules.start().state
        var ids: [String] = []
        for input in inputs {
            let step = rules.handle(input, in: s)
            ids += step.lines.map(\.id)
            s = step.state
        }
        return (s, ids)
    }

    @Test("始まりは最初の場面に入り、初回の行と、その直後の行を出す")
    func start() {
        let step = rules.start()
        #expect(step.events.first == .sceneEntered("S1"))
        #expect(step.lines.map(\.id) == ["N01", "M01"])
        #expect(step.state.scene == "S1")
    }

    @Test("次: は、その行の後の入力で、入力の中身を問わずに出る。当たる行があれば自由会話にしない")
    func nextInput() {
        let step = rules.handle(.none, in: rules.start().state)
        #expect(step.lines.map(\.id) == ["M02"])
        #expect(step.chosenLine == "M02")
        #expect(!step.events.contains(.freeTalk(respondent: "ママ")))
    }

    @Test("往復: は、起点の行から数えた入力の回数で出る")
    func turns() {
        let (_, ids) = play([.none, .none, .none])
        #expect(ids == ["M02", "M03"])
    }

    @Test("直前:と直後:の行は、その行の前後に続けて出る")
    func beforeAndAfter() {
        let (_, ids) = play([.none, .intent("ドア")])
        #expect(ids == ["M02", "D0", "D1", "D2"])
    }

    @Test("当たる行がなければ、その場の人物が自由会話で答える")
    func freeTalk() {
        let step = rules.handle(.intent("音楽"), in: play([.none, .none, .none]).0)
        #expect(step.lines.isEmpty)
        #expect(step.events == [.freeTalk(respondent: "ママ")])
    }

    @Test("移動で場面に入り、効果を適用する。戻ったときは、入るたびの行が出る")
    func move() {
        let (inBack, ids) = play([.none, .move("控え室")])
        #expect(ids == ["M02", "K01"])
        #expect(inBack.scene == "S2")
        #expect(inBack.flags == ["奥"])
        #expect(rules.presentPersons(in: inBack) == ["葵"])
        #expect(rules.respondent(in: inBack) == "葵")
        let step = rules.handle(.move("控え室"), in: play([.none]).0)
        #expect(step.events.contains(.presentation(.expression(person: "葵", name: "笑顔"))))
        let (back, again) = play([.move("店内")], from: inBack)
        #expect(back.scene == "S1")
        #expect(again == ["M05"])
    }

    @Test("別の場所へ移る入力では、今の場所の状態だけの行を出さない")
    func leavingSkipsLines() {
        let (s, ids) = play([.none, .none, .move("控え室")])
        #expect(ids == ["M02", "K01"])
        #expect(!s.shown.contains("M03"))
    }

    @Test("行けない場所は断り、離脱は行き先の一覧を出す")
    func rejectAndLeave() {
        let start = rules.start().state
        #expect(rules.handle(.move("厨房"), in: start).events.contains(.moveRejected("厨房")))
        #expect(rules.handle(.leave, in: start).events.contains(.destinationsRequested))
        // 行ける条件を満たさなければ行き先にならない
        var before = start
        before.shown.remove("M01")
        #expect(rules.destinations(in: before).isEmpty)
        #expect(rules.destinations(in: start).map(\.place) == ["控え室"])
    }

    @Test("入力の候補は結果の変わる入力だけ。答え済みの意図と、知っていることにだけ書いた意図は別に返す")
    func candidates() {
        let start = rules.start().state
        #expect(rules.inputCandidates(in: start) == [.intent("ドア"), .move("控え室"), .leave])
        #expect(rules.answeredIntents(in: start) == [.intent("音楽")])
        let (afterDoor, _) = play([.none, .intent("ドア")])
        #expect(!rules.inputCandidates(in: afterDoor).contains(.intent("ドア")))
        #expect(rules.answeredIntents(in: afterDoor).contains(.intent("ドア")))
    }

    @Test("知っていることは、条件のない行はいつも、意図: の行はその意図のときだけ入る")
    func promptKnowledge() {
        let start = rules.start().state
        #expect(rules.promptKnowledge(of: "ママ", in: start) == ["客が減っている"])
        #expect(rules.promptKnowledge(of: "ママ", in: start, input: .intent("ドア")) == ["客が減っている", "ドアは自分で選んだ"])
        #expect(rules.fallbackLine(of: "ママ", in: start)?.text == "さあね。")
    }

    @Test("その人物がもう話した台詞を返す")
    func spokenLines() {
        let (s, _) = play([.none, .intent("ドア")])
        #expect(rules.spokenLines(of: "ママ", in: s).map(\.id) == ["M01", "M02", "D1"])
        #expect(rules.spokenLines(of: "葵", in: s).map(\.id) == ["D0", "D2"])
    }

    @Test("その入力に最初に定型文で答える人物")
    func responder() {
        let start = rules.start().state
        // 次: の行は入力の中身を問わずに先に出る
        #expect(rules.responder(to: .intent("ドア"), in: start) == "ママ")
        #expect(rules.responder(to: .intent("ドア"), in: play([.none]).0) == "葵")
        #expect(rules.responder(to: .intent("音楽"), in: play([.none, .none, .none]).0) == nil)
    }

    @Test("台本での書き方から入力を作る")
    func notation() {
        #expect(PlayerInput(notation: "意図:ドア") == .intent("ドア"))
        #expect(PlayerInput(notation: "移動：控え室") == .move("控え室"))
        #expect(PlayerInput(notation: "離脱") == .leave)
        #expect(PlayerInput(notation: "なし") == PlayerInput.none)
        #expect(PlayerInput(notation: "推理:C1") == nil)
    }

    @Test("言い換えは、1回目は元の文面、その後は順に使い、一巡したら元に戻る")
    func variants() throws {
        let line = try #require(rules.scenario.scene("S1")?.lines.first { $0.id == "M05" })
        #expect((1...3).map(line.text(forTime:)) == ["おかえり。", "また来た。", "おかえり。"])
    }
}

@Suite("条件と効果の書き方")
struct ExprTests {
    @Test("+ は / より先に結びつき、! と ( ) が使える")
    func parse() throws {
        #expect(try Expr(notation: "意図:ドア + !済:M01 / 初回")
                == .or([.and([.intent("ドア"), .not(.shown("M01"))]), .firstVisit]))
        #expect(try Expr(notation: "意図:ドア + (済:M01 / 済:M02)")
                == .and([.intent("ドア"), .or([.shown("M01"), .shown("M02")])]))
        #expect(try Expr(notation: "往復:場面:3") == .turns(from: nil, n: 3))
        #expect(try Expr(notation: "往復：M01：2") == .turns(from: "M01", n: 2))
        #expect(try Expr(notation: "開始 + !初回") == .and([.enter, .not(.firstVisit)]))
    }

    @Test("読めない書き方はエラー")
    func errors() {
        #expect(throws: (any Error).self) { try Expr(notation: "推理:C1") }
        #expect(throws: (any Error).self) { try Expr(notation: "済:M01 +") }
        #expect(throws: (any Error).self) { try Expr(notation: "(済:M01") }
        #expect(throws: (any Error).self) { try Effect(notation: "動かす:葵:上") }
    }

    @Test("効果を読む")
    func effects() throws {
        #expect(try Effect(notation: "動かす:葵:左") == .moveSprite(person: "葵", position: "left"))
        #expect(try Effect(notation: "表情:ママ:笑顔") == .expression(person: "ママ", name: "笑顔"))
        #expect(try Effect(notation: "フラグ:相談") == .flag("相談"))
        #expect(try Effect(notation: "揺らす:ママ") == .shake("ママ"))
    }
}
