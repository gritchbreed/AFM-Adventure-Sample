#!/bin/sh
# 回帰の確かめ（リポジトリの直下で実行する）
#
#   tools/regress.sh             検査・ユニットテスト・解釈の評価・流し直し（実機のモデルを使う。数分かかる）
#   tools/regress.sh --quick     検査・ユニットテスト・流し直しだけ
#   tools/regress.sh --validate  検査とユニットテストだけ（LLM を使わない）
#
# 生成した文は照らし合わせない。照らし合わせるのは、台本の参照・到達可能性、選んだ選択肢、出た定型文の ID だけ。
# 悪意のある入力（eval-guardrail）と記憶（eval-memory）は、結果を人が読んで判断するので、ここには入れない。
set -e
cd "$(dirname "$0")/.."

MODE="${1:-full}"
swift build --package-path Yukemuri -q
Y=./Yukemuri/.build/debug/yukemuri

echo "== 台本の検査"
$Y validate

echo "== ユニットテスト"
swift test --package-path Yukemuri -q

[ "$MODE" = "--validate" ] && exit 0

if [ "$MODE" != "--quick" ]; then
  echo "== 入力の解釈の評価"
  $Y eval-interpret Yukemuri/Evaluation/interpret.json | grep -E "^NG|^SKIP|正解率|時間"
  $Y eval-interpret Yukemuri/Evaluation/interpret-injection.json | grep -E "^NG|^SKIP|正解率"
fi

echo "== 流し直し"
for f in Yukemuri/Evaluation/replay-*.jsonl; do
  echo "-- $f"
  $Y replay "$f" | grep -E "照らし合わせ|^  NG"
done
