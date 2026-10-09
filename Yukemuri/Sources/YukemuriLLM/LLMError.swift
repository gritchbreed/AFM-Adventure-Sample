import Foundation
import FoundationModels

/// モデルの利用可否
public enum ModelAvailability: Sendable, Equatable {
    case available
    /// 端末非対応
    case deviceNotEligible
    /// Apple Intelligence 無効
    case appleIntelligenceNotEnabled
    /// モデル準備中（ダウンロード中など）
    case modelNotReady
    case other(String)

    public var isAvailable: Bool { self == .available }

    /// 画面・ログ向けの説明
    public var reasonText: String {
        switch self {
        case .available: "利用可能"
        case .deviceNotEligible: "この端末は Apple Intelligence に対応していません"
        case .appleIntelligenceNotEnabled: "Apple Intelligence が有効になっていません（システム設定で有効にしてください）"
        case .modelNotReady: "モデルの準備中です（ダウンロード完了までお待ちください）"
        case .other(let detail): "利用できません: \(detail)"
        }
    }

    public static func system(_ model: SystemLanguageModel = .default) -> ModelAvailability {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .other(String(describing: reason))
            }
        }
    }
}

/// モデルのエラー（Foundation Models のエラーをこの型に変換して扱う）
public enum LLMError: Error, Sendable, Equatable {
    /// ガードレール違反
    case guardrailViolation(String)
    /// モデルによる拒否
    case refusal(String)
    /// コンテキスト超過
    case contextSizeExceeded(String)
    /// 利用不可
    case unavailable(ModelAvailability)
    /// 時間切れ
    case timeout(Double)
    case other(kind: String, detail: String)

    /// 集計用の種別名
    public var kind: String {
        switch self {
        case .guardrailViolation: "guardrail_violation"
        case .refusal: "refusal"
        case .contextSizeExceeded: "context_size_exceeded"
        case .unavailable: "unavailable"
        case .timeout: "timeout"
        case .other(let kind, _): kind
        }
    }

    public var detail: String {
        switch self {
        case .guardrailViolation(let d), .refusal(let d), .contextSizeExceeded(let d): d
        case .unavailable(let a): a.reasonText
        case .timeout(let s): "\(s) 秒以内に終わらなかった"
        case .other(_, let d): d
        }
    }

    /// Foundation Models のエラーを変換する
    public static func from(_ error: Error) -> LLMError {
        if let error = error as? LLMError { return error }
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded(let c):
                return .contextSizeExceeded("\(c.tokenCount)/\(c.contextSize) \(c.debugDescription)")
            case .guardrailViolation(let c):
                return .guardrailViolation(c.debugDescription)
            case .refusal(let c):
                return .refusal(c.debugDescription)
            case .rateLimited(let c):
                return .other(kind: "rate_limited", detail: c.debugDescription)
            case .timeout(let c):
                return .other(kind: "model_timeout", detail: c.debugDescription)
            case .unsupportedLanguageOrLocale(let c):
                return .other(kind: "unsupported_language_or_locale", detail: c.debugDescription)
            case .unsupportedCapability(let c):
                return .other(kind: "unsupported_capability", detail: c.debugDescription)
            case .unsupportedTranscriptContent(let c):
                return .other(kind: "unsupported_transcript_content", detail: c.debugDescription)
            case .unsupportedGenerationGuide(let c):
                return .other(kind: "unsupported_generation_guide", detail: c.debugDescription)
            @unknown default:
                return .other(kind: "language_model_error", detail: String(describing: error))
            }
        }
        if let error = error as? SystemLanguageModel.Error {
            switch error {
            case .assetsUnavailable:
                return .unavailable(.modelNotReady)
            @unknown default:
                return .other(kind: "system_language_model_error", detail: String(describing: error))
            }
        }
        if let error = error as? LanguageModelSession.Error {
            return .other(kind: "session_error", detail: String(describing: error))
        }
        if error is CancellationError {
            return .other(kind: "cancelled", detail: "")
        }
        if let error = error as? GeneratedContent.ParsingError {
            return .other(kind: "decoding_failure", detail: error.debugDescription)
        }
        // Swift の型に戻せない NSError として届くことがある（プロトタイプでの実測: FoundationModels.LanguageModelError code -1）
        // TODO(要確認): code -1 の意味は公式ドキュメントに記載を見つけられていない
        let nsError = error as NSError
        if nsError.domain.hasPrefix("FoundationModels.") {
            let typeName = nsError.domain.split(separator: ".").last.map(String.init) ?? nsError.domain
            return .other(kind: "\(typeName)(\(nsError.code))", detail: String(describing: error))
        }
        return .other(kind: "unknown", detail: String(describing: error))
    }
}

extension Duration {
    /// ミリ秒（切り捨て）
    public var milliseconds: Int {
        Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
