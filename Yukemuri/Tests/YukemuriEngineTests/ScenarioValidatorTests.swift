import Foundation
import Testing
@testable import YukemuriEngine

@Suite("台本の検査")
struct ScenarioValidatorTests {
    @Test("テスト用の台本は、エラーも出ない定型文もない")
    func valid() throws {
        let report = ScenarioValidator().validate(try Fixtures.scenario())
        #expect(report.errors.isEmpty)
        #expect(report.warnings.isEmpty)
        #expect(report.stateCount > 1)
    }

    @Test("ない定型文・意図・人物・場所を参照していたら報告する")
    func references() throws {
        let scenario = try Fixtures.scenario {
            $0.replacingOccurrences(of: #""condition": "直前:D1""#, with: #""condition": "直前:D9""#)
                .replacingOccurrences(of: #""condition": "意図:音楽""#, with: #""condition": "意図:天気""#)
                .replacingOccurrences(of: #""speaker": "葵", "condition": "直後:D1""#, with: #""speaker": "店長", "condition": "直後:D1""#)
                .replacingOccurrences(of: #""can_enter": "済:M01""#, with: #""can_enter": "場所:厨房""#)
        }
        let errors = ScenarioValidator().validate(scenario).errors
        #expect(errors.contains("D0：定型文 D9 がない"))
        #expect(errors.contains("K02：意図 天気 がない"))
        #expect(errors.contains("D2：話者 店長 がない"))
        #expect(errors.contains("場面 S2 の行ける条件：場所 厨房 がない"))
    }

    @Test("定型文の ID が重なっていたら報告する")
    func duplicates() throws {
        let scenario = try Fixtures.scenario { $0.replacingOccurrences(of: #""id": "K02""#, with: #""id": "K01""#) }
        #expect(ScenarioValidator().validate(scenario).errors.contains("定型文の ID K01 が重なっている"))
    }

    @Test("どの入力でも出ない定型文を警告する")
    func unreachable() throws {
        let scenario = try Fixtures.scenario {
            $0.replacingOccurrences(of: #""condition": "意図:音楽""#, with: #""condition": "意図:音楽 + フラグ:立たない""#)
        }
        let report = ScenarioValidator().validate(scenario)
        #expect(report.errors.isEmpty)
        #expect(report.warnings == ["出ない定型文 K02（場面 S2）"])
    }
}
