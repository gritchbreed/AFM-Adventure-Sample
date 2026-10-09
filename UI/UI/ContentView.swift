import AppKit
import SwiftUI
import YukemuriEngine

/// プレイの画面
struct ContentView: View {
    @State private var model = GameViewModel()
    @State private var input = ""
    @FocusState private var inputFocused: Bool
    @AppStorage("textSize") private var textSize: TextSize = .small

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView("読み込んでいます……")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable(let reason):
                ContentUnavailableView("遊べません", systemImage: "exclamationmark.triangle", description: Text(reason))
            case .playing:
                stageContent
            }
        }
        .environment(\.font, AppFont.gothic(TextSize.base * textSize.scale))
        .task { await model.load() }
        .inspector(isPresented: $model.showDebug) {
            DebugView(model: model)
        }
        .sheet(isPresented: $model.showLog) {
            LogSheet(model: model, scale: textSize.scale)
        }
        .sheet(isPresented: $model.showDestinations) {
            DestinationsView(places: model.destinations.map(\.place)) { place in
                model.showDestinations = false
                if let place { Task { await model.move(to: place) } }
            }
        }
    }

    /// 舞台（16:9。余る所は黒）に、今の行のメッセージ窓を重ね、下に入力欄を置く
    private var stageContent: some View {
        VStack(spacing: 0) {
            GameStageView(model: model, scale: textSize.scale)
                .contentShape(Rectangle())
                .onTapGesture { model.advance() }
                // 入力欄の外にフォーカスがあるときも、スペース・Enter で次へ進めるようにする
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(keys: [.space, .return]) { _ in
                    guard model.isRevealing else { return .ignored }
                    model.advance()
                    return .handled
                }
                // 入力欄が使えない間も、Enter とスペースで次へ進めるように、見えないボタンに割り当てる
                .background {
                    if model.isRevealing {
                        Group {
                            Button("次へ") { model.advance() }.keyboardShortcut(.defaultAction)
                            Button("次へ") { model.advance() }.keyboardShortcut(.space, modifiers: [])
                        }
                        .opacity(0)
                        .allowsHitTesting(false)
                    }
                }
            Divider()
            footer
                .padding(12)
        }
    }

    private var footer: some View {
        HStack(alignment: .bottom) {
            // その場に2人以上いるときは、話し相手を選べる（自動なら、名前の呼びかけや話の向きで決める）
            if model.presentIDs.count >= 2 {
                Menu {
                    Button("自動") { model.addressee = nil }
                    ForEach(model.presentIDs, id: \.self) { id in
                        Button(model.displayName(id)) { model.addressee = id }
                    }
                } label: {
                    HStack(spacing: inputFontSize * 0.25) {
                        Text(model.addressee.map { model.displayName($0) } ?? "自動")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: inputFontSize * 0.6))
                    }
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(InputBarButtonStyle(fontSize: inputFontSize))
                .fixedSize()
                .disabled(model.busy)
                .help("話しかける相手。自動のときは、文の頭で呼んだ名前や話の向きで決まります")
            }
            TextField(inputPrompt, text: $input, axis: .vertical)
                .lineLimit(1...4)
                .font(AppFont.gothic(inputFontSize))
                .textFieldStyle(.plain)
                .padding(.vertical, inputFontSize * 0.3)
                .padding(.horizontal, inputFontSize * 0.45)
                .background(RoundedRectangle(cornerRadius: inputFontSize * 0.35).fill(Self.fieldBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: inputFontSize * 0.35)
                        .stroke(inputFocused && model.awaitingInput ? Color.green : Color.secondary.opacity(0.35),
                                lineWidth: inputFocused && model.awaitingInput ? 2.5 : 1)
                }
                .focusEffectDisabled()
                .focused($inputFocused)
                .onSubmit(send)
                // 入力を受け付けるようになったら、入力欄にフォーカスを戻す
                .onChange(of: model.awaitingInput) { _, ready in
                    if ready { inputFocused = true }
                }
                // 人物の台詞や地の文を出している間は、入力欄を無効にする（その間の Enter・スペースは、次の行へ進める）
                .disabled(!model.awaitingInput)
                .onKeyPress(keys: [.return, .space]) { _ in
                    guard model.isRevealing else { return .ignored }
                    model.advance()
                    return .handled
                }
            Button(action: send) { Text("送る") }
                .buttonStyle(InputBarButtonStyle(fontSize: inputFontSize, prominent: true))
                .disabled(!model.awaitingInput || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("送る（Return）")
        }
    }

    static let fieldBackground = Color(nsColor: .textBackgroundColor)

    /// 入力欄の文字の大きさ（話し相手・送るのボタンも同じ大きさにする）
    private var inputFontSize: CGFloat { TextSize.base * textSize.scale }

    private var inputPrompt: String {
        if model.isRevealing { return "話の続き（Enter かスペースで次へ）" }
        if model.busy { return "返事を待っています……" }
        return model.inputPlaceholder
    }

    private func send() {
        let text = input
        input = ""
        Task {
            await model.send(text)
            inputFocused = true
        }
    }
}

/// 絵のファイル（`Resources/Graphics/` の PNG。ID がファイル名）。一度読んだ絵は持っておく
@MainActor
enum GraphicStore {
    private static var cache: [String: Image] = [:]
    private static var missing: Set<String> = []

    static func image(_ name: String) -> Image? {
        if let image = cache[name] { return image }
        if missing.contains(name) { return nil }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
            missing.insert(name)
            return nil
        }
        let image = NSImage(contentsOf: url).map { Image(nsImage: $0) }
        if let image { cache[name] = image } else { missing.insert(name) }
        return image
    }

    /// 表情とファイル名の後ろの部分
    static let expressionSuffix = ["通常": "normal", "不安": "fear", "笑顔": "smile", "怒り": "anger", "悲しみ": "sad"]

    /// 人物の絵。その表情の絵がなければ、通常の絵
    static func sprite(_ id: String, expression: String) -> Image? {
        image("\(id)_\(expressionSuffix[expression] ?? "normal")") ?? image("\(id)_normal")
    }
}

/// 舞台（16:9 に収めて、余る所は黒）と、その上のメッセージ窓
private struct GameStageView: View {
    let model: GameViewModel
    let scale: CGFloat

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width, geo.size.height * 16 / 9)
            let size = CGSize(width: width, height: width * 9 / 16)
            ZStack(alignment: .bottom) {
                StageView(model: model)
                MessageWindow(model: model, stage: size, scale: scale)
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topTrailing) { sideButtons(size: size) }
            .overlay(alignment: .topLeading) {
                GameMenuButton(model: model, side: iconSide(size))
                    .padding(.top, iconSide(size) * 0.45)
                    .padding(.leading, iconSide(size) * 0.4)
            }
            .overlay {
                if model.showMenu {
                    GameMenuPanel(model: model, area: size, topInset: iconSide(size) * 1.75)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black)
    }

    /// 舞台の隅の丸いボタンの大きさ
    func iconSide(_ size: CGSize) -> CGFloat { max(28, size.height * 0.052) }

    /// 舞台の右上のアイコン：ログ・行き先
    func sideButtons(size: CGSize) -> some View {
        let side = iconSide(size)
        let canMove = !(model.destinations.isEmpty || model.busy)
        return VStack(spacing: side * 0.25) {
            iconButton("text.bubble", label: "ログ（⌘L）", side: side) { model.showLog = true }
                .keyboardShortcut("l", modifiers: .command)
            iconButton("map", label: "行き先", side: side, enabled: canMove) { model.showDestinations = true }
        }
        .padding(.top, side * 0.45)
        .padding(.trailing, side * 0.4)
    }

    /// - Parameter enabled: 押せないときは、丸い下地を残して記号だけを薄くする
    private func iconButton(_ symbol: String, label: String, side: CGFloat, enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: side * 0.45, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.35))
                .frame(width: side, height: side)
                .background(Circle().fill(.black.opacity(0.55)))
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// メッセージ窓：舞台の下に、今の行を1つだけ出す
///
/// 台詞は名札つきの窓を話し手の側に寄せ、地の文などは名札のない横長の窓を中央に出す。窓は3行ぶんを基本に、
/// 舞台の高さの半分まで上に伸ばし、それでも入らなければ窓の中でスクロールする。
private struct MessageWindow: View {
    let model: GameViewModel
    let stage: CGSize
    let scale: CGFloat

    private var fontSize: CGFloat { TextSize.base * scale }

    var body: some View {
        Group {
            if let entry = model.currentLine {
                window(entry)
            } else if model.busy {
                // 返事を待つ間：前の行の窓の大きさと位置のまま、左端に読み込み中の印を出す
                placed(model.previousLine, nameplate: false) {
                    ProgressView().controlSize(.small).tint(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: stage.height * 0.5, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture { model.advance() }
        .padding(.bottom, stage.height * 0.035)
        .frame(width: stage.width)
    }

    @ViewBuilder
    private func window(_ entry: LogEntry) -> some View {
        let count = model.typing?.entry.id == entry.id ? model.typing!.count : entry.text.count
        let chars = Array(entry.text)
        let font = switch entry.kind {
        case .narration: AppFont.mincho(fontSize)
        case .dialogue, .reply: AppFont.gothic(fontSize)
        default: AppFont.gothic(fontSize * 0.92)
        }
        placed(entry, nameplate: true) { text(String(chars.prefix(count)), String(chars.dropFirst(count)), font: font) }
    }

    /// 台詞は話し手の側に寄せた幅 72% の窓（名札つき）、それ以外は中央の幅 86% の窓
    @ViewBuilder
    private func placed<Content: View>(_ entry: LogEntry?, nameplate showsName: Bool, @ViewBuilder content: () -> Content) -> some View {
        switch entry?.kind {
        case .dialogue(let speaker), .reply(let speaker):
            let side = model.messageSide(of: entry?.person)
            VStack(alignment: .leading, spacing: 4) {
                if showsName { nameplate(speaker, color: PersonColor.color(model.colorName(of: entry?.person))) }
                box(content: content)
            }
            .frame(width: stage.width * 0.72)
            .frame(maxWidth: .infinity, alignment: side < 0 ? .leading : side > 0 ? .trailing : .center)
            .padding(.horizontal, stage.width * 0.04)
        default:
            box(content: content)
                .frame(width: stage.width * 0.86)
        }
    }

    /// 出していない文字も透明で置いて、行の折り返しが文字送りの途中で動かないようにする
    private func text(_ shown: String, _ hidden: String, font: Font) -> some View {
        Text("\(shown)\(Text(hidden).foregroundStyle(.clear))")
            .font(font)
            .lineSpacing(fontSize * 0.35)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 黒の半透明の箱
    private func box<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let minHeight = fontSize * 1.35 * 3 + fontSize * 0.35 * 2
        let body = content()
        return ViewThatFits(in: .vertical) {
            body.frame(minHeight: minHeight, alignment: .topLeading)
            ScrollView { body }.defaultScrollAnchor(.bottom)
        }
        .padding(.horizontal, fontSize * 1.2)
        .padding(.vertical, fontSize * 0.9)
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.28), lineWidth: 1.5))
        .overlay(alignment: .bottomTrailing) {
            if model.showsAdvanceMark {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: fontSize * 0.85))
                    .foregroundStyle(.white.opacity(0.85))
                    .symbolEffect(.pulse)
                    .padding(fontSize * 0.5)
            }
        }
    }

    /// 台詞の名札。縁の色は人物の色
    private func nameplate(_ name: String, color: Color) -> some View {
        Text(name)
            .font(AppFont.gothic(fontSize * 0.9, bold: true))
            .foregroundStyle(.white)
            .padding(.horizontal, fontSize * 1.1)
            .padding(.vertical, fontSize * 0.3)
            .background(Capsule().fill(.black.opacity(0.78)))
            .overlay(Capsule().strokeBorder(color.opacity(0.9), lineWidth: 2))
            .padding(.leading, fontSize * 0.8)
    }
}

/// 会話の記録（ログ）の画面
private struct LogSheet: View {
    let model: GameViewModel
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ログ").font(AppFont.gothic(.headline, bold: true))
                Spacer()
                Button("閉じる") { model.showLog = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            LogView(entries: model.log, scale: scale, colorName: model.colorName(of:))
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 480, idealHeight: 640)
    }
}

/// 舞台：16:9 の背景に、腰から上の人物の絵を重ねる
private struct StageView: View {
    let model: GameViewModel

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let width = min(geo.size.width, height * 16 / 9)
            ZStack(alignment: .bottom) {
                background
                ForEach(model.stage.people) { person in
                    SpriteView(person: person, sprite: model.sprite(of: person.id), name: model.displayName(person.id),
                               height: height * GameViewModel.spriteHeightRatio)
                        .offset(x: xOffset(of: person, width: width))
                        .transition(.opacity)
                }
            }
            .frame(width: width, height: height)
            .overlay(alignment: .top) { placeLabel }
            .clipped()
            .frame(maxWidth: .infinity)
        }
        .background(.black)
    }

    @ViewBuilder
    private var background: some View {
        if let id = model.stage.background, let image = GraphicStore.image(id) {
            image.resizable().scaledToFill()
                .transition(.opacity)
                .id(id)
        } else {
            Rectangle().fill(.black)
        }
    }

    /// 場所の名前と、呼び出しごとに使った文脈の大きさ
    private var placeLabel: some View {
        Text([model.stage.place, model.contextUsageText].compactMap { $0 }.joined(separator: " ・ "))
            .font(AppFont.gothic(.caption, bold: true))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.35), in: Capsule())
            .padding(8)
            .opacity(model.stage.place == nil ? 0 : 1)
    }

    /// 人物の横の位置（`動かす:` の指定があればそれ。なければ、ほかの人物と並ぶ相棒は右、それ以外は左）
    private func xOffset(of person: Stage.Person, width: CGFloat) -> CGFloat {
        let partner = model.rules?.scenario.partner
        let fraction: CGFloat
        switch person.position {
        case "left": fraction = 0.18
        case "center": fraction = 0.5
        case "right": fraction = 0.82
        default:
            if model.isPartnerOnRight(person.id) {
                fraction = 0.82
            } else {
                let others = model.stage.people.filter { $0.id != partner }
                let i = CGFloat(others.firstIndex { $0.id == person.id } ?? 0)
                let n = CGFloat(others.count)
                fraction = n <= 1 ? 0.18 : 0.14 + 0.18 * i / (n - 1)
            }
        }
        return (fraction - 0.5) * width
    }
}

/// 人物の絵（表情の切り替えはフェード、揺らすは左右に短く振る）
private struct SpriteView: View {
    let person: Stage.Person
    let sprite: String?
    let name: String
    let height: CGFloat

    var body: some View {
        ZStack {
            if let sprite, let image = GraphicStore.sprite(sprite, expression: person.expression) {
                image.resizable().scaledToFit()
                    .id(person.expression)
                    .transition(.opacity)
            } else {
                // 絵のファイルがない人物
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .overlay { Text("\(name)\n\(person.expression)").foregroundStyle(.white).multilineTextAlignment(.center) }
                    .aspectRatio(1400 / 1800, contentMode: .fit)
            }
        }
        .frame(height: height)
        .keyframeAnimator(initialValue: CGFloat(0), trigger: person.shakes) { content, x in
            content.offset(x: x)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-14, duration: 0.05)
                LinearKeyframe(14, duration: 0.07)
                LinearKeyframe(-10, duration: 0.07)
                LinearKeyframe(8, duration: 0.07)
                LinearKeyframe(0, duration: 0.06)
            }
        }
    }
}

/// 人物の色（台本の `color` の名前を、画面の色にする。システムの色なので、ダークモードでも見やすい）
enum PersonColor {
    static func color(_ name: String?) -> Color {
        switch name {
        case "青": .blue
        case "緑": .green
        case "橙": .orange
        case "紫": .purple
        case "桃": .pink
        case "赤": .red
        default: .gray
        }
    }
}

/// 文字の大きさ（設定に残す）
enum TextSize: String, CaseIterable {
    case small, medium, large

    /// 本文の大きさの基準（ポイント）。実際の大きさは、これに scale を掛けたもの
    static let base: CGFloat = 13

    var scale: CGFloat {
        switch self {
        case .small: 1.25
        case .medium: 1.5
        case .large: 1.8
        }
    }

    /// 一段大きい・小さい大きさ（端ならそのまま）
    var larger: TextSize { Self.allCases.drop { $0 != self }.dropFirst().first ?? self }
    var smaller: TextSize { Self.allCases.reversed().drop { $0 != self }.dropFirst().first ?? self }

    var label: String {
        switch self {
        case .small: "小"
        case .medium: "中"
        case .large: "大"
        }
    }
}

/// 記録（地の文・台詞・入力・知らせ）。ログの画面に出す
private struct LogView: View {
    let entries: [LogEntry]
    let scale: CGFloat
    let colorName: (String?) -> String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(entries) { entry in
                    EntryRow(entry: entry, scale: scale, theme: PersonColor.color(colorName(entry.person)))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
    }
}

private struct EntryRow: View {
    let entry: LogEntry
    var scale: CGFloat = 1
    /// 話し手の色
    var theme: Color = .gray

    private func size(_ ratio: CGFloat = 1) -> CGFloat { TextSize.base * scale * ratio }

    var body: some View {
        switch entry.kind {
        case .narration:
            // 地の文は、吹き出しなしで、左に罫線を引いて本の地の文のように出す
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.secondary.opacity(0.35))
                    .frame(width: 3)
                Text(entry.text)
                    .font(AppFont.mincho(size()))
                    .lineSpacing(4 * scale)
                    .foregroundStyle(.primary.opacity(0.85))
            }
            .padding(.vertical, 2)
        case .dialogue(let speaker), .reply(let speaker):
            VStack(alignment: .leading, spacing: 4) {
                Text(speaker).font(AppFont.gothic(size(0.8), bold: true)).foregroundStyle(theme)
                Text(entry.text)
                    .font(AppFont.gothic(size()))
                    .lineSpacing(2 * scale)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.opacity(0.35), lineWidth: 1))
            }
        case .player:
            Text(entry.text)
                .font(AppFont.gothic(size()))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.green.opacity(0.35), lineWidth: 1))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .system:
            Text(entry.text)
                .font(AppFont.gothic(size(0.8)))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// 行き先の一覧の窓。行き先を押すとそこへ移り、「閉じる」で何もせずに閉じる
private struct DestinationsView: View {
    let places: [String]
    /// 選んだ行き先（閉じたときは nil）
    let choose: (String?) -> Void
    @AppStorage("textSize") private var textSize: TextSize = .small

    var body: some View {
        VStack(spacing: 14) {
            Text("行き先")
                .font(AppFont.gothic(TextSize.base * textSize.scale, bold: true))
            VStack(spacing: 10) {
                ForEach(places, id: \.self) { place in
                    Button { choose(place) } label: {
                        Text(place).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            Divider()
            Button(role: .cancel) { choose(nil) } label: {
                Label("閉じる", systemImage: "xmark").frame(maxWidth: .infinity)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.bordered)
            .tint(.gray)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
        }
        .font(AppFont.gothic(TextSize.base * textSize.scale))
        .padding(20)
        .frame(minWidth: 280, maxWidth: 360)
        .presentationDetents([.medium])
    }
}

/// 入力欄の横のボタン（話し相手・送る）。入力欄と同じ大きさの文字にする
struct InputBarButtonStyle: ButtonStyle {
    var fontSize: CGFloat
    /// 送るボタンのように、色を付けて目立たせる
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        InputBarButtonLabel(configuration: configuration, fontSize: fontSize, prominent: prominent)
    }
}

private struct InputBarButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let fontSize: CGFloat
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(AppFont.gothic(fontSize))
            .padding(.horizontal, fontSize * 0.6)
            .padding(.vertical, fontSize * 0.3)
            .background(
                RoundedRectangle(cornerRadius: fontSize * 0.35)
                    .fill(prominent ? Color.accentColor.opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
                                    : Color.secondary.opacity(configuration.isPressed ? 0.3 : 0.15))
            )
            .foregroundStyle(prominent ? Color.white : (isEnabled ? Color.primary : Color.secondary))
            .contentShape(Rectangle())
    }
}

#Preview {
    ContentView()
}
