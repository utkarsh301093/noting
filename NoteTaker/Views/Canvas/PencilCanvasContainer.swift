import SwiftUI
import PencilKit

/// Routes undo/redo to whichever canvas the user most recently drew on.
public final class CanvasController: ObservableObject {
    public weak var canvasView: PKCanvasView?

    public init() {}

    public func undo() {
        canvasView?.undoManager?.undo()
    }

    public func redo() {
        canvasView?.undoManager?.redo()
    }
}

/// Canvas pinned to a fixed zoom and offset. With scrolling disabled, the scrollable content must
/// cover the visible area (so every point is writable) and must not drift.
final class PinnedCanvasView: PKCanvasView {
    var pinnedOffset: CGPoint = .zero
    /// Nil = exactly the visible bounds (a whole page); set for a zoomed-in window onto a page.
    var pinnedContentSize: CGSize?

    override func layoutSubviews() {
        super.layoutSubviews()
        applyPin()
    }

    func applyPin() {
        let size = pinnedContentSize ?? bounds.size
        if contentSize != size {
            contentSize = size
        }
        if contentOffset != pinnedOffset {
            contentOffset = pinnedOffset
        }
    }
}

/// SwiftUI wrapper for PKCanvasView with Apple Pencil support, the shared PKToolPicker, and a
/// fixed logical coordinate space.
///
/// Drawings are stored in logical (unscaled) page coordinates; `contentScale` maps them onto the
/// on-screen size, so strokes stay put when the canvas is resized or rotated. The Zoom Window uses a
/// larger scale plus `contentOffset` to show a magnified part of the same drawing.
public struct PencilCanvasContainer: UIViewRepresentable {
    @Binding public var drawing: PKDrawing
    public var isPencilOnly: Bool
    public var controller: CanvasController?
    public var onDrawingChanged: ((PKDrawing) -> Void)?
    /// On-screen points per logical point.
    public var contentScale: CGFloat
    /// Scroll offset in on-screen points (logical origin × scale). Zero for a whole page.
    public var contentOffset: CGPoint
    /// Scrollable size in on-screen points; nil means the visible bounds.
    public var contentSize: CGSize?
    /// Appearance the ink is displayed in: `.light` over light paper and PDFs, `.dark` over dark paper.
    /// PencilKit stores ink in light-mode colors and adapts it for dark display automatically.
    public var interfaceStyle: UIUserInterfaceStyle
    public var showsToolPicker: Bool
    public var onBeginDrawing: (() -> Void)?
    /// Hold the pencil still at the end of a stroke to turn it into a clean line / shape.
    public var snapsToShapes: Bool

    public init(
        drawing: Binding<PKDrawing>,
        isPencilOnly: Bool = true,
        controller: CanvasController? = nil,
        onDrawingChanged: ((PKDrawing) -> Void)? = nil,
        contentScale: CGFloat = 1.0,
        contentOffset: CGPoint = .zero,
        contentSize: CGSize? = nil,
        interfaceStyle: UIUserInterfaceStyle = .unspecified,
        showsToolPicker: Bool = true,
        onBeginDrawing: (() -> Void)? = nil,
        snapsToShapes: Bool = false
    ) {
        self._drawing = drawing
        self.isPencilOnly = isPencilOnly
        self.controller = controller
        self.onDrawingChanged = onDrawingChanged
        self.contentScale = max(contentScale, 0.05)
        self.contentOffset = contentOffset
        self.contentSize = contentSize
        self.interfaceStyle = interfaceStyle
        self.showsToolPicker = showsToolPicker
        self.onBeginDrawing = onBeginDrawing
        self.snapsToShapes = snapsToShapes
    }

    private static var sharedPicker: PKToolPicker?

    /// One tool picker for every canvas, so the selected pen carries across pages, margins and the zoom window.
    public static func sharedToolPicker() -> PKToolPicker {
        if let picker = sharedPicker {
            return picker
        }
        let picker = PKToolPicker()
        sharedPicker = picker
        return picker
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeUIView(context: Context) -> PKCanvasView {
        let canvasView = PinnedCanvasView()
        canvasView.delegate = context.coordinator
        canvasView.isOpaque = false
        canvasView.backgroundColor = .clear
        canvasView.drawingPolicy = isPencilOnly ? .pencilOnly : .anyInput
        canvasView.overrideUserInterfaceStyle = interfaceStyle

        // No internal scrolling or pinch zoom: the outer ScrollView scrolls the pages.
        canvasView.isScrollEnabled = false
        canvasView.bouncesZoom = false
        canvasView.showsVerticalScrollIndicator = false
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.contentInsetAdjustmentBehavior = .never
        context.coordinator.applyGeometry(to: canvasView)

        context.coordinator.withExternalUpdate {
            canvasView.drawing = drawing
        }
        context.coordinator.lastBindingDrawing = drawing
        context.coordinator.canvasView = canvasView
        if controller?.canvasView == nil {
            controller?.canvasView = canvasView
        }

        PencilInteractionManager.shared.attach(to: canvasView)
        context.coordinator.installShapeSnapping(on: canvasView)
        context.coordinator.setupToolPicker(for: canvasView, visible: showsToolPicker)
        return canvasView
    }

    public func updateUIView(_ uiView: PKCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        // Apply the binding only when it actually changed from outside (page load, zoom window,
        // snapping on another canvas). Comparing against the canvas directly would revert strokes
        // whose binding update is still in flight.
        if drawing != coordinator.lastBindingDrawing {
            coordinator.lastBindingDrawing = drawing
            if uiView.drawing != drawing {
                coordinator.withExternalUpdate {
                    uiView.drawing = drawing
                }
            }
        }

        let desiredPolicy: PKCanvasViewDrawingPolicy = isPencilOnly ? .pencilOnly : .anyInput
        if uiView.drawingPolicy != desiredPolicy {
            uiView.drawingPolicy = desiredPolicy
        }
        if uiView.overrideUserInterfaceStyle != interfaceStyle {
            uiView.overrideUserInterfaceStyle = interfaceStyle
        }

        coordinator.applyGeometry(to: uiView)
        coordinator.updateShapeSnapping(enabled: snapsToShapes, pencilOnly: isPencilOnly)
        coordinator.updateToolPickerVisibility(showsToolPicker, for: uiView)

        if controller?.canvasView == nil {
            controller?.canvasView = uiView
        }
    }

    public static func dismantleUIView(_ uiView: PKCanvasView, coordinator: Coordinator) {
        let picker = PencilCanvasContainer.sharedToolPicker()
        picker.setVisible(false, forFirstResponder: uiView)
        picker.removeObserver(uiView)
        uiView.delegate = nil
    }

    public class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
        var parent: PencilCanvasContainer
        weak var canvasView: PKCanvasView?
        var lastBindingDrawing = PKDrawing()
        private var isApplyingExternalUpdate = false
        private var isToolPickerVisible = true

        private var holdRecognizer: ShapeHoldGestureRecognizer?
        private var strokeCountAtStrokeStart = 0
        /// Stroke count before a held stroke; set until that stroke shows up in the drawing.
        private var pendingSnapBaseCount: Int?

        init(_ parent: PencilCanvasContainer) {
            self.parent = parent
            super.init()
        }

        func withExternalUpdate(_ body: () -> Void) {
            isApplyingExternalUpdate = true
            body()
            isApplyingExternalUpdate = false
        }

        // MARK: Geometry

        func applyGeometry(to canvas: PKCanvasView) {
            let scale = parent.contentScale
            if abs(canvas.zoomScale - scale) > 0.0001 ||
                abs(canvas.minimumZoomScale - scale) > 0.0001 ||
                abs(canvas.maximumZoomScale - scale) > 0.0001 {
                // Widen the limits first so the new zoom scale isn't clamped, then pin them.
                canvas.minimumZoomScale = min(canvas.minimumZoomScale, scale)
                canvas.maximumZoomScale = max(canvas.maximumZoomScale, scale)
                canvas.zoomScale = scale
                canvas.minimumZoomScale = scale
                canvas.maximumZoomScale = scale
            }
            if let pinned = canvas as? PinnedCanvasView {
                pinned.pinnedOffset = parent.contentOffset
                pinned.pinnedContentSize = parent.contentSize
                pinned.applyPin()
            }
        }

        // MARK: Tool Picker

        func setupToolPicker(for canvas: PKCanvasView, visible: Bool) {
            let picker = PencilCanvasContainer.sharedToolPicker()
            picker.addObserver(canvas)
            picker.setVisible(visible, forFirstResponder: canvas)
            isToolPickerVisible = visible

            if visible {
                DispatchQueue.main.async { [weak canvas] in
                    guard let canvas = canvas, canvas.window != nil else { return }
                    canvas.becomeFirstResponder()
                }
            }
        }

        func updateToolPickerVisibility(_ visible: Bool, for canvas: PKCanvasView) {
            guard visible != isToolPickerVisible else { return }
            isToolPickerVisible = visible
            PencilCanvasContainer.sharedToolPicker().setVisible(visible, forFirstResponder: canvas)
            if visible && canvas.window != nil && !canvas.isFirstResponder {
                canvas.becomeFirstResponder()
            }
        }

        // MARK: Hold-to-snap

        func installShapeSnapping(on canvas: PKCanvasView) {
            let recognizer = ShapeHoldGestureRecognizer(target: nil, action: nil)
            recognizer.delegate = self
            recognizer.isEnabled = parent.snapsToShapes
            recognizer.allowedTouchTypes = Self.touchTypes(pencilOnly: parent.isPencilOnly)
            recognizer.onStrokeBegan = { [weak self, weak canvas] in
                self?.strokeCountAtStrokeStart = canvas?.drawing.strokes.count ?? 0
            }
            recognizer.onHold = { [weak self] viewPoints in
                self?.snapStrokeInProgress(viewPoints) ?? false
            }
            recognizer.onStrokeEnded = { [weak self] held in
                guard let self = self, held else { return }
                // Fallback if the hold timer couldn't fire mid-stroke: snap the finished stroke.
                // PencilKit may commit it slightly after the touch ends, so snap as soon as it
                // appears (here or in canvasViewDrawingDidChange), and give up shortly after.
                self.pendingSnapBaseCount = self.strokeCountAtStrokeStart
                DispatchQueue.main.async { self.snapPendingStroke() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.pendingSnapBaseCount = nil }
            }
            canvas.addGestureRecognizer(recognizer)
            holdRecognizer = recognizer
        }

        func updateShapeSnapping(enabled: Bool, pencilOnly: Bool) {
            guard let recognizer = holdRecognizer else { return }
            if recognizer.isEnabled != enabled {
                recognizer.isEnabled = enabled
            }
            let types = Self.touchTypes(pencilOnly: pencilOnly)
            if recognizer.allowedTouchTypes != types {
                recognizer.allowedTouchTypes = types
            }
        }

        private static func touchTypes(pencilOnly: Bool) -> [NSNumber] {
            pencilOnly
                ? [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
                : [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
        }

        /// Pencil held still mid-stroke: replace the unfinished freehand stroke with the clean shape
        /// right away, without waiting for the pencil to lift.
        private func snapStrokeInProgress(_ viewPoints: [CGPoint]) -> Bool {
            guard let canvas = canvasView, let tool = canvas.tool as? PKInkingTool else { return false }
            // Touch locations are in the canvas's bounds (which include the scroll offset);
            // dividing by the zoom scale gives drawing coordinates.
            let scale = max(canvas.zoomScale, 0.01)
            let points = viewPoints.map { CGPoint(x: $0.x / scale, y: $0.y / scale) }
            guard let snapped = ShapeSnapper.snappedStroke(fromPoints: points, tool: tool) else { return false }
            
            // End PencilKit's in-progress stroke. Re-enabling right away doesn't pick the current
            // touch back up, so moving or lifting the pencil afterwards draws nothing extra.
            let base = strokeCountAtStrokeStart
            canvas.drawingGestureRecognizer.isEnabled = false
            canvas.drawingGestureRecognizer.isEnabled = true
            
            // Next turn of the run loop: drop the freehand stroke if PencilKit committed it on
            // cancel, and add the shape in its place.
            DispatchQueue.main.async { [weak self, weak canvas] in
                guard let self = self, let canvas = canvas else { return }
                var drawing = canvas.drawing
                drawing.strokes = Array(drawing.strokes.prefix(base)) + [snapped.stroke]
                self.setDrawingUndoably(drawing, on: canvas, actionName: "Snap to Shape")
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            return true
        }
        
        private func snapPendingStroke() {
            guard let base = pendingSnapBaseCount,
                  let canvas = canvasView, canvas.tool is PKInkingTool else { return }
            var drawing = canvas.drawing
            // Wait until exactly one new stroke has been added by this touch.
            guard drawing.strokes.count == base + 1 else { return }
            pendingSnapBaseCount = nil
            guard let last = drawing.strokes.last,
                  let snapped = ShapeSnapper.snappedStroke(from: last) else { return }
            drawing.strokes[drawing.strokes.count - 1] = snapped.stroke
            setDrawingUndoably(drawing, on: canvas, actionName: "Snap to Shape")
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        /// Replaces the canvas drawing as a user edit (saved like any stroke) with undo/redo support.
        private func setDrawingUndoably(_ newDrawing: PKDrawing, on canvas: PKCanvasView, actionName: String) {
            let previous = canvas.drawing
            if let undoManager = canvas.undoManager {
                undoManager.registerUndo(withTarget: canvas) { [weak self] target in
                    self?.setDrawingUndoably(previous, on: target, actionName: actionName)
                }
                undoManager.setActionName(actionName)
            }
            canvas.drawing = newDrawing
        }

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: PKCanvasViewDelegate

        public func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            // Route undo/redo to the canvas being written on, and keep the tool picker attached to it.
            parent.controller?.canvasView = canvasView
            if isToolPickerVisible && !canvasView.isFirstResponder {
                canvasView.becomeFirstResponder()
            }
            PencilCanvasContainer.sharedToolPicker().colorUserInterfaceStyle =
                canvasView.overrideUserInterfaceStyle == .dark ? .dark : .light
            parent.onBeginDrawing?()
        }

        public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Programmatic loads aren't user edits: don't echo them back or re-save them.
            guard !isApplyingExternalUpdate else { return }
            let updated = canvasView.drawing
            lastBindingDrawing = updated
            parent.drawing = updated
            parent.onDrawingChanged?(updated)
            if pendingSnapBaseCount != nil {
                DispatchQueue.main.async { self.snapPendingStroke() }
            }
        }
    }
}
