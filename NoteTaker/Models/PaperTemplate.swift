import SwiftUI

/// Types of paper templates tailored for academic and business school note-taking.
public enum PaperTemplateType: String, Codable, CaseIterable, Identifiable {
    case blank = "Blank"
    case ruled = "Ruled / Lined"
    case ruledNarrow = "Ruled Narrow"
    case grid = "Grid / Graph"
    case dotGrid = "Dot Grid"
    case cornell = "Cornell Notes"
    case financialLedger = "Financial Ledger"
    case slideNotes = "Slide Presentation Notes"
    
    public var id: String { rawValue }
    public var displayName: String { rawValue }
    
    public var iconName: String {
        switch self {
        case .blank: return "doc"
        case .ruled: return "line.horizontal.3"
        case .ruledNarrow: return "text.alignleft"
        case .grid: return "squareshape.split.3x3"
        case .dotGrid: return "circle.grid.3x3.fill"
        case .cornell: return "rectangle.split.3x1"
        case .financialLedger: return "tablecells"
        case .slideNotes: return "rectangle.inset.topthird.fill"
        }
    }
    
    public var description: String {
        switch self {
        case .blank:
            return "Clean sheet without rules. Great for sketching and freeform thinking."
        case .ruled:
            return "Standard academic ruled lines (28pt) with left margin."
        case .ruledNarrow:
            return "Compact ruled lines (20pt) for dense writing."
        case .grid:
            return "5mm square grid for finance curves, supply/demand, and math."
        case .dotGrid:
            return "Subtle 5mm dot grid for structured layouts, matrices, and tables."
        case .cornell:
            return "Classic Cornell format: Cue column, Notes section, and Bottom Summary."
        case .financialLedger:
            return "3-column accounting ledger for balance sheets, DCF, and income statements."
        case .slideNotes:
            return "Upper slide frame with ruled note-taking lines below."
        }
    }
    
    /// Default line height for text alignment and GoodNotes-style Zoom Window auto-advance
    public var lineHeight: CGFloat {
        switch self {
        case .blank: return 32.0
        case .ruled: return 28.0
        case .ruledNarrow: return 20.0
        case .grid: return 24.0
        case .dotGrid: return 24.0
        case .cornell: return 28.0
        case .financialLedger: return 26.0
        case .slideNotes: return 24.0
        }
    }
}

/// Paper background tone.
public enum PaperColor: String, Codable, CaseIterable, Identifiable {
    case ivory = "Ivory Cream"
    case white = "Pure White"
    case sepia = "Warm Sepia"
    case dark = "Dark Charcoal"
    
    public var id: String { rawValue }
    
    public var backgroundColor: Color {
        switch self {
        case .ivory: return BrandTheme.paperIvory
        case .white: return Color.white
        case .sepia: return BrandTheme.paperSepia
        case .dark: return BrandTheme.paperDark
        }
    }
    
    public var uiColor: UIColor {
        switch self {
        case .ivory: return UIColor(BrandTheme.paperIvory)
        case .white: return UIColor.white
        case .sepia: return UIColor(BrandTheme.paperSepia)
        case .dark: return UIColor(BrandTheme.paperDark)
        }
    }
    
    public var rulingColor: Color {
        switch self {
        case .ivory: return Color(red: 0xDB / 255.0, green: 0xD7 / 255.0, blue: 0xCA / 255.0)
        case .white: return Color(red: 0xEE / 255.0, green: 0xF0 / 255.0, blue: 0xF4 / 255.0)
        case .sepia: return Color(red: 0xE2 / 255.0, green: 0xD6 / 255.0, blue: 0xBE / 255.0)
        case .dark: return Color(red: 0x2E / 255.0, green: 0x2E / 255.0, blue: 0x32 / 255.0)
        }
    }
    
    public var isDark: Bool {
        self == .dark
    }
}
