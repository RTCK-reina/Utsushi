import Foundation
import AppKit

/// 表示言語の切り替え。
///
/// macOS はシステム設定の「言語と地域」でアプリごとに言語を選べるが、
/// **そこまで辿り着けることを前提にしない。** アプリの中に置く。
///
/// 仕組みは `AppleLanguages` の上書き。読み込みは起動時に一度しか行われないので、
/// 切り替えたら再起動が要る。**黙って再起動しない**——実行中の文字起こしが消えるため、
/// 画面で伝えてから利用者に押してもらう。
enum AppLanguage: String, CaseIterable, Identifiable {
    /// システムの言語に従う。`AppleLanguages` の上書きを消す。
    case system
    case japanese = "ja"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:   return String(localized: "システムに従う")
        case .japanese: return "日本語"
        case .english:  return "English"
        }
    }

    private static let key = "AppleLanguages"

    /// 今の設定。上書きが無ければ `.system`。
    static var current: AppLanguage {
        guard let list = UserDefaults.standard.stringArray(forKey: key),
              let first = list.first else { return .system }
        // "ja-JP" のような地域付きも受ける
        if first.hasPrefix("ja") { return .japanese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    /// 次の起動から効く。**現在の画面は切り替わらない。**
    static func apply(_ language: AppLanguage) {
        switch language {
        case .system:
            UserDefaults.standard.removeObject(forKey: key)
        case .japanese, .english:
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
        UserDefaults.standard.synchronize()
    }

    /// アプリを再起動する。実行中の作業は失われるので、呼ぶ前に確認すること。
    static func restart() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }
}
