import SwiftUI
import ReadrKit

#if canImport(PDFKit)
import PDFKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The shared brain of the native PDF reader: owns all `PDFView` wiring —
/// selection menu, highlight overlays, page tracking, outline, search — so the
/// SwiftUI layer stays declarative. One instance lives per `PDFReaderView`
/// (`@StateObject`); the representable attaches its `PDFView` here, which is
/// how AppKit/UIKit callbacks and SwiftUI-observed state land on one object.
@MainActor
final class PDFReaderController: NSObject, ObservableObject {

    // MARK: Published state

    /// Zero-based index of the page under the reading position.
    @Published private(set) var currentPageIndex = 0
    @Published private(set) var pageCount = 0
    /// Highlight whose note is being edited — drives the note sheet.
    @Published var pendingNote: PDFHighlight?
    /// True when `pendingNote` was just created by the Note action, so
    /// cancelling the sheet should undo the highlight too. Editing an
    /// existing highlight's note must never delete it on cancel.
    private(set) var pendingNoteIsNew = false
    /// Which annotation menu is up. macOS presents it as an `NSPopover`; iOS
    /// renders a floating bar from this state. Published on both platforms
    /// because menu actions route by this context.
    @Published private(set) var activeMenu: MenuContext?

    enum MenuContext: Equatable {
        /// A fresh text selection: color click creates the highlight.
        case create
        /// A click on an existing highlight: recolor/note/remove it.
        case edit(PDFHighlight)
    }

    // MARK: Wiring (set by the representable)

    weak var pdfView: PDFView?
    weak var model: AppModel?
    var book: Book?
    var onAsk: ((Selection) -> Void)?

    // MARK: Private state

    private var loadedURL: URL?
    /// Live PDFKit annotations per stored highlight, so recolor/remove update
    /// pages in place without reloading the document. The PDF *file* is never
    /// mutated — overlays exist only on the in-memory `PDFDocument`.
    private var overlayAnnotations: [UUID: [PDFAnnotation]] = [:]
    private var selectionDebounce: Task<Void, Never>?
    private var positionSaveDebounce: Task<Void, Never>?
    /// The selection the create menu was anchored to, captured when the menu
    /// appears so its actions aren't at the mercy of later selection changes.
    private var pendingSelection: PDFSelection?
    /// Set when the next selection change is programmatic (search navigation)
    /// and must not raise the create menu.
    private var suppressSelectionMenu = false
    private var lastSavedPageIndex: Int?

    /// Last color picked, used when Note creates a highlight without an
    /// explicit color choice. Persisted so it survives relaunches — same key
    /// the text reader uses, so both modes share one "last color".
    private var lastUsedColor: HighlightColor {
        get {
            UserDefaults.standard.string(forKey: "lastHighlightColor")
                .flatMap(HighlightColor.init(rawValue:)) ?? .yellow
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lastHighlightColor") }
    }

    #if canImport(AppKit) && !canImport(UIKit)
    /// One reusable popover + hosting controller for the annotation menu —
    /// creating a fresh NSPopover per selection leaks window resources.
    private lazy var menuHost: NSHostingController<AnyView> = {
        let host = NSHostingController<AnyView>(rootView: AnyView(EmptyView()))
        host.sizingOptions = .preferredContentSize
        return host
    }()
    private lazy var menuPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = menuHost
        return popover
    }()
    #endif

    deinit {
        NotificationCenter.default.removeObserver(self)
        selectionDebounce?.cancel()
        positionSaveDebounce?.cancel()
    }

    // MARK: Attachment & document loading

    func attach(_ view: PDFView) {
        // Re-attaching (SwiftUI recreated the platform view) must not leave
        // observers or overlay bookkeeping pointed at the dead view/document.
        NotificationCenter.default.removeObserver(self)
        pdfView = view
        loadedURL = nil
        overlayAnnotations = [:]

        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        // Sharper page tiles at rest — the default interpolation left pages
        // caught mid-tiling looking soft (seen in the CI walk's page 2).
        view.interpolationQuality = .high

        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionDidChange(_:)),
            name: .PDFViewSelectionChanged, object: view
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageDidChange(_:)),
            name: .PDFViewPageChanged, object: view
        )
        installTapRecognizer(on: view)
    }

    /// Load the document once per URL. `PDFDocument.documentURL` can't be
    /// compared against our URL directly: PDFKit reports resolved paths
    /// (`/private/var/…`) while ours go through the `/var` symlink, so raw
    /// equality never matches and the reader would reset to page 1 on every
    /// SwiftUI update. Also prevents retry-loops when a document fails to load.
    func loadIfNeeded(url: URL) {
        guard let pdfView else { return }
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        guard loadedURL != target else { return }
        loadedURL = target
        pdfView.document = PDFDocument(url: url)
        // Everything else is deferred one runloop: loadIfNeeded runs inside
        // SwiftUI's update pass (make/updateView) where publishing is not
        // allowed (overlay rebuilding can fault the model's highlight cache,
        // which publishes), and PDFView finishes its own initial layout after
        // the document is set — an immediate go(to:) would be overridden by
        // that layout pass.
        DispatchQueue.main.async { [weak self] in
            self?.rebuildOverlays()
            self?.restorePosition()
            self?.refreshPageState()
        }
    }

    private func restorePosition() {
        guard let pdfView, let document = pdfView.document,
              let model, let book,
              let saved = model.position(for: book)?.pdfPageIndex,
              let page = document.page(at: max(0, min(saved, document.pageCount - 1)))
        else { return }
        pdfView.go(to: page)
    }

    // MARK: Page tracking & position

    @objc private func pageDidChange(_ note: Notification) {
        refreshPageState()
        schedulePositionSave()
    }

    private func refreshPageState() {
        guard let pdfView, let document = pdfView.document else { return }
        pageCount = document.pageCount
        if let page = pdfView.currentPage {
            currentPageIndex = document.index(for: page)
        }
    }

    /// Debounce position writes: the store rewrites its JSON on every save,
    /// so a fast scroll through many pages should land one write when the
    /// scrolling settles, not one per page.
    private func schedulePositionSave() {
        guard currentPageIndex != lastSavedPageIndex else { return }
        positionSaveDebounce?.cancel()
        positionSaveDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.persistPosition()
        }
    }

    /// Write the position immediately — called when the reader disappears so
    /// a pending debounce can't drop the last page turn.
    func flushPosition() {
        positionSaveDebounce?.cancel()
        persistPosition()
    }

    private func persistPosition() {
        // Skipping repeats keeps continuous scrolling cheap.
        guard let model, let book, currentPageIndex != lastSavedPageIndex else { return }
        lastSavedPageIndex = currentPageIndex
        // PDF and text mode share one ReadingPosition per book: update only
        // the PDF page so switching back to text mode restores its spot.
        var position = model.position(for: book) ?? ReadingPosition(chapterIndex: 0)
        position.pdfPageIndex = currentPageIndex
        model.savePosition(position, for: book)
    }

    // MARK: Highlight overlays

    private func rebuildOverlays() {
        for annotations in overlayAnnotations.values {
            for annotation in annotations {
                annotation.page?.removeAnnotation(annotation)
            }
        }
        overlayAnnotations = [:]
        guard let model, let book, let document = pdfView?.document else { return }
        for highlight in model.pdfHighlights(for: book) {
            addOverlay(for: highlight, in: document)
        }
    }

    private func addOverlay(for highlight: PDFHighlight, in document: PDFDocument) {
        guard (0..<document.pageCount).contains(highlight.pageIndex),
              let page = document.page(at: highlight.pageIndex) else { return }
        var annotations: [PDFAnnotation] = []
        for rect in highlight.lineRects {
            let annotation = PDFAnnotation(
                bounds: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                forType: .highlight,
                withProperties: nil
            )
            annotation.color = Self.overlayColor(for: highlight.color)
            page.addAnnotation(annotation)
            annotations.append(annotation)
        }
        overlayAnnotations[highlight.id] = annotations
    }

    /// Marker color on PDF pages. Stronger alpha than the text reader's
    /// markers: PDF paper is rendered artwork, not a theme background, so the
    /// text-mode 0.35 washes out here.
    private static func overlayColor(for color: HighlightColor) -> PlatformColor {
        ReadingTheme.markerBase(color).withAlphaComponent(0.45)
    }

    func recolorHighlight(_ highlight: PDFHighlight, to color: HighlightColor) {
        guard let model else { return }
        var updated = highlight
        updated.color = color
        model.updatePDFHighlight(updated)
        lastUsedColor = color
        for annotation in overlayAnnotations[highlight.id] ?? [] {
            annotation.color = Self.overlayColor(for: color)
        }
        setNeedsRedraw()
    }

    func removeHighlight(_ highlight: PDFHighlight) {
        model?.removePDFHighlight(highlight)
        for annotation in overlayAnnotations[highlight.id] ?? [] {
            annotation.page?.removeAnnotation(annotation)
        }
        overlayAnnotations[highlight.id] = nil
        setNeedsRedraw()
        dismissMenu()
    }

    private func setNeedsRedraw() {
        #if canImport(UIKit)
        pdfView?.setNeedsDisplay()
        #elseif canImport(AppKit)
        pdfView?.needsDisplay = true
        #endif
    }

    // MARK: Selection → create menu

    @objc private func selectionDidChange(_ note: Notification) {
        selectionDebounce?.cancel()
        selectionDebounce = Task { [weak self] in
            // Debounce so the menu appears when the drag settles, not on
            // every extension of an in-progress selection.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.selectionDidSettle()
        }
    }

    /// The single definition of "there is a selection worth acting on" —
    /// shared by the menu presentation and the keyboard shortcuts so the two
    /// paths can't diverge on what counts as selected.
    private static func hasText(_ selection: PDFSelection) -> Bool {
        !(selection.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func selectionDidSettle() {
        if suppressSelectionMenu {
            suppressSelectionMenu = false
            return
        }
        guard let pdfView,
              let selection = pdfView.currentSelection,
              Self.hasText(selection)
        else {
            // Selection cleared (click elsewhere, Escape): tear the menu down.
            if activeMenu == .create { dismissMenu() }
            return
        }
        pendingSelection = selection
        presentMenu(.create, anchoredTo: anchorRect(for: selection))
    }

    private func anchorRect(for selection: PDFSelection) -> CGRect {
        guard let pdfView, let page = selection.pages.first else { return .zero }
        return pdfView.convert(selection.bounds(for: page), from: page)
    }

    // MARK: Menu presentation

    private func presentMenu(_ context: MenuContext, anchoredTo rect: CGRect) {
        activeMenu = context
        #if canImport(UIKit)
        _ = rect // iOS floats a bar above the bottom edge; no anchor needed.
        #elseif canImport(AppKit)
        guard let pdfView, rect != .zero else { return }
        menuHost.rootView = AnyView(menuView(for: context).padding(2))
        // AppKit popovers follow NSApp.effectiveAppearance, not the window's
        // pinned (theme-derived) scheme — adopt the PDF view's appearance so
        // the frame can't clash with the paper.
        menuPopover.appearance = pdfView.effectiveAppearance
        // .minY is the visual top edge (PDFView is flipped), so the menu sits
        // above the selection like Apple Books; AppKit flips it below when
        // there's no room.
        menuPopover.show(
            relativeTo: rect.insetBy(dx: -4, dy: -4),
            of: pdfView,
            preferredEdge: .minY
        )
        #endif
    }

    func dismissMenu() {
        activeMenu = nil
        pendingSelection = nil
        #if canImport(AppKit) && !canImport(UIKit)
        if menuPopover.isShown { menuPopover.performClose(nil) }
        #endif
    }

    /// The shared annotation menu wired back to this controller. macOS hosts
    /// it in the popover; iOS renders it inside the floating bottom bar.
    ///
    /// Every action captures `context` directly: routing through the published
    /// `activeMenu` drops clicks, because `popoverDidClose` nils it before the
    /// button action runs. `activeMenu` only drives presentation state now.
    func menuView(for context: MenuContext) -> AnnotationMenuView {
        switch context {
        case .create:
            return AnnotationMenuView(
                mode: .create,
                onHighlight: { [weak self] color in
                    self?.createHighlightsFromPendingSelection(color: color)
                },
                onNote: { [weak self] in
                    self?.noteCurrentSelection()
                },
                onAsk: { [weak self] in
                    guard let self else { return }
                    if let built = self.askCurrentSelection() {
                        self.onAsk?(built)
                    } else {
                        self.dismissMenu()
                    }
                },
                onCopy: { [weak self] in
                    guard let self else { return }
                    let text = self.pendingSelection?.string ?? ""
                    if !text.isEmpty { Pasteboard.copy(text) }
                    self.finishSelectionAction()
                },
                onRemove: nil
            )
        case .edit(let highlight):
            return AnnotationMenuView(
                mode: .edit(
                    currentColor: highlight.color,
                    hasNote: !(highlight.note ?? "").isEmpty
                ),
                onHighlight: { [weak self] color in
                    self?.recolorHighlight(highlight, to: color)
                    self?.dismissMenu()
                },
                onNote: { [weak self] in
                    self?.dismissMenu()
                    self?.pendingNoteIsNew = false
                    self?.pendingNote = highlight
                },
                onAsk: { [weak self] in
                    guard let self else { return }
                    self.dismissMenu()
                    let page = self.pdfView?.document?.page(at: highlight.pageIndex)
                    self.onAsk?(self.askSelection(
                        quoted: highlight.quotedText,
                        page: page,
                        pageIndex: highlight.pageIndex
                    ))
                },
                onCopy: { [weak self] in
                    Pasteboard.copy(highlight.quotedText)
                    self?.dismissMenu()
                },
                onRemove: { [weak self] in self?.removeHighlight(highlight) }
            )
        }
    }

    // MARK: Creating highlights

    /// Store the pending selection as highlights: per-line page-space rects,
    /// grouped by page so a selection spanning a page break becomes one stored
    /// highlight per page touched. Overlays are added immediately — no reload.
    @discardableResult
    private func createHighlightsFromPendingSelection(color: HighlightColor) -> [PDFHighlight] {
        guard let model, let book, let document = pdfView?.document,
              let selection = pendingSelection
        else {
            dismissMenu()
            return []
        }
        lastUsedColor = color

        var rectsByPage: [Int: [PDFRect]] = [:]
        var linesByPage: [Int: [String]] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let index = document.index(for: page)
                rectsByPage[index, default: []].append(
                    PDFRect(x: bounds.origin.x, y: bounds.origin.y,
                            width: bounds.width, height: bounds.height)
                )
                if let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    linesByPage[index, default: []].append(text)
                }
            }
        }

        var created: [PDFHighlight] = []
        for (pageIndex, rects) in rectsByPage.sorted(by: { $0.key < $1.key }) {
            let quoted = linesByPage[pageIndex]?.joined(separator: " ")
                ?? (selection.string ?? "")
            let highlight = PDFHighlight(
                bookID: book.id,
                pageIndex: pageIndex,
                lineRects: rects,
                quotedText: quoted,
                color: color,
                createdAt: Date()
            )
            model.addPDFHighlight(highlight)
            addOverlay(for: highlight, in: document)
            created.append(highlight)
        }
        finishSelectionAction()
        return created
    }

    /// Wrap up a create-menu action: drop the selection and close the menu.
    private func finishSelectionAction() {
        pdfView?.clearSelection()
        dismissMenu()
    }

    // MARK: Selection actions (annotation menu + keyboard shortcuts)

    /// The selection an action should act on: the live PDFView selection (a
    /// keyboard shortcut can fire before the menu's debounce settles), falling
    /// back to the one the menu captured when it appeared.
    private func committedSelection() -> PDFSelection? {
        if let current = pdfView?.currentSelection, Self.hasText(current) {
            return current
        }
        return pendingSelection
    }

    /// ⇧⌘H: highlight the current selection in the last-used color — the
    /// keyboard equivalent of the menu's color dots. No-op without a selection.
    func highlightCurrentSelection() {
        guard let selection = committedSelection() else { return }
        pendingSelection = selection
        createHighlightsFromPendingSelection(color: lastUsedColor)
    }

    /// Highlight the current selection and open its note editor — the menu's
    /// Note action and the ⇧⌘M shortcut. No-op without a selection.
    /// Note implies a highlight (Apple Books behavior): it's created in the
    /// last-used color first, and `pendingNoteIsNew` tells the sheet that
    /// cancelling must undo exactly that highlight.
    func noteCurrentSelection() {
        guard let selection = committedSelection() else { return }
        pendingSelection = selection
        guard let created = createHighlightsFromPendingSelection(
            color: lastUsedColor
        ).first else { return }
        pendingNoteIsNew = true
        pendingNote = created
    }

    /// The Ask `Selection` for the current PDF selection — the menu's ✦ Ask
    /// and the ⇧⌘A shortcut. Nil when nothing is selected, so the caller can
    /// fall back to a whole-book ask. Dismisses the menu but KEEPS the PDF
    /// selection (like the text reader), so cancelling the Ask sheet leaves
    /// the selection usable for a follow-up highlight or note.
    func askCurrentSelection() -> Selection? {
        guard let selection = committedSelection() else { return nil }
        let built = askSelection(quoted: selection.string ?? "", page: selection.pages.first)
        dismissMenu()
        return built
    }

    // MARK: Tap/click → edit menu

    private func installTapRecognizer(on view: PDFView) {
        #if canImport(UIKit)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapGesture(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
        #elseif canImport(AppKit)
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClickGesture(_:)))
        // Don't hold back PDFView's own mouse handling (selection, links).
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)
        #endif
    }

    #if canImport(UIKit)
    @objc private func handleTapGesture(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let pdfView else { return }
        handleTap(at: gesture.location(in: pdfView))
    }
    #elseif canImport(AppKit)
    @objc private func handleClickGesture(_ gesture: NSClickGestureRecognizer) {
        guard let pdfView else { return }
        handleTap(at: gesture.location(in: pdfView))
    }
    #endif

    /// A click/tap with no text selected either opens the edit menu for the
    /// highlight under the point, or dismisses whatever menu is up.
    private func handleTap(at point: CGPoint) {
        guard let pdfView, let document = pdfView.document,
              let model, let book else { return }
        // A click that just finished making a selection belongs to the create
        // flow — the debounced selection handler owns that.
        let selected = pdfView.currentSelection?.string ?? ""
        guard selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let page = pdfView.page(for: point, nearest: true) else { return }
        let pageIndex = document.index(for: page)
        let pagePoint = pdfView.convert(point, to: page)

        let hit = model.pdfHighlights(for: book).first { highlight in
            highlight.pageIndex == pageIndex && highlight.lineRects.contains { rect in
                CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
                    .insetBy(dx: -3, dy: -3) // forgiving hit target
                    .contains(pagePoint)
            }
        }
        guard let hit else {
            if activeMenu != nil { dismissMenu() }
            return
        }
        presentMenu(.edit(hit), anchoredTo: editAnchorRect(for: hit, on: page))
    }

    private func editAnchorRect(for highlight: PDFHighlight, on page: PDFPage) -> CGRect {
        guard let pdfView else { return .zero }
        var union = CGRect.null
        for rect in highlight.lineRects {
            union = union.union(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
        }
        guard !union.isNull else { return .zero }
        return pdfView.convert(union, from: page)
    }

    // MARK: Ask

    /// PDFs have no chapter model, so the Ask `Selection` is synthesized:
    /// quoted text plus ±240 characters of the page's text as the "where you
    /// are" anchor, with "Page N" standing in for the chapter title.
    private func askSelection(quoted: String, page: PDFPage?, pageIndex: Int? = nil) -> Selection {
        let index = pageIndex
            ?? page.flatMap { pdfView?.document?.index(for: $0) }
            ?? currentPageIndex
        var surrounding = quoted
        if !quoted.isEmpty,
           let pageText = page?.string,
           let range = pageText.range(of: quoted) {
            let lower = pageText.index(range.lowerBound, offsetBy: -240, limitedBy: pageText.startIndex)
                ?? pageText.startIndex
            let upper = pageText.index(range.upperBound, offsetBy: 240, limitedBy: pageText.endIndex)
                ?? pageText.endIndex
            surrounding = String(pageText[lower..<upper])
        }
        return Selection(
            chapterID: book?.chapters.first?.id ?? UUID(),
            quotedText: quoted,
            surroundingText: surrounding,
            chapterTitle: "Page \(index + 1)"
        )
    }

    // MARK: Outline (TOC)

    struct OutlineItem: Identifiable {
        let id = UUID()
        let title: String
        /// Nesting level, 0 = top-level chapter.
        let depth: Int
        /// 1-based, for display.
        let pageNumber: Int?
        let destination: PDFDestination?
    }

    /// The document outline flattened for a simple indented list; empty when
    /// the PDF has no outline.
    func outlineItems() -> [OutlineItem] {
        guard let document = pdfView?.document, let root = document.outlineRoot else { return [] }
        var items: [OutlineItem] = []
        appendChildren(of: root, depth: 0, document: document, to: &items)
        return items
    }

    private func appendChildren(
        of outline: PDFOutline, depth: Int,
        document: PDFDocument, to items: inout [OutlineItem]
    ) {
        guard depth <= 6 else { return } // malformed outlines can recurse deeply
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index) else { continue }
            let label = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let page = child.destination?.page
            items.append(OutlineItem(
                title: label.isEmpty ? "Untitled section" : label,
                depth: depth,
                pageNumber: page.map { document.index(for: $0) + 1 },
                destination: child.destination
            ))
            appendChildren(of: child, depth: depth + 1, document: document, to: &items)
        }
    }

    func jump(to item: OutlineItem) {
        guard let destination = item.destination else { return }
        pdfView?.go(to: destination)
    }

    func goToPage(_ index: Int) {
        guard let document = pdfView?.document, document.pageCount > 0,
              let page = document.page(at: max(0, min(index, document.pageCount - 1)))
        else { return }
        pdfView?.go(to: page)
    }

    // MARK: Search

    struct SearchResult: Identifiable {
        let id = UUID()
        /// 1-based, for display.
        let pageNumber: Int
        let snippet: String
        fileprivate let match: PDFSelection
    }

    /// Synchronous find, capped so a common word in a large PDF can't produce
    /// an unbounded result list. Matches are painted via
    /// `highlightedSelections` until `clearSearch()`.
    func search(_ query: String) -> [SearchResult] {
        guard let pdfView, let document = pdfView.document else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            pdfView.highlightedSelections = nil
            return []
        }
        let matches = Array(document.findString(trimmed, withOptions: .caseInsensitive).prefix(200))
        for match in matches {
            match.color = PlatformColor.systemYellow
        }
        pdfView.highlightedSelections = matches
        return matches.map { match in
            let pageIndex = match.pages.first.map { document.index(for: $0) } ?? 0
            return SearchResult(
                pageNumber: pageIndex + 1,
                snippet: Self.snippet(around: match),
                match: match
            )
        }
    }

    /// A little context around the match so the row reads like a sentence
    /// fragment instead of the bare query.
    private static func snippet(around match: PDFSelection) -> String {
        let extended = (match.copy() as? PDFSelection) ?? match
        if extended !== match {
            extended.extend(atStart: 24)
            extended.extend(atEnd: 32)
        }
        let raw = extended.string ?? match.string ?? ""
        return raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func jump(to result: SearchResult) {
        guard let pdfView else { return }
        // Programmatic selection must not raise the annotation menu.
        suppressSelectionMenu = true
        pdfView.setCurrentSelection(result.match, animate: true)
        pdfView.go(to: result.match)
    }

    func clearSearch() {
        pdfView?.highlightedSelections = nil
    }
}

#if canImport(UIKit)
extension PDFReaderController: UIGestureRecognizerDelegate {
    /// Recognize alongside PDFView's own gestures so taps still drive link
    /// navigation and selection handles normally.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#elseif canImport(AppKit)
extension PDFReaderController: NSPopoverDelegate {
    /// Transient popovers close themselves on outside clicks; keep the menu
    /// context in sync so stale state can't route the next action.
    func popoverDidClose(_ notification: Notification) {
        activeMenu = nil
        pendingSelection = nil
    }
}
#endif
#endif
