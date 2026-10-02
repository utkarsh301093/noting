import UIKit
import PencilKit
import os

/// Handles Apple Pencil double-tap: switches between the current tool and the eraser (or the
/// previous tool, per the system setting).
///
/// Tool switching goes through the shared `PKToolPicker`, which propagates the selected tool to
/// every observing canvas — so a double-tap toggles exactly once no matter how many canvases
/// (pages, margins, zoom window) are on screen.
///
/// A visible `PKToolPicker` already handles double-tap natively; toggling here as well would
/// immediately undo its switch. So taps are only acted on while the picker is hidden, and only if
/// the picker's tool didn't change on its own right after the tap.
public final class PencilInteractionManager: NSObject, UIPencilInteractionDelegate, PKToolPickerObserver {
    public static let shared = PencilInteractionManager()

    private let log = Logger(subsystem: "Noting", category: "PencilDoubleTap")

    /// Tool history, keyed by tool picker item identifier on iPadOS 18+ (where the picker selects
    /// items, not tools) and by tool on iPadOS 17.
    private var previous: ToolRef?
    private var lastDrawing: ToolRef?
    private var current: ToolRef?
    private var toolChangeCount = 0
    private var lastTapTime: TimeInterval = 0
    private var isObservingPicker = false

    private enum ToolRef {
        case item(String, isEraser: Bool)
        case tool(PKTool)

        var isEraser: Bool {
            switch self {
            case .item(_, let isEraser): return isEraser
            case .tool(let tool): return tool is PKEraserTool
            }
        }
    }

    override private init() {
        super.init()
    }

    /// Attaches a pencil interaction to a view. Each canvas gets its own, so double-tap keeps
    /// working after the first canvas is scrolled away and deallocated.
    public func attach(to view: UIView) {
        observePickerIfNeeded()
        // PKCanvasView may carry PencilKit's own pencil interaction, so look for ours specifically.
        guard !view.interactions.contains(where: { ($0 as? UIPencilInteraction)?.delegate === self }) else { return }
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        view.addInteraction(interaction)
    }

    private func observePickerIfNeeded() {
        guard !isObservingPicker else { return }
        isObservingPicker = true
        let picker = PencilCanvasContainer.sharedToolPicker()
        picker.addObserver(self)
        current = Self.selection(of: picker)
        if let current, !current.isEraser { lastDrawing = current }
    }

    // MARK: Picker observation

    @available(iOS 18.0, *)
    public func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        selectionDidChange(toolPicker)
    }

    public func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
        // On iPadOS 18+ the item callback above covers this; don't count changes twice.
        if #available(iOS 18.0, *) { return }
        selectionDidChange(toolPicker)
    }

    private func selectionDidChange(_ picker: PKToolPicker) {
        toolChangeCount += 1
        previous = current
        current = Self.selection(of: picker)
        if let current, !current.isEraser { lastDrawing = current }
    }

    private static func selection(of picker: PKToolPicker) -> ToolRef {
        if #available(iOS 18.0, *) {
            let item = picker.selectedToolItem
            return .item(item.identifier, isEraser: item is PKToolPickerEraserItem)
        }
        return .tool(picker.selectedTool)
    }

    // MARK: Double-tap

    public func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        // Several interactions may report the same physical tap; handle it once.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTapTime > 0.2 else { return }
        lastTapTime = now

        let action = UIPencilInteraction.preferredTapAction
        let picker = PencilCanvasContainer.sharedToolPicker()
        log.debug("Double-tap: action=\(action.rawValue) pickerVisible=\(picker.isVisible)")
        switch action {
        case .ignore, .showColorPalette, .showInkAttributes:
            return
        default:
            break
        }
        guard !picker.isVisible else { return }

        // In case the picker handled the tap anyway, give it a moment and only toggle if it didn't.
        let countAtTap = toolChangeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            guard self.toolChangeCount == countAtTap else {
                self.log.debug("Double-tap: picker already switched tools")
                return
            }
            self.toggleTool(alwaysToEraser: action != .switchPrevious)
        }
    }

    private func toggleTool(alwaysToEraser: Bool) {
        let picker = PencilCanvasContainer.sharedToolPicker()
        let target: ToolRef?
        if current?.isEraser == true {
            target = (alwaysToEraser ? lastDrawing : previous) ?? lastDrawing
        } else if alwaysToEraser || previous == nil {
            target = eraser(in: picker)
        } else {
            target = previous
        }
        guard let target else {
            log.debug("Double-tap: nothing to switch to")
            return
        }
        select(target, in: picker)
    }

    private func eraser(in picker: PKToolPicker) -> ToolRef {
        if #available(iOS 18.0, *) {
            if let item = picker.toolItems.first(where: { $0 is PKToolPickerEraserItem }) {
                return .item(item.identifier, isEraser: true)
            }
        }
        return .tool(PKEraserTool(.vector))
    }

    private func select(_ ref: ToolRef, in picker: PKToolPicker) {
        let countBefore = toolChangeCount
        switch ref {
        case .item(let identifier, _):
            if #available(iOS 18.0, *) {
                picker.selectedToolItemIdentifier = identifier
            }
        case .tool(let tool):
            picker.selectedTool = tool
        }
        // Programmatic changes may not be reported to observers; keep the history in sync anyway.
        if toolChangeCount == countBefore {
            selectionDidChange(picker)
        }
        log.debug("Double-tap: switched to \(ref.isEraser ? "eraser" : "drawing tool")")
    }
}
