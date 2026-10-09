# 血の池の夜 — Apple Foundation Models の会話デモ

<img width="985" height="695" alt="Image" src="https://github.com/user-attachments/assets/445ae03d-6842-4093-98bb-a16329f2adcf" />
端末内の LLM（Apple Foundation Models）で、自由に入力した言葉に登場人物が答える、小さな会話アドベンチャーです（macOS）。

開店前のスナック「血の池」で、付き合っている葵と、店のママと一緒に、「若いお客さんにも来てもらうには？」を話します。店内ではママの意見を聞き、控え室では葵と相談します。終わりはありません。

LLM に物語を任せず、次の3つだけに使う作り方を、動くコードとテストで示します。

1. **入力の解釈**：自由な文を、台本の選択肢（話題・移動）のどれか1つに当てはめる（生成ではなく選択）
2. **自由会話**：定型文のない話題や雑談に、人物として2〜3文で返す（話題ごとの人物の考えは台本に書く）
3. **記憶の取り出し**：プレイヤーが話した自分のこと（好きな店・音楽など）を短い言葉で覚え、聞いた人の雑談に生かす

くわしくは [docs/AFMの使い方.html](docs/AFMの使い方.html) と [docs/LLMのテスト手法.html](docs/LLMのテスト手法.html) を、ブラウザで開いて読んでください。

## 動作環境

- macOS 27 以降で、Apple Intelligence を有効にした Apple シリコンの Mac
- Xcode 27 以降（Swift 6.2）

モデルを使えないとき（Apple Intelligence がオフ、モデルの準備中など）は、アプリはその理由を出して止まります。

## dmg で遊ぶ

ビルドしなくても、このリポジトリの [Releases](../../releases) にある dmg で遊べます。

1. dmg をダウンロードして開き、「血の池の夜」を「アプリケーション」へドラッグする
2. アプリを開く。**最初は macOS に止められます**（下を参照）
3. 「システム設定」→「プライバシーとセキュリティ」を開き、下のほうに出る「"血の池の夜"は開発元を確認できないため…」の横の「このまま開く」を押す。もう一度アプリを開き、確認の画面で「開く」を押す

この dmg のアプリは、Apple の公証（notarization）を受けていません（個人の Mac だけで通る仮の署名です）。そのため、初回は「開発元を確認できない」として止められます。気になる場合は、ソースから Xcode でビルドしてください（下の「遊び方」）。止められたときの画面と手順は、macOS の版で変わることがあります（2026-10-09 時点、macOS 15 以降の手順）。

dmg のアプリはリリース版のビルドで、「開発」メニューはなく、プレイの記録も残しません。入力した言葉は端末の中のモデルだけで処理し、外には送りません。

## 遊び方（ソースからビルド）

1. `UI/UI.xcodeproj` を Xcode で開き、`UI` スキームを My Mac で実行する（アプリの名前は「血の池の夜」）
2. 入力欄に話しかける（例：「あのドア、入りにくくない？」「コーヒーを出してみたら？」「控え室で話そう」）
   - Enter で送る。文字送りの途中は、Enter かスペースで次の行へ進む
   - 話し相手は、文の頭で名前を呼ぶ（「葵、〜」）か、入力欄の左のメニューで選ぶ
   - 右上の地図のアイコンで、行き先を選んで移動することもできる
   - 画面の上の札に、今いる場所と、呼び出しごと（解釈・会話・記憶）に使った文脈の大きさ／上限と使用率が出る
3. 左上のメニューの「開発」（デバッグ版のビルドだけ）から、デバッグの画面を開ける。解釈の候補、モデルが選んだもの、返事の出どころ（生成・生成し直し・定型文に戻した）、モデルに渡したプロンプト、主人公の記憶が見られる

## 手法を試せる場所

| 手法 | コード | 試し方 |
| --- | --- | --- |
| 候補から1つ選ばせる解釈（DynamicGenerationSchema の anyOf、temperature 0） | `Yukemuri/Sources/YukemuriLLM/InputInterpreter.swift` | `yukemuri eval-interpret`、デバッグの画面の「解釈」 |
| 含む語・発言例とほぼ同じ文・移動の言い方による補正 | 同上の `RefinedInterpreter` | `swift test`（InterpretTests） |
| instructions に設定と規則だけを入れ、発言と記憶は入力の側に入れる | `Yukemuri/Sources/YukemuriLLM/Talk.swift` | デバッグの画面のプロンプト、`yukemuri eval-guardrail` |
| 出力の検査（一人称・呼び方・くり返し・話題の引きずり・作品の外の言葉）と1回だけの作り直し、定型文への戻し | `Yukemuri/Sources/YukemuriLLM/SafeTalker.swift` | `swift test`（SessionTests） |
| つらさの打ち明けを規則で見つけ、相談窓口を案内する（拒否の台詞は出さない） | `Yukemuri/Sources/YukemuriLLM/GameSession.swift` | `swift test`（SessionTests） |
| 文脈の大きさの取得と、溢れたときの削り方 | `Yukemuri/Sources/YukemuriLLM/ContextBudget.swift` | メニューの「開発」で 4096 に固定して遊ぶ |
| 入力と出力の語のリストによる検査（空白を挟んだ書き方も止める） | `Yukemuri/Sources/YukemuriLLM/ContentFilter.swift` | `swift test`（ContentFilterTests） |
| 記憶の取り出しと、聞いた人だけへの反映 | `Yukemuri/Sources/YukemuriLLM/ProtagonistMemory.swift` | `yukemuri eval-memory`、控え室で葵にだけ話してから店内でママに聞く |
| LLM を使わない規則のエンジンと、台本の検査 | `Yukemuri/Sources/YukemuriEngine/` | `yukemuri validate`、`yukemuri trace` |

## コマンドとテスト

リポジトリの直下で実行します。

```sh
swift test --package-path Yukemuri                          # ユニットテスト（LLM は偽物に差し替え。モデル不要）
swift build --package-path Yukemuri
./Yukemuri/.build/debug/yukemuri validate                   # 台本の検査（モデル不要）
./Yukemuri/.build/debug/yukemuri trace 意図:メニュー 移動:控え室  # 規則だけで動かす（モデル不要）
./Yukemuri/.build/debug/yukemuri play "コーヒーを出してみたら？" "控え室で話そう"   # 実機のモデルで通しプレイ
./Yukemuri/.build/debug/yukemuri eval-interpret Yukemuri/Evaluation/interpret.json --repeat 3   # 入力の解釈の評価
./Yukemuri/.build/debug/yukemuri eval-guardrail Yukemuri/Evaluation/redteam.json        # 悪意のある入力の評価
./Yukemuri/.build/debug/yukemuri eval-memory Yukemuri/Evaluation/memory.json            # 記憶の取り出しの評価
./Yukemuri/.build/debug/yukemuri replay Yukemuri/Evaluation/replay-basic.jsonl          # 流し直し（出る定型文の照らし合わせ）
tools/regress.sh                                            # まとめて（--quick、--validate もある）
```

評価の結果は `Yukemuri/results/` に書き出します（入力文を含むので、リポジトリには入れません）。

## 構成

```
UI/                    SwiftUI のアプリ（macOS）
  UI/Resources/scenario.json   台本（データの形は docs/scenario-data-spec.md）
  UI/Resources/Graphics/       背景と人物の絵
Yukemuri/              Swift パッケージ
  Sources/YukemuriEngine/      ルールエンジン（LLM なし）
  Sources/YukemuriLLM/         入力の解釈・自由会話・記憶（Foundation Models）
  Sources/yukemuri/            検査と評価のコマンド
  Tests/                       ユニットテスト
  Evaluation/                  評価データ
docs/                  資料
tools/regress.sh       回帰の確かめ
```

## 素材

- 背景（BG15・BG18）と人物の絵（CH09・CH10）：OpenAI の画像生成モデル（GPT-image2）で作成
- 禁止語のリストの一部：[whym の Japanese bad words list](https://gist.github.com/whym/b5ac3feb2a78797c9d98)（CC0 1.0）から選んだ語
- 書体：OS の書体を使います（フォントのファイルは含みません）

## 注意

- デバッグ版のアプリは、試作プレイの記録（入力した文とプロンプト）を、アプリのコンテナの中（`~/Library/Containers/<Bundle ID>/Data/Library/Application Support/playlogs/`）に書きます。メニューの「開発」で止められます。入力の検査で止めた入力と、つらさを打ち明けた入力は、本文を残しません
- Foundation Models の API と振る舞いは、OS の版で変わることがあります。数値は 2026-10-09 時点、M4 の MacBook Air・macOS 27.0.1 での測定です

## ライセンス

[Apache License 2.0](LICENSE)
