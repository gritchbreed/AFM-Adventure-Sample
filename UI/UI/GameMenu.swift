import AppKit
import SwiftUI

/// 画面内のメニュー
///
/// 舞台の左上のメニューボタンから、舞台の中に開く板。左の列で分類を選び、右の列でその分類の項目を変える。
/// 「開発」（デバッグの画面、文脈の大きさの固定など）は、デバッグ版のビルドだけに出す。

/// 左上のメニューボタン（右上のアイコンと同じ丸い下地）
struct GameMenuButton: View {
    let model: GameViewModel
    let side: CGFloat

    var body: some View {
        Button {
            model.showMenu.toggle()
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: side * 0.45, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: side, height: side)
                .background(Circle().fill(.black.opacity(0.55)))
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("メニュー")
        .accessibilityLabel("メニュー")
    }
}

/// メニューの板。`area` は板を重ねる範囲（舞台）
struct GameMenuPanel: View {
    let model: GameViewModel
    let area: CGSize
    /// 板の上端の位置（メニューボタンの下）
    let topInset: CGFloat

    @AppStorage("textSize") private var textSize: TextSize = .small
    @AppStorage(GameViewModel.autoAdvanceKey) private var autoAdvance = true
    @AppStorage(PlayLog.enabledKey) private var playLogEnabled = true
    @AppStorage(GameViewModel.contextKey) private var contextSetting = 0
    @State private var category: Category = .text
    @State private var hovered: String?

    enum Category: String, CaseIterable, Identifiable {
        case text = "文字", game = "ゲーム", dev = "開発"
        var id: String { rawValue }
    }

    /// 項目の行
    enum Item: Identifiable {
        case toggle(String, Bool, () -> Void)
        case choice(String, Bool, () -> Void)
        case action(String, () -> Void)
        case header(String)

        var id: String {
            switch self {
            case .toggle(let t, _, _), .choice(let t, _, _), .action(let t, _), .header(let t): t
            }
        }
    }

    private var fontSize: CGFloat { TextSize.base * textSize.scale * 0.9 }

    /// 出す分類（開発はデバッグ版のビルドだけ）
    private var categories: [Category] {
        Category.allCases.filter { c in
            #if DEBUG
            return true
            #else
            return c != .dev
            #endif
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 板の外を押すと閉じる
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            panel
                .padding(.top, topInset)
                .padding(.leading, fontSize * 0.8)
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
    }

    private var panel: some View {
        HStack(alignment: .top, spacing: 0) {
            column(width: fontSize * 6.5) {
                ForEach(categories) { c in
                    row(id: "c-\(c.rawValue)", selected: c == category, showsArrow: true) {
                        Text(c.rawValue)
                    } action: { category = c }
                }
            }
            Rectangle().fill(.white.opacity(0.35)).frame(width: 1)
                .padding(.vertical, fontSize * 0.4)
                .frame(maxHeight: .infinity)
            ViewThatFits(in: .vertical) {
                itemColumn
                ScrollView { itemColumn }
                    .scrollIndicators(.hidden)
            }
            .frame(maxHeight: area.height - topInset - fontSize * 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(fontSize * 0.4)
        .background(RoundedRectangle(cornerRadius: fontSize * 0.6).fill(.black.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: fontSize * 0.6).strokeBorder(.white.opacity(0.7), lineWidth: 2))
        .overlay(alignment: .topTrailing) {
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: fontSize * 0.6, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(fontSize * 0.35)
            }
            .buttonStyle(.plain)
            .help("閉じる")
        }
        .shadow(color: .black.opacity(0.5), radius: 8)
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var itemColumn: some View {
        column(width: fontSize * 17) {
            ForEach(items(for: category)) { item in itemRow(item) }
        }
    }

    private func column<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(width: width, alignment: .leading)
            .padding(.vertical, fontSize * 0.2)
    }

    @ViewBuilder
    private func itemRow(_ item: Item) -> some View {
        switch item {
        case .header(let title):
            Text(title)
                .font(AppFont.gothic(fontSize * 0.75, bold: true))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, fontSize * 0.6)
                .padding(.top, fontSize * 0.5)
                .padding(.bottom, fontSize * 0.15)
        case .toggle(let title, let isOn, let action):
            row(id: title, selected: false, label: {
                Text(title)
                Spacer(minLength: fontSize)
                Text(isOn ? "オン" : "オフ")
                    .foregroundStyle(isOn ? Color.green : Color.white.opacity(0.5))
            }, action: action)
        case .choice(let title, let isOn, let action):
            row(id: title, selected: false, label: {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: fontSize * 0.7))
                    .foregroundStyle(isOn ? Color.green : Color.white.opacity(0.5))
                Text(title)
            }, action: action)
        case .action(let title, let action):
            row(id: title, selected: false) {
                Text(title)
                Spacer(minLength: fontSize)
                Image(systemName: "chevron.right")
                    .font(.system(size: fontSize * 0.6))
                    .foregroundStyle(.white.opacity(0.5))
            } action: {
                close()
                action()
            }
        }
    }

    /// 1行。選んでいる行（分類）は、白い角丸で光らせ、黒い文字にする。マウスを乗せた行は薄く明るくする
    private func row<Label: View>(id: String, selected: Bool, showsArrow: Bool = false,
                                  @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: fontSize * 0.4) {
                if showsArrow {
                    Image(systemName: "play.fill")
                        .font(.system(size: fontSize * 0.45))
                        .opacity(selected ? 1 : 0)
                }
                label()
            }
            .font(AppFont.gothic(fontSize))
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(.horizontal, fontSize * 0.6)
            .padding(.vertical, fontSize * 0.35)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: fontSize * 0.5)
                    .fill(selected ? Color.white : Color.white.opacity(hovered == id ? 0.12 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
    }

    private func close() {
        model.showMenu = false
    }

    // MARK: - 項目

    private func items(for category: Category) -> [Item] {
        switch category {
        case .text:
            return [.header("文字の大きさ")]
                + TextSize.allCases.map { size in Item.choice(size.label, textSize == size) { textSize = size } }
                + [.toggle("オート（自動で次の行へ）", autoAdvance) { autoAdvance.toggle() }]
        case .game:
            return [.action("最初から") { Task { await model.restart() } }]
        case .dev:
            var list: [Item] = [.action("デバッグの画面") { model.showDebug.toggle() }]
            list.append(.header("文脈の大きさ"))
            for (title, value) in [("自動", 0), ("4096 に固定", 4096), ("8192 に固定", 8192)] {
                list.append(.choice(title, contextSetting == value) {
                    contextSetting = value
                    Task { await model.applyContextSetting() }
                })
            }
            list.append(.toggle("プレイの記録を残す", playLogEnabled) { playLogEnabled.toggle() })
            list.append(.action("ログの場所を開く") {
                if let dir = model.playLog.directory { NSWorkspace.shared.open(dir) }
            })
            return list
        }
    }
}
