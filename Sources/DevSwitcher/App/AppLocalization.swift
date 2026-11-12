import DevSwitcherCore
import Foundation

/// 言語は起動時に固定する。確認シートを開いた途中で言語や判断文言を変えない。
struct AppLocalization: Sendable {
    static let selectedLanguage = Language.preferred()

    enum Language: String, CaseIterable, Sendable {
        case japanese = "ja"
        case english = "en"

        static func preferred(_ languages: [String] = Locale.preferredLanguages) -> Self {
            let match = Bundle.preferredLocalizations(from: ["en", "ja"], forPreferences: languages).first
            return match == "ja" ? .japanese : .english
        }
    }

    let language: Language
    private let translations: [String: String]

    init(language: Language = AppLocalization.selectedLanguage, resources: Bundle? = nil) throws {
        self.language = language
        let bundle = try resources ?? AppResources.bundle()
        guard let root = bundle.resourceURL else {
            throw LocalizationError.missingResource(language.rawValue)
        }
        // Bundle の言語 fallback を使わず、選択言語の同梱物を必須にする。
        let url = root.appendingPathComponent("\(language.rawValue).lproj/Localizable.strings")
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        guard let translations = object as? [String: String], !translations.isEmpty else {
            throw LocalizationError.invalidResource(language.rawValue)
        }
        self.translations = translations
    }

    func render(_ message: LocalizedMessage) -> String {
        guard let template = translations[message.key] else {
            preconditionFailure("Missing \(language.rawValue) localization: \(message.key)")
        }
        return message.rendered(using: template)
    }

    static func install() {
        do {
            let localization = try AppLocalization()
            L10n.install { localization.render($0) }
        } catch {
            // 同梱物の欠落を別言語や開発マシンのファイルで補わない。
            fatalError("Cannot load application translations. Reinstall Dev Switcher. \(error)")
        }
    }

    enum LocalizationError: Error {
        case missingResource(String)
        case invalidResource(String)
    }
}
