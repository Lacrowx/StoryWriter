import AppKit
import SwiftUI

// These preferences belong to this Mac and never travel with a project.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
    var nativeAppearance: NSAppearance? { switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) } }
}

enum WriterAccent: String, CaseIterable, Identifiable {
    case sage = "Sage", blue = "Ocean", purple = "Violet", rose = "Rose", amber = "Amber"
    var id: String { rawValue }
    func color(dark: Bool) -> NSColor {
        switch self {
        case .sage: return dark ? NSColor(srgbRed: 0.52, green: 0.76, blue: 0.64, alpha: 1) : NSColor(srgbRed: 0.20, green: 0.43, blue: 0.36, alpha: 1)
        case .blue: return dark ? .systemTeal : .systemBlue
        case .purple: return .systemPurple
        case .rose: return .systemPink
        case .amber: return dark ? .systemYellow : .systemBrown
        }
    }
}

enum PaperTone: String, CaseIterable, Identifiable {
    case warm = "Warm", white = "White", sepia = "Sepia"
    var id: String { rawValue }
    var color: NSColor {
        switch self {
        case .warm: return NSColor(srgbRed: 0.992, green: 0.981, blue: 0.956, alpha: 1)
        case .white: return .white
        case .sepia: return NSColor(srgbRed: 0.94, green: 0.89, blue: 0.79, alpha: 1)
        }
    }
}

enum PaperMargins: String, CaseIterable, Identifiable {
    case compact = "Compact", balanced = "Balanced", generous = "Generous"
    var id: String { rawValue }
    func horizontal(for width: CGFloat) -> CGFloat {
        switch self {
        case .compact: return 20
        case .balanced: return min(64, max(28, width * 0.045))
        case .generous: return min(100, max(44, width * 0.08))
        }
    }
    var vertical: CGFloat { switch self { case .compact: return 24; case .balanced: return 36; case .generous: return 52 } }
}

struct ApplicationPreferences {
    var defaults: UserDefaults = .standard
    func bool(_ key: String, fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
    func number(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let value = defaults.object(forKey: key) as? Double, value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
    var resumesWorkspace: Bool { bool("resumeWorkspace", fallback: true) }
    var autosaveDelay: Double { number("autosaveDelay", fallback: 0.7, range: 0.3...5) }
    var revisionInterval: Double { number("revisionInterval", fallback: 300, range: 60...1800) }
    var backupInterval: Double { number("backupInterval", fallback: 300, range: 60...1800) }
    var reviewDelay: Double { number("reviewDelay", fallback: 2, range: 1...10) }
    var defaultFont: NSFont {
        let size = number("defaultFontSize", fallback: 18, range: 10...32)
        return NSFontManager.shared.font(withFamily: defaults.string(forKey: "defaultFontName") ?? "Georgia", traits: [], weight: 5, size: size) ?? NSFont.systemFont(ofSize: size)
    }
    var defaultLineSpacing: Double { number("defaultLineSpacing", fallback: 6, range: 0...16) }
    var paperMargins: PaperMargins { defaults.string(forKey: "paperMargins").flatMap(PaperMargins.init(rawValue:)) ?? .balanced }
    var discoversNames: Bool { bool("discoverObjectNames", fallback: true) }
    var selectionActions: Bool { bool("selectionQuickActions", fallback: true) }
}

// Shared by manuscript and planning fields, so typing assistance behaves consistently.
struct TypingPreferences: DynamicProperty {
    @AppStorage("nativeSpellChecking") var spelling = true
    @AppStorage("nativeGrammarChecking") var grammar = true
    @AppStorage("automaticSpellingCorrection") var correction = false
    @AppStorage("smartQuotes") var quotes = true
    @AppStorage("smartDashes") var dashes = true
    @AppStorage("detectWebLinks") var links = true

    func apply(to view: NSTextView) {
        if view.isContinuousSpellCheckingEnabled != spelling { view.isContinuousSpellCheckingEnabled = spelling }
        if view.isGrammarCheckingEnabled != grammar { view.isGrammarCheckingEnabled = grammar }
        if view.isAutomaticSpellingCorrectionEnabled != correction { view.isAutomaticSpellingCorrectionEnabled = correction }
        if view.isAutomaticQuoteSubstitutionEnabled != quotes { view.isAutomaticQuoteSubstitutionEnabled = quotes }
        if view.isAutomaticDashSubstitutionEnabled != dashes { view.isAutomaticDashSubstitutionEnabled = dashes }
        if view.isAutomaticLinkDetectionEnabled != links { view.isAutomaticLinkDetectionEnabled = links }
    }
}

struct ApplicationAppearanceModifier: ViewModifier {
    @AppStorage("appAppearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("accentColor") private var accent = WriterAccent.sage.rawValue
    func body(content: Content) -> some View {
        let color = AppTheme.color(for: WriterAccent(rawValue: accent) ?? .sage)
        return content.preferredColorScheme((AppAppearance(rawValue: appearance) ?? .system).colorScheme)
            .tint(color).accentColor(color)
            .onAppear { applyAppearance() }
            .onChange(of: appearance) { _, _ in applyAppearance() }
    }
    private func applyAppearance() { NSApp.appearance = (AppAppearance(rawValue: appearance) ?? .system).nativeAppearance }
}
