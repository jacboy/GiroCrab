import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// UI language of the app (#93), designed along the Apple HIG:
///
/// * The choice lives in the app's own `AppleLanguages` default – the same
///   value macOS writes for System Settings › General › Language & Region ›
///   Applications (and iOS for Settings › GiroCrab › Language). Both places
///   therefore always show the same choice. The String Catalog and the Rust
///   core (`setLanguage` with `Bundle.main.preferredLocalizations`) follow it
///   after a restart, so one run never mixes languages.
/// * No question at launch when the system language is one the app speaks:
///   the system already answered it, and people get to their content at once.
///   The choice is offered in Settings › Allgemein.
/// * A language screen before the vault opens only when the system language
///   is not supported, i.e. when the app would otherwise silently guess.
/// * When the system language later changes away from an explicitly chosen
///   app language, one non-blocking alert offers to switch (asked once).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, de, en

    var id: String { rawValue }

    /// Language names are shown in their own language, as in System Settings.
    static func nativeName(_ code: String) -> String {
        Locale(identifier: code).localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }
}

/// What to ask when the app starts.
enum LanguageQuestion: Equatable {
    case none
    /// The system language is not supported: choose German or English.
    case chooseLanguage
    /// The system language changed to `to`, but the app is set to another language.
    case systemChanged(to: String)
}

struct LanguagePreference {
    /// Languages the app ships translations for (source language first).
    static let supported = ["de", "en"]
    static let lastSystemKey = "language.lastSystemLanguage"
    static let appleLanguagesKey = "AppleLanguages"

    let defaults: UserDefaults
    /// Name of the app's own defaults domain (the bundle identifier).
    let domain: String
    /// The user's system-wide preferred languages, unaffected by the app override.
    let systemLanguages: () -> [String]

    static var standard: LanguagePreference {
        LanguagePreference(defaults: .standard, domain: Bundle.main.bundleIdentifier ?? "",
                           systemLanguages: globalPreferredLanguages)
    }

    /// Defaults domain used with `--simulate-system-language`, so trying the
    /// flows never touches the real app settings.
    static let simulationDomain = "de.girocrab.app.language-simulation"

    /// The preference the app works with: the real one, or with
    /// `--simulate-system-language <code>` a pretended system language and a
    /// separate defaults domain.
    static var current: LanguagePreference {
        guard let simulated = LaunchOptions.current.simulateSystemLanguage,
              let suite = UserDefaults(suiteName: simulationDomain) else { return standard }
        return LanguagePreference(defaults: suite, domain: simulationDomain, systemLanguages: { [simulated] })
    }

    /// The app bundle carries the translations (not the case for `swift run`
    /// or test bundles, which only have the German source strings).
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Set(Bundle.main.localizations).isSuperset(of: supported)
    }

    /// Language the running process actually uses.
    static var runningLanguage: String {
        Bundle.main.preferredLocalizations.first.flatMap(supportedCode) ?? supported[0]
    }

    /// "de-DE" -> "de"; nil for languages the app has no translation for.
    static func supportedCode(_ identifier: String) -> String? {
        let code = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
        return supported.contains(code) ? code : nil
    }

    /// The system list contains a language the app speaks.
    var systemIsSupported: Bool {
        systemLanguages().contains { Self.supportedCode($0) != nil }
    }

    /// The language the app uses when following the system: the first
    /// supported entry of the system list, German if there is none.
    var systemLanguage: String {
        systemLanguages().lazy.compactMap(Self.supportedCode).first ?? Self.supported[0]
    }

    /// The app's own `AppleLanguages` (only its own domain: a plain read would
    /// fall back to the global list).
    private var ownLanguages: [String]? {
        defaults.persistentDomain(forName: domain)?[Self.appleLanguagesKey] as? [String]
    }

    /// Current choice, also when it was made in System Settings.
    var choice: AppLanguage {
        ownLanguages?.first.flatMap(Self.supportedCode).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// Language the app uses after the next start for the given choice.
    func effectiveLanguage(for choice: AppLanguage) -> String {
        choice == .system ? systemLanguage : choice.rawValue
    }

    /// Stores the choice (takes effect after a restart).
    func apply(_ choice: AppLanguage) {
        if choice == .system {
            defaults.removeObject(forKey: Self.appleLanguagesKey)
        } else {
            defaults.set([choice.rawValue], forKey: Self.appleLanguagesKey)
        }
        acknowledgeSystemLanguage()
    }

    /// What "the system language" was at the last start: the resolved language,
    /// or the raw first entry when the system speaks none of the app's languages.
    var systemKey: String {
        systemIsSupported ? systemLanguage : "-" + (systemLanguages().first ?? "")
    }

    /// Remembers the current system language, so a question about it is asked once.
    func acknowledgeSystemLanguage() {
        defaults.set(systemKey, forKey: Self.lastSystemKey)
    }

    /// Decides what to ask at start-up; only on the first start or after the
    /// system language changed. Cases without a question are acknowledged at once.
    func startupQuestion() -> LanguageQuestion {
        let last = defaults.string(forKey: Self.lastSystemKey)
        guard last != systemKey else { return .none }
        switch choice {
        case .system where !systemIsSupported:
            return .chooseLanguage
        case let chosen where chosen != .system && last != nil && systemIsSupported && chosen.rawValue != systemLanguage:
            return .systemChanged(to: systemLanguage)
        default:
            acknowledgeSystemLanguage()
            return .none
        }
    }

    /// The system list from the global preferences domain. `Locale.preferredLanguages`
    /// would already return the app's own `AppleLanguages` override.
    static func globalPreferredLanguages() -> [String] {
        #if os(macOS)
        if let list = CFPreferencesCopyValue(appleLanguagesKey as CFString, kCFPreferencesAnyApplication,
                                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
           !list.isEmpty {
            return list
        }
        #endif
        return Locale.preferredLanguages
    }

    /// Starts a new instance of the app and quits this one. Only possible for
    /// a real `.app` bundle on macOS (not `swift run`).
    static var canRelaunch: Bool {
        #if os(macOS)
        Bundle.main.bundleURL.pathExtension == "app"
        #else
        false
        #endif
    }

    @MainActor static func relaunch() {
        #if os(macOS)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        if LaunchOptions.current.simulateSystemLanguage != nil {
            // Simulation: keep the developer switches and apply the simulated choice
            // through the argument domain (the real AppleLanguages stay untouched).
            var args = Array(CommandLine.arguments.dropFirst())
            if let i = args.firstIndex(of: "-AppleLanguages") { args.removeSubrange(i..<min(i + 2, args.count)) }
            let pref = current
            config.arguments = args + ["-AppleLanguages", "(\(pref.effectiveLanguage(for: pref.choice)))"]
        }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        #endif
    }
}

/// Shown before the vault opens, only when the system language is not one the
/// app speaks: the app would otherwise silently fall back to German.
struct LanguagePromptView: View {
    let preference: LanguagePreference
    let onDone: () -> Void
    // English is the more likely fallback for someone whose system is in neither language.
    @State private var selection: AppLanguage = .en

    init(preference: LanguagePreference = .current, onDone: @escaping () -> Void) {
        self.preference = preference
        self.onDone = onDone
    }

    private var needsRestart: Bool {
        selection.rawValue != LanguagePreference.runningLanguage && LanguagePreference.canRelaunch
    }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "globe")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("Sprache wählen")
                    .font(.title.bold())
                Text("GiroCrab ist in Ihrer Systemsprache noch nicht verfügbar. In welcher Sprache soll GiroCrab angezeigt werden?")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: 420)
                Picker("Sprache", selection: $selection) {
                    ForEach(LanguagePreference.supported, id: \.self) { code in
                        Text(verbatim: AppLanguage.nativeName(code)).tag(AppLanguage(rawValue: code)!)
                    }
                }
                .labelsHidden()
                #if os(macOS)
                .pickerStyle(.radioGroup)
                #endif
                .fixedSize()
                Text(needsRestart
                     ? "GiroCrab startet dazu kurz neu. Sie können die Sprache später in den Einstellungen ändern."
                     : "Sie können die Sprache später in den Einstellungen ändern.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Weiter", action: confirm)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(32)
        }
    }

    private func confirm() {
        preference.apply(selection)
        if needsRestart { LanguagePreference.relaunch() } else { onDone() }
    }
}

/// The once-per-change alert when the system language moved away from the
/// app's explicitly chosen language.
struct SystemLanguageChangedAlert: ViewModifier {
    @Binding var newLanguage: String?

    func body(content: Content) -> some View {
        let new = newLanguage.map(AppLanguage.nativeName) ?? ""
        let current = AppLanguage.nativeName(LanguagePreference.runningLanguage)
        content.alert("Die Systemsprache wurde geändert", isPresented: Binding(
            get: { newLanguage != nil },
            set: { if !$0 { newLanguage = nil } }
        )) {
            Button("Zu \(new) wechseln") {
                LanguagePreference.current.apply(.system)
                LanguagePreference.relaunch()
            }
            .keyboardShortcut(.defaultAction)
            Button("\(current) beibehalten", role: .cancel) {
                LanguagePreference.current.acknowledgeSystemLanguage()
            }
        } message: {
            Text("Ihr Mac verwendet jetzt \(new), GiroCrab ist auf \(current) eingestellt. Zum Wechseln startet GiroCrab neu.")
        }
    }
}

/// Settings › Allgemein › Sprache.
struct LanguageSettingsSection: View {
    private let preference = LanguagePreference.current
    @State private var selection: AppLanguage = LanguagePreference.current.choice

    private var needsRestart: Bool {
        preference.effectiveLanguage(for: selection) != LanguagePreference.runningLanguage
    }

    var body: some View {
        #if os(macOS)
        Section {
            Picker("Sprache", selection: $selection) {
                Text("Systemsprache (\(AppLanguage.nativeName(preference.systemLanguage)))").tag(AppLanguage.system)
                Divider()
                ForEach(LanguagePreference.supported, id: \.self) { code in
                    Text(verbatim: AppLanguage.nativeName(code)).tag(AppLanguage(rawValue: code)!)
                }
            }
            .onChange(of: selection) { _, new in preference.apply(new) }
            if needsRestart && LanguagePreference.canRelaunch {
                LabeledContent("Die neue Sprache wird nach einem Neustart verwendet.") {
                    Button("Neu starten") { LanguagePreference.relaunch() }
                }
            }
        } footer: {
            Text("Diese Einstellung entspricht der Sprache für GiroCrab in den Systemeinstellungen unter „Allgemein › Sprache & Region › Programme“.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .leadingFooter()
        }
        // Pick up a change made in System Settings while the app is running.
        .onAppear { selection = preference.choice }
        #else
        // iOS has its own per-app language setting; the HIG asks apps not to duplicate it.
        Section {
            LabeledContent("Sprache", value: AppLanguage.nativeName(LanguagePreference.runningLanguage))
            Button("In den Einstellungen ändern") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
        #endif
    }
}
