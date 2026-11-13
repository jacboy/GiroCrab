// macOS entry point for `swift run GiroCrabMac` / `cargo run` (the Xcode
// multiplatform target uses Xcode/App/GiroCrabApp.swift instead).
//
//   GiroCrabMac --demo-seed                 explore with demo data
//   GiroCrabMac --screenshot out.png        render the window to a PNG and quit
//
// Compiled empty on other platforms, so the package scheme (and its tests)
// also builds for the iOS Simulator.
#if os(macOS)
import AppKit
import SwiftUI
import GiroCrabUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    #if canImport(Sparkle)
    /// Kept alive for the app's lifetime; nil unless this is a configured
    /// release bundle (see Updater.swift).
    private var updater: SparkleUpdateBackend?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if LaunchOptions.current.dark {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if CommandLine.arguments.contains("--light") {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        if let icon = Self.appIcon() {
            NSApp.applicationIconImage = icon
        }
        // In --screenshot mode don't steal the keyboard focus from the user.
        if LaunchOptions.current.screenshotPath == nil {
            NSApp.activate(ignoringOtherApps: true)
        }
        MainActor.assumeIsolated {
            WindowScreenshot.scheduleIfRequested()
            #if canImport(Sparkle)
            // Not in screenshot / demo-seed automation runs.
            if LaunchOptions.current.screenshotPath == nil {
                updater = SparkleUpdateBackend.startIfConfigured()
            }
            #endif
        }
    }

    /// The GiroCrab icon, also when started outside an .app bundle
    /// (`swift run`, `cargo run`): bundle icns → asset catalog → source PNG.
    static func appIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let img = NSImage(contentsOf: url) {
            return img
        }
        if let img = NSImage(named: "AppIcon") {
            return img
        }
        // .build/<config>/GiroCrabMac -> GiroCrabApp/Xcode/App/Assets.xcassets/…
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Xcode/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
            if let img = NSImage(contentsOf: candidate) { return img }
            let nested = dir.appendingPathComponent("GiroCrabApp/Xcode/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
            if let img = NSImage(contentsOf: nested) { return img }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct GiroCrabMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    // The model is built here, once and outside the body's dependency tracking
    // (see GiroCrabScenes.prepare).
    init() {
        // Frontmost before the first Touch ID prompt, also via `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
        if LaunchOptions.current.screenshotPath == nil {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        GiroCrabScenes.prepare()
    }

    var body: some Scene {
        GiroCrabScenes()
    }
}

GiroCrabMacApp.main()
#endif
