import Cocoa
import WebKit
import UniformTypeIdentifiers

let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt"]

enum ViewMode: Int {
    case source = 0, split = 1, preview = 2

    static var saved: ViewMode {
        get {
            guard UserDefaults.standard.object(forKey: "viewMode") != nil else { return .split }
            return ViewMode(rawValue: UserDefaults.standard.integer(forKey: "viewMode")) ?? .split
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "viewMode") }
    }
}

/// Split view whose divider disappears completely when only one pane is shown.
final class PaneSplitView: NSSplitView {
    var showsDivider = true {
        didSet { needsDisplay = true }
    }
    override var dividerThickness: CGFloat { showsDivider ? super.dividerThickness : 0 }
    override func drawDivider(in rect: NSRect) {
        if showsDivider { super.drawDivider(in: rect) }
    }
}

// MARK: - Viewer window

final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                    WKNavigationDelegate, NSSplitViewDelegate, NSTextViewDelegate {
    let fileURL: URL
    var onClose: ((ViewerWindowController) -> Void)?

    private let splitView = PaneSplitView()
    private let textScroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { textScroll.documentView as! NSTextView }
    private let webView: WKWebView
    private let modeControl = NSSegmentedControl(
        labels: ["Source", "Split", "Preview"], trackingMode: .selectOne, target: nil, action: nil)
    private var mode = ViewMode.saved
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingScrollY: Double = 0
    private var isLoadingPreview = false
    /// The file's contents as last seen on disk.
    private var lastText: String?
    private var hasLoaded = false

    private let editButton = NSButton(title: "Edit", target: nil, action: nil)
    private var isEditing = false
    private var isDirty = false
    private var isPromptingConflict = false
    private var renderWork: DispatchWorkItem?

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: config)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init(window: window)

        window.title = fileURL.lastPathComponent
        window.representedURL = self.fileURL
        window.delegate = self
        window.minSize = NSSize(width: 480, height: 320)
        window.tabbingMode = .preferred
        window.setFrameAutosaveName("ViewerWindow")
        if window.frame.origin == .zero { window.center() }

        buildContent()
        buildToolbar()
        reload()
        startWatching()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildContent() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 16)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticLinkDetectionEnabled = false
        // Markdown needs its punctuation left exactly as typed.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.delegate = self

        webView.navigationDelegate = self
        webView.allowsMagnification = true

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(textScroll)
        splitView.addArrangedSubview(webView)
        window?.contentView = splitView
        applyMode(animatedDivider: false)
    }

    private func buildToolbar() {
        modeControl.target = self
        modeControl.action = #selector(modeControlChanged(_:))
        modeControl.selectedSegment = mode.rawValue
        modeControl.segmentStyle = .automatic
        for (i, tip) in ["Original text (⌘1)", "Text and rendered side by side (⌘2)", "Rendered (⌘3)"].enumerated() {
            modeControl.setToolTip(tip, forSegment: i)
        }
        editButton.target = self
        editButton.action = #selector(toggleEditing(_:))
        editButton.setButtonType(.pushOnPushOff)
        editButton.bezelStyle = .texturedRounded
        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit")
        editButton.imagePosition = .imageLeading
        editButton.toolTip = "Allow editing the text (⇧⌘E)"
        let toolbar = NSToolbar(identifier: "ViewerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    private static let modeItem = NSToolbarItem.Identifier("viewMode")
    private static let editItem = NSToolbarItem.Identifier("editToggle")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.editItem, Self.modeItem]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.editItem, Self.modeItem]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.modeItem:
            item.label = "View"
            item.view = modeControl
        case Self.editItem:
            item.label = "Edit"
            item.view = editButton
        default:
            return nil
        }
        return item
    }

    // MARK: View mode

    @objc private func modeControlChanged(_ sender: NSSegmentedControl) {
        setMode(ViewMode(rawValue: sender.selectedSegment) ?? .split)
    }

    func setMode(_ newMode: ViewMode) {
        mode = newMode
        ViewMode.saved = newMode
        modeControl.selectedSegment = newMode.rawValue
        applyMode(animatedDivider: true)
    }

    var currentMode: ViewMode { mode }

    private func applyMode(animatedDivider: Bool) {
        textScroll.isHidden = (mode == .preview)
        webView.isHidden = (mode == .source)
        splitView.showsDivider = (mode == .split)
        splitView.adjustSubviews()
        if mode == .split {
            splitView.layoutSubtreeIfNeeded()
            splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)
        }
        splitView.needsDisplay = true
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat { 160 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        splitView.bounds.width - 160
    }

    // MARK: Loading

    /// File > Reload: re-read from disk, confirming first if edits would be lost.
    @objc func reloadDocument(_ sender: Any?) {
        guard isDirty, let window else { reload(force: true); return }
        let alert = NSAlert()
        alert.messageText = "Discard your unsaved changes?"
        alert.informativeText = "Reloading replaces your edits with the version on disk."
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.setDirty(false)
            self.reload(force: true)
        }
    }

    /// Shows the file from disk if it differs from what was last seen there.
    func reload(force: Bool = false) {
        let text: String
        do {
            text = try MarkdownRenderer.readText(at: fileURL)
        } catch {
            if !hasLoaded {
                textView.string = "Could not read \(fileURL.path):\n\(error.localizedDescription)"
            }
            return
        }
        guard force || text != lastText else { return }
        if isDirty {
            promptForConflict(diskText: text)
            return
        }
        let isFirstLoad = !hasLoaded
        lastText = text
        hasLoaded = true

        let visible = textScroll.contentView.bounds.origin
        textView.string = text
        textView.undoManager?.removeAllActions()
        if !isFirstLoad { textScroll.contentView.scroll(to: visible) }
        renderPreview(text, keepScroll: !isFirstLoad)
    }

    private func promptForConflict(diskText: String) {
        guard !isPromptingConflict, let window else { return }
        isPromptingConflict = true
        let alert = NSAlert()
        alert.messageText = "\u{201C}\(fileURL.lastPathComponent)\u{201D} was changed by another app."
        alert.informativeText = "You have unsaved edits here. Keep them, or replace them with the version on disk?"
        alert.addButton(withTitle: "Keep My Edits")
        alert.addButton(withTitle: "Use Disk Version")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isPromptingConflict = false
            if response == .alertSecondButtonReturn {
                self.setDirty(false)
                self.reload(force: true)
            } else {
                self.lastText = diskText // don't ask again about this version
            }
        }
    }

    private func renderPreview(_ text: String, keepScroll: Bool) {
        let html = MarkdownRenderer.htmlDocument(markdown: text, fileURL: fileURL)
        let load = { [weak self] in
            guard let self else { return }
            self.isLoadingPreview = true
            _ = self.webView.loadHTMLString(html, baseURL: self.fileURL)
        }
        if !keepScroll {
            pendingScrollY = 0
            load()
        } else if isLoadingPreview {
            load() // keep the scroll position captured for the load in flight
        } else {
            webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
                self?.pendingScrollY = (value as? Double) ?? 0
                load()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoadingPreview = false
        guard pendingScrollY > 0 else { return }
        webView.evaluateJavaScript("window.scrollTo(0, \(pendingScrollY))", completionHandler: nil)
        pendingScrollY = 0
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoadingPreview = false
    }

    // MARK: Editing

    var isEditingEnabled: Bool { isEditing }
    var hasUnsavedChanges: Bool { isDirty }

    @objc func toggleEditing(_ sender: Any?) { setEditing(!isEditing) }

    func setEditing(_ on: Bool) {
        guard hasLoaded || !on else {
            NSSound.beep()
            editButton.state = .off
            return
        }
        isEditing = on
        editButton.state = on ? .on : .off
        textView.isEditable = on
        if on {
            if mode == .preview { setMode(.split) }
            window?.makeFirstResponder(textView)
        }
    }

    private func setDirty(_ dirty: Bool) {
        isDirty = dirty
        window?.isDocumentEdited = dirty
    }

    func textDidChange(_ notification: Notification) {
        setDirty(true)
        renderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.renderPreview(self.textView.string, keepScroll: true)
        }
        renderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    @objc func saveDocument(_ sender: Any?) { _ = save() }

    @discardableResult
    func save() -> Bool {
        guard hasLoaded else { return false }
        let text = textView.string
        do {
            try Data(text.utf8).write(to: fileURL.resolvingSymlinksInPath(), options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
        lastText = text
        setDirty(false)
        return true
    }

    private func unsavedChangesAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to \u{201C}\(fileURL.lastPathComponent)\u{201D}?"
        alert.informativeText = "Your changes will be lost if you don\u{2019}t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don\u{2019}t Save").hasDestructiveAction = true
        return alert
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        unsavedChangesAlert().beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                if self.save() { sender.close() }
            case .alertThirdButtonReturn:
                self.setDirty(false)
                sender.close()
            default:
                break
            }
        }
        return false
    }

    /// Asked at quit time. Returns false if the user cancels.
    func confirmUnsavedChangesForQuit() -> Bool {
        guard isDirty else { return true }
        window?.makeKeyAndOrderFront(nil)
        switch unsavedChangesAlert().runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.isFileURL {
            // In-page anchor: let WebKit scroll to it.
            if url.fragment != nil, url.standardizedFileURL.path == fileURL.path {
                decisionHandler(.allow)
                return
            }
            let target = URL(fileURLWithPath: url.path)
            if markdownExtensions.contains(target.pathExtension.lowercased()) {
                (NSApp.delegate as? AppDelegate)?.open(target)
            } else {
                NSWorkspace.shared.open(target)
            }
        } else {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    // MARK: Live reload

    private func startWatching() {
        watcher?.cancel()
        let fd = Darwin.open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else {
            // File may be mid-save (replaced atomically); try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.window != nil else { return }
                if FileManager.default.fileExists(atPath: self.fileURL.path) { self.startWatching(); self.reload() }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let replaced = !source.data.intersection([.delete, .rename]).isEmpty
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.reload()
                if replaced { self.startWatching() }
            }
        }
        source.setCancelHandler { _ = Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    func windowWillClose(_ notification: Notification) {
        watcher?.cancel()
        watcher = nil
        onClose?(self)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controllers: [ViewerWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            if controllers.isEmpty { openDocument(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in controllers where controller.hasUnsavedChanges {
            if !controller.confirmUnsavedChangesForQuit() { return .terminateCancel }
        }
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(open)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openDocument(nil) }
        return true
    }

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        if let existing = controllers.first(where: { $0.fileURL == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = ViewerWindowController(fileURL: url)
        controller.onClose = { [weak self] closed in
            DispatchQueue.main.async { self?.controllers.removeAll { $0 === closed } }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        var types = markdownExtensions.compactMap { UTType(filenameExtension: $0) }
        types.append(.plainText)
        panel.allowedContentTypes = types
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            panel.urls.forEach(open)
        } else if controllers.isEmpty {
            NSApp.terminate(nil)
        }
    }

    private var activeController: ViewerWindowController? {
        NSApp.keyWindow?.windowController as? ViewerWindowController
            ?? NSApp.mainWindow?.windowController as? ViewerWindowController
    }

    @objc func selectViewMode(_ sender: NSMenuItem) {
        guard let mode = ViewMode(rawValue: sender.tag) else { return }
        activeController?.setMode(mode)
    }

    @objc func reloadActive(_ sender: Any?) { activeController?.reloadDocument(sender) }
    @objc func saveActive(_ sender: Any?) { activeController?.saveDocument(sender) }
    @objc func toggleEditingActive(_ sender: Any?) { activeController?.toggleEditing(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(selectViewMode(_:)) {
            item.state = (activeController?.currentMode.rawValue == item.tag) ? .on : .off
            return activeController != nil
        }
        if item.action == #selector(reloadActive(_:)) { return activeController != nil }
        if item.action == #selector(saveActive(_:)) { return activeController?.hasUnsavedChanges == true }
        if item.action == #selector(toggleEditingActive(_:)) {
            item.state = (activeController?.isEditingEnabled == true) ? .on : .off
            return activeController != nil
        }
        return true
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Kilodown"
        let main = NSMenu()

        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 target: AnyObject? = nil, tag: Int = 0,
                 modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = target
            item.tag = tag
            item.keyEquivalentModifierMask = modifiers
            return item
        }

        let app = submenu(appName)
        add(app, "About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "Hide \(appName)", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("File")
        add(file, "Open…", #selector(openDocument(_:)), "o", target: self)
        let recent = add(file, "Open Recent", nil)
        let recentMenu = NSMenu(title: "Open Recent")
        add(recentMenu, "Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))
        recent.submenu = recentMenu
        file.addItem(.separator())
        add(file, "Save", #selector(saveActive(_:)), "s", target: self)
        add(file, "Reload", #selector(reloadActive(_:)), "r", target: self)
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu("Edit")
        add(edit, "Allow Editing", #selector(toggleEditingActive(_:)), "e", target: self,
            modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSTextView.pasteAsPlainText(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Find in Source…", #selector(NSTextView.performFindPanelAction(_:)), "f",
            tag: Int(NSFindPanelAction.showFindPanel.rawValue))
        add(edit, "Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g",
            tag: Int(NSFindPanelAction.next.rawValue))
        add(edit, "Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "g",
            tag: Int(NSFindPanelAction.previous.rawValue), modifiers: [.command, .shift])

        let view = submenu("View")
        add(view, "Source", #selector(selectViewMode(_:)), "1", target: self, tag: ViewMode.source.rawValue)
        add(view, "Split", #selector(selectViewMode(_:)), "2", target: self, tag: ViewMode.split.rawValue)
        add(view, "Preview", #selector(selectViewMode(_:)), "3", target: self, tag: ViewMode.preview.rawValue)
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])

        let window = submenu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = window

        return main
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
