import AppKit
import SwiftUI
import YukemuriEngine

/// デバッグの画面（今の状態と、直前の解釈・返事・プロンプトを見る）
///
/// AFM の手法を確かめるときに使う：解釈の候補（選択肢）、モデルが選んだもの、返事の出どころ（生成・生成し直し・定型文に戻した）、
/// 検査で見つかった問題、実際にモデルに渡した instructions。
struct DebugView: View {
    let model: GameViewModel

    var body: some View {
        List {
            if let s = model.debugSummary {
                Section("状態") {
                    row("場面", s.scene ?? "-")
                    row("背景", model.scene?.background ?? "-")
                    row("その場の人物", model.people.joined(separator: "、"))
                    row("出た定型文", "\(s.shownCount) 行")
                    if !s.flags.isEmpty { row("フラグ", s.flags.joined(separator: "、")) }
                }
            }
            Section("モデル") {
                row("文脈の大きさ", model.contextDescription)
            }
            Section("主人公の記憶（\(model.memory.count)）") {
                if model.memory.isEmpty {
                    Text("なし").foregroundStyle(.secondary)
                }
                ForEach(model.memory, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
            }
            Section("今の解釈の候補（\(model.debugCandidates.count)）") {
                chips(model.debugCandidates)
            }
            if let t = model.lastTurn {
                Section("直前の入力") {
                    Text(t.text).textSelection(.enabled)
                    row("解釈", t.interpreted)
                    row("解釈の時間", "\(t.interpretMs) ms")
                    if let e = t.interpretError { row("解釈のエラー", e) }
                    row("定型文", t.lines.isEmpty ? "なし" : t.lines.joined(separator: "、"))
                    if let source = t.replySource {
                        row("返事", source == "generated" ? "生成" : source == "regenerated" ? "生成し直し" : "定型文に戻した")
                        row("返事の時間", "\(t.replyMs ?? 0) ms")
                        if !t.replyErrors.isEmpty { row("エラー", t.replyErrors.joined(separator: "、")) }
                        if !t.replyProblems.isEmpty { row("検査の問題", t.replyProblems.joined(separator: "、")) }
                    }
                }
            }
            if let prompt = model.lastPrompt {
                Section("最後にモデルに渡したプロンプト") {
                    Text(prompt)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            Section("ログ") {
                if let url = model.playLog.url {
                    Text(url.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button("Finder で開く") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } else {
                    Text("ログを書けません")
                }
            }
        }
        .frame(minWidth: 280)
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).textSelection(.enabled)
        }
    }

    private func chips(_ items: [String]) -> some View {
        Text(items.isEmpty ? "なし" : items.joined(separator: "  "))
            .font(.callout.monospaced())
            .textSelection(.enabled)
    }
}
