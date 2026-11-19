import AppKit
import SwiftUI

extension String {
    var localized: String { NSLocalizedString(self, comment: "") }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ru
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .en: return AppLanguage.text("English", in: "en")
        case .ru: return AppLanguage.text("Russian", in: "ru")
        }
    }

    static func text(_ key: String, in language: String) -> String {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static var pickerTitle: String {
        let en = text("Language", in: "en"), ru = text("Language", in: "ru")
        return en == ru ? en : en + " / " + ru
    }

    static var saved: AppLanguage {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        guard let first = (domain["AppleLanguages"] as? [String])?.first else { return .system }
        return first.hasPrefix("ru") ? .ru : .en
    }

    static func save(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    static func restart() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
