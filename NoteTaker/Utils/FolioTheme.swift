import SwiftUI

/// Classical Design System tokens for Folio — an editorial, book-like iPad note-taking system.
/// Defined by Cormorant Garamond headings, Lora body text, hairline dividers,
/// warm archival paper grounds, and warm gold (#b68235) accents.
public struct FolioTheme {
    
    // MARK: - Core Theme Palettes (Light & Dark)
    
    public struct LightPalette {
        public static let bg = Color(hex: "#f3f2f2")
        public static let surface = Color(hex: "#eae9e9")
        public static let text = Color(hex: "#201f1d")
        public static let textSecondary = Color(hex: "#605d5d")
        public static let accent = Color(hex: "#b68235")
        public static let divider = Color(hex: "#201f1d").opacity(0.16)
    }
    
    public struct DarkPalette {
        public static let bg = Color(hex: "#181717")
        public static let surface = Color(hex: "#222121")
        public static let text = Color(hex: "#f3f2f2")
        public static let textSecondary = Color(hex: "#a6a2a2")
        public static let accent = Color(hex: "#e1ad66")
        public static let divider = Color.white.opacity(0.14)
    }
    
    // MARK: - Dynamic Color Resolver
    
    public static func bg(isDark: Bool) -> Color {
        isDark ? DarkPalette.bg : LightPalette.bg
    }
    
    public static func surface(isDark: Bool) -> Color {
        isDark ? DarkPalette.surface : LightPalette.surface
    }
    
    public static func text(isDark: Bool) -> Color {
        isDark ? DarkPalette.text : LightPalette.text
    }
    
    public static func textSecondary(isDark: Bool) -> Color {
        isDark ? DarkPalette.textSecondary : LightPalette.textSecondary
    }
    
    public static func accent(isDark: Bool) -> Color {
        isDark ? DarkPalette.accent : LightPalette.accent
    }
    
    public static func divider(isDark: Bool) -> Color {
        isDark ? DarkPalette.divider : LightPalette.divider
    }
    
    // MARK: - Classical Typography Helpers
    
    /// Serif display font for headings, matching Cormorant Garamond
    public static func serifHeading(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}
