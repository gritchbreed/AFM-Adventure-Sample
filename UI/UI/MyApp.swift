import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        Window("血の池の夜", id: "main") {
            ContentView()
        }
        .commands { TextSizeCommands() }
    }
}

/// 「表示」のメニューに、文字の大きさを変える項目（⌘＋・⌘−）を足す
struct TextSizeCommands: Commands {
    @AppStorage("textSize") private var textSize: TextSize = .small

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("文字を大きく（\(textSize.larger.label)）") { textSize = textSize.larger }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(textSize == textSize.larger)
            Button("文字を小さく（\(textSize.smaller.label)）") { textSize = textSize.smaller }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(textSize == textSize.smaller)
        }
    }
}
