import UIKit
import PencilKit

/// Handles Apple Pencil double-tap: switches between the current tool and the eraser (or the
/// previous tool, per the system setting).
///
/// Tool switching goes through the shared `PKToolPicker`, which propagates the selected tool to
/// every observing canvas — so a double-tap toggles exactly once no matter how many canvases
/// (pages, margins, zoom window) are on screen.
public final class PencilInteractionManager: NSObject, UIPencilInteractionDelegate {
    public static let shared = PencilInteractionManager()
    
    private var previousTool: PKTool?
    private var lastTapTime: TimeInterval = 0
    
    override private init() {
        super.init()
    }
    
    /// Attaches a pencil interaction to a view. Each canvas gets its own, so double-tap keeps
    /// working after the first canvas is scrolled away and deallocated.
    public func attach(to view: UIView) {
        guard !view.interactions.contains(where: { $0 is UIPencilInteraction }) else { return }
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        view.addInteraction(interaction)
    }
    
    public func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        // Several interactions may report the same physical tap; handle it once.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTapTime > 0.2 else { return }
        lastTapTime = now
        
        switch UIPencilInteraction.preferredTapAction {
        case .ignore, .showColorPalette, .showInkAttributes:
            return
        case .switchPrevious:
            toggleTool(alwaysToEraser: false)
        default:
            toggleTool(alwaysToEraser: true)
        }
    }
    
    private func toggleTool(alwaysToEraser: Bool) {
        let picker = PencilCanvasContainer.sharedToolPicker()
        let current = picker.selectedTool
        if current is PKEraserTool {
            picker.selectedTool = previousTool ?? PKInkingTool(.pen, color: .black, width: 2.5)
            previousTool = current
        } else if alwaysToEraser || previousTool == nil {
            previousTool = current
            picker.selectedTool = PKEraserTool(.vector)
        } else if let previous = previousTool {
            previousTool = current
            picker.selectedTool = previous
        }
    }
}
