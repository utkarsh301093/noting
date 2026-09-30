import SwiftUI

/// App-wide Light / Dark theme preference.
///
/// Ink colors are never rewritten when the theme changes: PencilKit stores ink in light-mode colors
/// and adapts it on screen for canvases in dark appearance.
@MainActor
public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()
    
    @Published public var isDarkMode: Bool = UserDefaults.standard.bool(forKey: "isDarkMode") {
        didSet {
            UserDefaults.standard.set(isDarkMode, forKey: "isDarkMode")
        }
    }
    
    private init() {}
    
    public func toggleTheme() {
        isDarkMode.toggle()
    }
}
