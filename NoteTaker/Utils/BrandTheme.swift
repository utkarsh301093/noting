import SwiftUI

/// Accent, paper and folder colors used across the app.
public struct BrandTheme {
    // MARK: - Brand Colors
    /// Royal purple (#4E2A84)
    public static let brandPurple = Color(red: 0x4E / 255.0, green: 0x2A / 255.0, blue: 0x84 / 255.0)
    
    // MARK: - Academic Accent Colors
    public static let brandGold = Color(red: 0xD4 / 255.0, green: 0xAF / 255.0, blue: 0x37 / 255.0)
    public static let financeTeal = Color(red: 0x00 / 255.0, green: 0x7E / 255.0, blue: 0x8A / 255.0)
    public static let strategyBlue = Color(red: 0x23 / 255.0, green: 0x5C / 255.0, blue: 0x97 / 255.0)
    public static let marketingCoral = Color(red: 0xE0 / 255.0, green: 0x5A / 255.0, blue: 0x47 / 255.0)
    public static let analyticsGreen = Color(red: 0x2E / 255.0, green: 0x7D / 255.0, blue: 0x32 / 255.0)
    public static let slateGray = Color(red: 0x54 / 255.0, green: 0x6E / 255.0, blue: 0x7A / 255.0)
    
    // MARK: - Paper Colors
    public static let paperIvory = Color(red: 0xFC / 255.0, green: 0xFA / 255.0, blue: 0xF2 / 255.0)
    public static let paperSepia = Color(red: 0xF5 / 255.0, green: 0xEF / 255.0, blue: 0xDC / 255.0)
    public static let paperDark = Color(red: 0x1A / 255.0, green: 0x1A / 255.0, blue: 0x1C / 255.0)
    public static let paperMarginRed = Color(red: 0xEE / 255.0, green: 0x77 / 255.0, blue: 0x77 / 255.0)
    
    public static let availableFolderColors: [(name: String, color: Color, hex: String)] = [
        ("Royal Purple", brandPurple, "#4E2A84"),
        ("Strategy Blue", strategyBlue, "#235C97"),
        ("Finance Teal", financeTeal, "#007E8A"),
        ("Analytics Green", analyticsGreen, "#2E7D32"),
        ("Marketing Coral", marketingCoral, "#E05A47"),
        ("Gold Accent", brandGold, "#D4AF37"),
        ("Slate", slateGray, "#546E7A")
    ]
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
