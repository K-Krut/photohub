import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "Follow System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    static var saved: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    }

    @MainActor
    static func save(_ value: AppAppearance) {
        UserDefaults.standard.set(value.rawValue, forKey: "appearance")
        apply()
    }

    @MainActor
    static func apply() {
        switch saved {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum SettingsWindow {
    @MainActor
    static func open(_ model: Model, tab: String? = nil) {
        if let tab { model.settingsTab = tab }
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) else { return }
        menu.performActionForItem(at: index)
    }
}

extension View {
    func settingsTab(_ tag: String, _ title: LocalizedStringKey, _ icon: String) -> some View {
        tabItem { Label(title, systemImage: icon) }.tag(tag)
    }
}

struct GeneralSettings: View {
    @State private var language = AppLanguage.saved
    @State private var languageChanged = false
    @State private var appearance = AppAppearance.saved

    var body: some View {
        Form {
            Section {
                Picker(AppLanguage.pickerTitle, selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { value in
                    AppLanguage.save(value)
                    languageChanged = true
                }
                if languageChanged {
                    HStack {
                        Label("Restart PhotoHub to switch the language.", systemImage: "arrow.clockwise.circle").foregroundStyle(Color.accentColor)
                        Spacer()
                        Button("Restart Now") { AppLanguage.restart() }
                    }
                }
            } footer: {
                Text("By default PhotoHub follows the macOS language. A new language applies after a restart.")
            }
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { AppAppearance.save($0) }
            } footer: {
                Text("Light or dark applies right away; Follow System switches with macOS.")
            }
            Section {
                LabeledContent("Settings", value: "⌘,")
                LabeledContent("Collections, All Items, Map, Calendar, Folders, To Phone, Statistics", value: "⌘1 … ⌘7")
                LabeledContent("Refresh Catalog", value: "⌘R")
            } header: {
                Text("Keyboard Shortcuts")
            }
        }
        .formStyle(.grouped)
    }
}

struct SidebarFooter: View {
    @ObservedObject var model: Model

    var body: some View {
        HStack(spacing: 6) {
            Button { SettingsWindow.open(model, tab: "general") } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings: language, appearance, archive, collections, statistics (⌘,)")
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
