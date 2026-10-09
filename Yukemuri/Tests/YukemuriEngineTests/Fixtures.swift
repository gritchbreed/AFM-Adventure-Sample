import Foundation
@testable import YukemuriEngine

/// テスト用の小さな台本
///
/// 店内：初回の地の文 → 直後のママの台詞 → 次の入力で M02、3往復で M03。ドアの意図で、直前・直後の葵の台詞をはさむ
/// 控え室：M01 の後に行ける。初回の地の文でフラグと表情。音楽の意図で葵が答える
enum Fixtures {
    static let json = #"""
    {
     "spec_version": 1,
     "protagonist": {"name": "吉永", "rules": ["主人公の見た目には触れない"]},
     "partner": "葵",
     "place_aliases": {"控え室": ["奥"]},
     "intents": [
      {"id": "ドア", "description": "ドアの話", "examples": ["ドアは？"], "words": ["ドア"]},
      {"id": "音楽", "description": "音楽の話", "examples": ["曲は？"]}
     ],
     "persons": [
      {"id": "ママ", "knowledge": [{"info": "客が減っている"}, {"info": "ドアは自分で選んだ", "condition": "意図:ドア"}],
       "fallbacks": [{"id": "ママ-拒1", "text": "さあね。"}]},
      {"id": "葵", "knowledge": [{"info": "映画音楽が好き", "condition": "意図:音楽"}]}
     ],
     "scenes": [
      {"id": "S1", "place": "店内", "person": "ママ", "free_talk": {"ママ": ["グラスを拭きながら話す"]},
       "lines": [
        {"id": "N01", "condition": "初回", "text": "店に戻った。"},
        {"id": "M01", "speaker": "ママ", "condition": "直後:N01", "text": "おかえり、{名前}さん。"},
        {"id": "M02", "speaker": "ママ", "condition": "次:M01", "text": "何食べてきたの？"},
        {"id": "M03", "speaker": "ママ", "condition": "往復:M01:3", "text": "そういえば、相談があるの。"},
        {"id": "D1", "speaker": "ママ", "condition": "意図:ドア", "text": "あのドアがいいのよ。"},
        {"id": "D0", "speaker": "葵", "condition": "直前:D1", "text": "ドアの話？"},
        {"id": "D2", "speaker": "葵", "condition": "直後:D1", "text": "私は好き。"},
        {"id": "M05", "speaker": "ママ", "condition": "開始 + !初回", "repeatable": true, "text": "おかえり。", "variants": ["また来た。"]}
       ]},
      {"id": "S2", "place": "控え室", "can_enter": "済:M01",
       "lines": [
        {"id": "K01", "condition": "初回", "text": "控え室に入った。", "effects": ["フラグ:奥", "表情:葵:笑顔"]},
        {"id": "K02", "speaker": "葵", "condition": "意図:音楽", "text": "映画音楽がいい。"}
       ]}
     ]
    }
    """#

    /// 台本を読む（`edit` で JSON の文字列を書き換えてから読む）
    static func scenario(_ edit: (String) -> String = { $0 }) throws -> Scenario {
        try Scenario.load(from: Data(edit(json).utf8))
    }
}
