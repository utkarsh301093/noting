import SwiftUI
import PencilKit

/// State for the GoodNotes-style Zoom Window: which region of the page is magnified, and how much.
/// All geometry is in the page's logical coordinates (see `PageGeometry`).
public final class ZoomWindowState: ObservableObject {
    private static let magnificationKey = "folio.zoomMagnification"
    public static let maxMagnification: CGFloat = 6

    @Published public var isVisible: Bool = false
    /// Top-left corner of the magnified region on the page.
    @Published public var origin: CGPoint = CGPoint(x: 80, y: 120)
    /// How much the dock enlarges the region. The region's size follows from this and the dock's size.
    @Published public private(set) var magnification: CGFloat
    /// On-screen size of the dock's writing area, reported by the dock.
    @Published public var dockSize: CGSize = CGSize(width: 900, height: 250) {
        didSet { setMagnification(magnification) }
    }
    @Published public var autoAdvanceTriggered: Bool = false
    /// Bumped whenever the region jumps by navigation (not by dragging), so the page can scroll to follow it.
    @Published public private(set) var navigationCount: Int = 0
    /// Logical size of the page being written on, used to keep the region on the page.
    @Published public var pageSize: CGSize = PageGeometry.notebookSize {
        didSet { setMagnification(magnification) }
    }
    /// Where a new line starts: the ruled margin on notebook pages, the page edge on PDFs.
    public var leftMarginX: CGFloat = 80

    public var regionSize: CGSize {
        CGSize(width: dockSize.width / magnification, height: dockSize.height / magnification)
    }

    public var targetRect: CGRect {
        CGRect(origin: origin, size: regionSize)
    }

    public init() {
        let saved = CGFloat(UserDefaults.standard.double(forKey: Self.magnificationKey))
        magnification = saved > 0 ? saved : 2.8
    }

    /// Smallest magnification that still keeps the region on the page.
    private var minMagnification: CGFloat {
        max(1.2, dockSize.width / max(pageSize.width, 1), dockSize.height / max(pageSize.height, 1))
    }

    public func setMagnification(_ value: CGFloat) {
        let clamped = min(max(value, minMagnification), Self.maxMagnification)
        if clamped != magnification {
            magnification = clamped
            UserDefaults.standard.set(Double(clamped), forKey: Self.magnificationKey)
        }
        clamp()
    }

    /// Resize the region on the page (keeping its top-left corner); the dock's magnification follows.
    public func resizeRegion(toWidth width: CGFloat) {
        setMagnification(dockSize.width / max(width, 1))
    }

    public func move(to point: CGPoint) {
        origin = point
        clamp()
    }

    /// Put the region at the start of the line nearest `y`.
    public func moveToLine(near y: CGFloat, lineHeight: CGFloat) {
        let snapped = (y / lineHeight).rounded() * lineHeight
        navigate(to: CGPoint(x: leftMarginX, y: snapped))
    }

    /// Put the region at the start of the page's first line.
    public func moveToPageStart(lineHeight: CGFloat) {
        navigate(to: CGPoint(x: leftMarginX, y: lineHeight))
    }

    private func navigate(to point: CGPoint) {
        move(to: point)
        navigationCount += 1
    }

    private var isAtLineEnd: Bool { origin.x + regionSize.width >= pageSize.width - 1 }
    private var isAtLineStart: Bool { origin.x <= leftMarginX + 1 }
    private var isAtPageBottom: Bool { origin.y >= pageSize.height - regionSize.height - 1 }

    /// Step right along the line; at the end of the line, wrap to the next one.
    /// Returns false when there's no room left on this page.
    @discardableResult
    public func advanceRight(lineHeight: CGFloat) -> Bool {
        autoAdvanceTriggered = false
        if isAtLineEnd {
            return nextLine(lineHeight: lineHeight)
        }
        navigate(to: CGPoint(x: origin.x + regionSize.width * 0.75, y: origin.y))
        return true
    }

    /// Step left along the line; at the start of the line, go back to the end of the previous one.
    public func advanceLeft(lineHeight: CGFloat) {
        autoAdvanceTriggered = false
        if isAtLineStart {
            guard origin.y - lineHeight >= 0 else { return }
            navigate(to: CGPoint(x: pageSize.width, y: origin.y - lineHeight))
        } else {
            navigate(to: CGPoint(x: max(leftMarginX, origin.x - regionSize.width * 0.75), y: origin.y))
        }
    }

    /// Returns false when there's no room left on this page.
    @discardableResult
    public func nextLine(lineHeight: CGFloat) -> Bool {
        autoAdvanceTriggered = false
        guard !isAtPageBottom else { return false }
        navigate(to: CGPoint(x: leftMarginX, y: origin.y + lineHeight))
        return true
    }

    private func clamp() {
        let size = regionSize
        let maxX = max(0, pageSize.width - size.width)
        let maxY = max(0, pageSize.height - size.height)
        let clamped = CGPoint(x: min(max(0, origin.x), maxX), y: min(max(0, origin.y), maxY))
        if clamped != origin {
            origin = clamped
        }
    }
}

/// Magnified writing dock at the bottom of the screen. It's a second canvas bound to the same page
/// drawing, zoomed into the target region — ink appears on the page as you write, and anything
/// already on the page shows up here.
public struct ZoomWritingWindowView: View {
    @ObservedObject public var state: ZoomWindowState
    let templateType: PaperTemplateType
    let paperColor: PaperColor
    /// PDF page shown behind the ink, if this is a PDF page.
    let pdfURL: URL?
    let pdfPageIndex: Int?
    @Binding var drawing: PKDrawing
    let isPencilOnly: Bool
    let snapsToShapes: Bool
    let isDark: Bool
    let controller: CanvasController
    let onDrawingChanged: (PKDrawing) -> Void
    /// Called when Right / Next Line runs out of room on this page.
    let onReachPageEnd: () -> Void

    @State private var knownStrokeCount: Int = 0
    @State private var autoAdvanceWork: DispatchWorkItem?

    /// Writing past this fraction of the dock's width moves the region right after a short pause.
    private let autoAdvanceRatio: CGFloat = 0.82

    private var isPdfPage: Bool { pdfURL != nil && pdfPageIndex != nil }
    private var inkIsDark: Bool { !isPdfPage && paperColor.isDark }

    public var body: some View {
        VStack(spacing: 0) {
            header

            GeometryReader { geo in
                let m = state.magnification
                ZStack(alignment: .topLeading) {
                    // 1. The page's own background, magnified to the same region
                    if let url = pdfURL, let index = pdfPageIndex {
                        PDFPageBackgroundView(pdfURL: url, pageIndex: index)
                            .frame(width: state.pageSize.width * m, height: state.pageSize.height * m)
                            .offset(x: -state.origin.x * m, y: -state.origin.y * m)
                    } else {
                        PaperBackgroundView(
                            templateType: templateType,
                            paperColor: paperColor,
                            contentScale: m,
                            pageSize: state.pageSize,
                            visibleOrigin: state.origin
                        )
                    }

                    // 2. Auto-advance guide
                    AutoAdvanceZoneOverlay(
                        width: geo.size.width,
                        height: geo.size.height,
                        marginRatio: autoAdvanceRatio,
                        isTriggered: state.autoAdvanceTriggered,
                        isDark: isDark
                    )

                    // 3. The page drawing itself, zoomed into the region
                    PencilCanvasContainer(
                        drawing: $drawing,
                        isPencilOnly: isPencilOnly,
                        controller: controller,
                        onDrawingChanged: { updated in
                            onDrawingChanged(updated)
                            scheduleAutoAdvanceIfNeeded(updated)
                        },
                        contentScale: m,
                        contentOffset: CGPoint(x: state.origin.x * m, y: state.origin.y * m),
                        contentSize: CGSize(width: state.pageSize.width * m, height: state.pageSize.height * m),
                        interfaceStyle: inkIsDark ? .dark : .light,
                        onBeginDrawing: {
                            // Still writing: hold off on moving the region.
                            autoAdvanceWork?.cancel()
                        },
                        snapsToShapes: snapsToShapes
                    )
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .onAppear { state.dockSize = geo.size }
                .onChange(of: geo.size) { state.dockSize = geo.size }
            }
            .frame(height: 250)
        }
        .background(FolioTheme.surface(isDark: isDark))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: -4)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(FolioTheme.accent(isDark: isDark).opacity(0.4), lineWidth: 1)
        )
        .onAppear { knownStrokeCount = drawing.strokes.count }
    }

    private var header: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "plus.magnifyingglass")
                    .foregroundColor(FolioTheme.accent(isDark: isDark))
                    .font(.system(size: 16, weight: .semibold))
                Text("Zoom Window")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FolioTheme.text(isDark: isDark))
            }

            // Magnification is set by resizing the box on the page; this just reports it.
            Text(String(format: "%.1f×", state.magnification))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(FolioTheme.divider(isDark: isDark).opacity(0.5))
                .cornerRadius(6)
                .accessibilityLabel(String(format: "Magnification %.1f times. Drag the corner of the box on the page to change it.", state.magnification))

            Spacer()

            HStack(spacing: 12) {
                roundButton("chevron.left", label: "Move left") {
                    state.advanceLeft(lineHeight: templateType.lineHeight)
                }
                roundButton("chevron.right", label: "Move right") {
                    moveRight()
                }

                Button {
                    autoAdvanceWork?.cancel()
                    withAnimation(.spring(response: 0.3)) {
                        if !state.nextLine(lineHeight: templateType.lineHeight) {
                            onReachPageEnd()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "return")
                            .font(.system(size: 14, weight: .bold))
                        Text("Next Line")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(FolioTheme.accent(isDark: isDark))
                    .foregroundColor(.white)
                    .cornerRadius(16)
                }
                .buttonStyle(PlainButtonStyle())

                Divider().frame(height: 20)

                roundButton("xmark", label: "Close zoom window") {
                    state.isVisible = false
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(Rectangle().fill(FolioTheme.divider(isDark: isDark)).frame(height: 1), alignment: .bottom)
    }

    private func roundButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3)) { action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(FolioTheme.text(isDark: isDark))
                .frame(width: 32, height: 32)
                .background(FolioTheme.divider(isDark: isDark).opacity(0.5))
                .clipShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(label)
    }

    private func moveRight() {
        autoAdvanceWork?.cancel()
        if !state.advanceRight(lineHeight: templateType.lineHeight) {
            onReachPageEnd()
        }
    }

    /// When a new stroke reaches the right-hand zone, slide the region along after a short pause.
    private func scheduleAutoAdvanceIfNeeded(_ updated: PKDrawing) {
        defer { knownStrokeCount = updated.strokes.count }
        guard updated.strokes.count > knownStrokeCount, let last = updated.strokes.last else { return }
        let triggerX = state.origin.x + state.regionSize.width * autoAdvanceRatio
        guard last.renderBounds.maxX >= triggerX else { return }

        state.autoAdvanceTriggered = true
        autoAdvanceWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                moveRight()
            }
        }
        autoAdvanceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
}

/// Visual guide showing where writing triggers the region to move right.
struct AutoAdvanceZoneOverlay: View {
    let width: CGFloat
    let height: CGFloat
    let marginRatio: CGFloat
    let isTriggered: Bool
    let isDark: Bool

    var body: some View {
        let marginX = width * marginRatio
        let accent = FolioTheme.accent(isDark: isDark)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(accent.opacity(isTriggered ? 0.12 : 0.04))
                .frame(width: width - marginX, height: height)
                .offset(x: marginX)

            Path { path in
                path.move(to: CGPoint(x: marginX, y: 0))
                path.addLine(to: CGPoint(x: marginX, y: height))
            }
            .stroke(accent.opacity(isTriggered ? 0.9 : 0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - Target Box Overlay on Main Canvas

/// Draggable frame on the page showing which region the Zoom Window is magnifying. The corner
/// handle (like an iPadOS window's) resizes the region, which sets the dock's magnification.
public struct TargetBoxOverlay: View {
    @ObservedObject public var state: ZoomWindowState
    let isDark: Bool

    @State private var dragStartOrigin: CGPoint?
    @State private var resizeStartWidth: CGFloat?
    @State private var isResizing = false

    public init(state: ZoomWindowState, isDark: Bool) {
        self.state = state
        self.isDark = isDark
    }

    public var body: some View {
        let rect = state.targetRect
        let accent = FolioTheme.accent(isDark: isDark)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .stroke(accent, lineWidth: 2.0)
                .background(accent.opacity(0.08))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let start = dragStartOrigin ?? state.origin
                            dragStartOrigin = start
                            state.move(to: CGPoint(
                                x: start.x + value.translation.width,
                                y: start.y + value.translation.height
                            ))
                        }
                        .onEnded { _ in dragStartOrigin = nil }
                )

            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(accent)
                .clipShape(Circle())
                .position(x: rect.maxX - 10, y: rect.minY + 10)
                .allowsHitTesting(false)

            if isResizing {
                Text(String(format: "%.1f×", state.magnification))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(accent))
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }

            resizeHandle(accent: accent)
                .position(x: rect.maxX, y: rect.maxY)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let startWidth = resizeStartWidth ?? state.regionSize.width
                            resizeStartWidth = startWidth
                            isResizing = true
                            // Follow whichever direction the finger moves further; the box keeps the dock's shape.
                            let aspect = state.dockSize.width / max(state.dockSize.height, 1)
                            let dx = value.translation.width
                            let dy = value.translation.height * aspect
                            state.resizeRegion(toWidth: startWidth + (abs(dx) >= abs(dy) ? dx : dy))
                        }
                        .onEnded { _ in
                            resizeStartWidth = nil
                            withAnimation(.easeOut(duration: 0.2)) { isResizing = false }
                        }
                )
                .accessibilityLabel("Resize zoom region")
        }
    }

    /// A rounded corner bracket hugging the box's bottom-right corner, with a larger touch target.
    private func resizeHandle(accent: Color) -> some View {
        // The frame is centred on the corner (20, 20); the bracket sits just outside it.
        Path { path in
            path.move(to: CGPoint(x: 25, y: 4))
            path.addQuadCurve(to: CGPoint(x: 4, y: 25), control: CGPoint(x: 25, y: 25))
        }
        .stroke(accent.opacity(isResizing ? 1 : 0.85), style: StrokeStyle(lineWidth: isResizing ? 6 : 5, lineCap: .round))
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
}
