import SwiftUI

/// 書体（OS の日本語の書体を使う。フォントのファイルはアプリに入れない）
///
/// 地の文は明朝体、それ以外はゴシック体。
enum AppFont {
    static func gothic(_ size: CGFloat, bold: Bool = false) -> Font {
        .system(size: size, weight: bold ? .bold : .regular)
    }

    static func mincho(_ size: CGFloat, bold: Bool = false) -> Font {
        .system(size: size, weight: bold ? .bold : .regular, design: .serif)
    }

    /// 文字の種類（`.caption` など）の大きさのゴシック体。OS の文字の大きさの設定に合わせて変わる
    static func gothic(_ style: Font.TextStyle, bold: Bool = false) -> Font {
        .system(style, weight: bold ? .bold : .regular)
    }
}
