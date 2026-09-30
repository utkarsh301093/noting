import SwiftUI
import PencilKit

/// State for the GoodNotes-style Zoom Window: which region of the page is magnified, and how much.
/// All geometry is in the page's logical coordinates (see `PageGeometry`).
public final class ZoomWindowState: ObservableObject {
    @Published public var isVisible: Bool = false
    /// Top-left corner of the magnified region on the page.
    @Published public var origin: CGPoint = CGPoint(x: 80, y: 120)
    /// Size of the magnified region; follows from the dock's size and the magnification.
    @Published public var regionSize: CGSize = CGSize(width: 260, height: 90)
    @Published public var magnification: CGFloat = 2.8
    @Published public var autoAdvanceTriggered: Bool = false
    /// Logical size of the page being written on, used to keep the region on the page.
    @Published public var pageSize: CGSize = PageGeometry.notebookSize {
        didSet { clamp() }
    }

    public let leftMarginX: CGFloat = 80

    public var targetRect: CGRect {
        CGRect(origin: origin, size: regionSize)
    }

    public init() {}

    public func move(to point: CGPoint) {
        origin = point
        clamp()
    }

    /// Step right along the line; at the end of the line, wrap to the next one.
    public func advanceRight(lineHeight: CGFloat) {
        if origin.x + regionSize.width >= pageSize.width - 1 {
            nextLine(lineHeight: lineHeight)
        } else {
            move(to: CGPoint(x: origin.x + regionSize.width * 0.75, y: origin.y))
        }
        autoAdvanceTriggered = false
    }

    public func advanceLeft() {
        move(to: CGPoint(x: max(leftMarginX, origin.x - regionSize.width * 0.75), y: origin.y))
        autoAdvanceTriggered = false
    }

    public func nextLine(lineHeight: CGFloat) {
        move(to: CGPoint(x: leftMarginX, y: origin.y + lineHeight))
        autoAdvanceTriggered = false
    }

    private func clamp() {
        let maxX = max(0, pageSize.width - regionSize.width)
        let maxY = max(0, pageSize.height - regionSize.height)
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
                .onAppear { updateRegionSize(for: geo.size) }
                .onChange(of: geo.size) { updateRegionSize(for: geo.size) }
                .onChange(of: state.magnification) { updateRegionSize(for: geo.size) }
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

            // Magnification
            HStack(spacing: 4) {
                ForEach([2.0, 2.8, 3.5], id: \.self) { (scale: CGFloat) in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            state.magnification = scale
                        }
                    } label: {
                        Text(String(format: "%.1f×", scale))
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(state.magnification == scale ? FolioTheme.accent(isDark: isDark) : Color.clear)
                            .foregroundColor(state.magnification == scale ? .white : FolioTheme.textSecondary(isDark: isDark))
                            .cornerRadius(6)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .background(FolioTheme.divider(isDark: isDark).opacity(0.5))
            .cornerRadius(8)

            Spacer()

            HStack(spacing: 12) {
                roundButton("chevron.left", label: "Move left") {
                    state.advanceLeft()
                }
                roundButton("chevron.right", label: "Move right") {
                    state.advanceRight(lineHeight: templateType.lineHeight)
                }

                Button {
                    withAnimation(.spring(response: 0.3)) {
                        state.nextLine(lineHeight: templateType.lineHeight)
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

    private func updateRegionSize(for size: CGSize) {
        let m = max(state.magnification, 0.1)
        let region = CGSize(width: size.width / m, height: size.height / m)
        if region != state.regionSize {
            state.regionSize = region
            state.move(to: state.origin) // keep it on the page
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
                state.advanceRight(lineHeight: templateType.lineHeight)
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

/// Draggable frame on the page showing which region the Zoom Window is magnifying.
public struct TargetBoxOverlay: View {
    @ObservedObject public var state: ZoomWindowState
    let isDark: Bool

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
                            state.move(to: CGPoint(
                                x: value.location.x - state.regionSize.width / 2,
                                y: value.location.y - state.regionSize.height / 2
                            ))
                        }
                )

            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(accent)
                .clipShape(Circle())
                .position(x: rect.maxX - 10, y: rect.minY + 10)
                .allowsHitTesting(false)
        }
    }
}
