import Cocoa

// Flipped clip view to make content start from top
class FlippedClipView: NSClipView {
    override var isFlipped: Bool { return true }
}

class PopupPanel: NSPanel, NSWindowDelegate {
    private var visualEffectView: NSVisualEffectView!
    private var scrollView: NSScrollView!
    private var contentStack: NSStackView!
    private var originalLabel: NSTextField!
    private var translatedLabel: NSTextField!
    private var loadingIndicator: NSProgressIndicator!
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var escMonitor: Any?
    private var fontZoomMonitor: Any?
    private var localFontZoomMonitor: Any?
    
    // Toolbar
    private var toolbarStack: NSStackView!
    private var modeLabel: NSTextField!
    private var fontSizeLabel: NSTextField!
    private var copyButton: NSButton!
    private var pinButton: NSButton!
    private var isPinned: Bool = false
    
    // Font scaling
    private var baseFontSizeOriginal: CGFloat = 11.0
    private var baseFontSizeTranslated: CGFloat = 13.0
    private var baseFontSizeToolbar: CGFloat = 9.0
    private var fontScale: CGFloat = 1.0
    private let minScale: CGFloat = 0.6
    private let maxScale: CGFloat = 3.0
    private let scaleStep: CGFloat = 0.1
    
    // Layout
    private let panelPadding: CGFloat = 14.0
    
    // Current mode display
    private var currentMode: String = "🌐 AI翻译"
    
    override var canBecomeKey: Bool { return true }
    
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    }
    
    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                  styleMask: [.nonactivatingPanel, .resizable],
                  backing: .buffered,
                  defer: true)
        
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.minSize = NSSize(width: 120, height: 60)
        self.delegate = self
        
        setupUI()
    }
    
    private func setupUI() {
        // Visual effect background
        visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 10
        visualEffectView.layer?.masksToBounds = true
        
        self.contentView = visualEffectView
        
        // ScrollView
        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        
        visualEffectView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
        ])
        
        // Content stack
        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4
        contentStack.edgeInsets = NSEdgeInsets(top: 8, left: panelPadding, bottom: 10, right: panelPadding)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        
        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = contentStack
        
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: clipView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
        ])
        
        // === TOOLBAR ===
        setupToolbar()
        
        // Separator line
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -panelPadding * 2).isActive = true
        
        // Original text label (gray, small)
        originalLabel = createLabel(fontSize: baseFontSizeOriginal, color: .secondaryLabelColor, selectable: false)
        contentStack.addArrangedSubview(originalLabel)
        
        // Loading indicator
        loadingIndicator = NSProgressIndicator()
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
        contentStack.addArrangedSubview(loadingIndicator)
        
        // Translated text label (normal size, selectable)
        translatedLabel = createLabel(fontSize: baseFontSizeTranslated, color: .labelColor, selectable: true)
        contentStack.addArrangedSubview(translatedLabel)
    }
    
    private func setupToolbar() {
        toolbarStack = NSStackView()
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.spacing = 6
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        
        let toolbarFontSize = baseFontSizeToolbar * fontScale
        
        // Mode label (left side)
        modeLabel = NSTextField(labelWithString: currentMode)
        modeLabel.font = NSFont.systemFont(ofSize: toolbarFontSize)
        modeLabel.textColor = .tertiaryLabelColor
        modeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        
        // Font size indicator
        fontSizeLabel = NSTextField(labelWithString: "100%")
        fontSizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: toolbarFontSize, weight: .regular)
        fontSizeLabel.textColor = .tertiaryLabelColor
        fontSizeLabel.setContentHuggingPriority(.required, for: .horizontal)
        
        // Copy button
        copyButton = createToolbarButton(title: "📋", action: #selector(copyTranslation))
        
        // Pin button
        pinButton = createToolbarButton(title: "📌", action: #selector(togglePin))
        
        toolbarStack.addArrangedSubview(modeLabel)
        toolbarStack.addArrangedSubview(spacer)
        toolbarStack.addArrangedSubview(fontSizeLabel)
        toolbarStack.addArrangedSubview(copyButton)
        toolbarStack.addArrangedSubview(pinButton)
        
        contentStack.addArrangedSubview(toolbarStack)
        toolbarStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -panelPadding * 2).isActive = true
    }
    
    private func createToolbarButton(title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.isBordered = false
        btn.setButtonType(.momentaryChange)
        let btnFontSize = baseFontSizeToolbar * fontScale
        btn.font = NSFont.systemFont(ofSize: btnFontSize)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setContentHuggingPriority(.required, for: .horizontal)
        return btn
    }
    
    // MARK: - Toolbar Actions
    
    @objc private func copyTranslation() {
        let text = translatedLabel.stringValue
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        
        // Brief visual feedback
        let original = copyButton.title
        copyButton.title = "✅"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.copyButton.title = original
        }
    }
    
    @objc private func togglePin() {
        isPinned.toggle()
        pinButton.title = isPinned ? "📍" : "📌"
        // Update mode label to show pin state
        if isPinned {
            modeLabel.stringValue = currentMode + " · 已固定"
        } else {
            modeLabel.stringValue = currentMode
        }
    }
    
    /// Update the mode indicator (call from outside when source changes)
    func setMode(_ mode: String) {
        currentMode = mode
        modeLabel.stringValue = isPinned ? mode + " · 已固定" : mode
    }
    
    // MARK: - Labels
    
    private func createLabel(fontSize: CGFloat, color: NSColor, selectable: Bool) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = NSFont.systemFont(ofSize: fontSize)
        label.textColor = color
        label.backgroundColor = .clear
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = selectable
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        updateLabelWidth(label)
        return label
    }
    
    private func updateLabelWidth(_ label: NSTextField) {
        let availableWidth = max(self.frame.width - panelPadding * 2 - 10, 100)
        label.preferredMaxLayoutWidth = availableWidth
    }
    
    private func updateAllLabelWidths() {
        updateLabelWidth(originalLabel)
        updateLabelWidth(translatedLabel)
        contentStack.needsLayout = true
    }
    
    // MARK: - Font Scaling
    
    private func adjustFontScale(by delta: CGFloat) {
        let newScale = max(minScale, min(maxScale, fontScale + delta))
        guard newScale != fontScale else { return }
        fontScale = newScale
        applyFontScale()
    }
    
    private func applyFontScale() {
        // Body text
        originalLabel.font = NSFont.systemFont(ofSize: baseFontSizeOriginal * fontScale)
        translatedLabel.font = NSFont.systemFont(ofSize: baseFontSizeTranslated * fontScale)
        
        // Toolbar (proportional)
        let toolbarSize = baseFontSizeToolbar * fontScale
        modeLabel.font = NSFont.systemFont(ofSize: toolbarSize)
        fontSizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: toolbarSize, weight: .regular)
        copyButton.font = NSFont.systemFont(ofSize: toolbarSize)
        pinButton.font = NSFont.systemFont(ofSize: toolbarSize)
        
        // Update indicator
        let pct = Int(round(fontScale * 100))
        fontSizeLabel.stringValue = "\(pct)%"
        
        updateAllLabelWidths()
        contentStack.needsLayout = true
    }
    
    // MARK: - NSWindowDelegate
    
    func windowDidResize(_ notification: Notification) {
        updateAllLabelWidths()
    }
    
    // MARK: - Public API
    
    func showLoading(at point: NSPoint, originalText: String) {
        originalLabel.stringValue = originalText
        translatedLabel.stringValue = ""
        translatedLabel.isHidden = true
        loadingIndicator.startAnimation(nil)
        loadingIndicator.isHidden = false
        isPinned = false
        pinButton.title = "📌"
        modeLabel.stringValue = currentMode
        
        positionNearMouse(point, text: originalText)
        makeKeyAndOrderFront(nil)
        setupDismissMonitors()
        setupFontZoomMonitors()
    }
    
    func showResult(originalText: String, translatedText: String) {
        originalLabel.stringValue = originalText
        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true
        translatedLabel.stringValue = translatedText
        translatedLabel.isHidden = false
        
        // Get current screen bounds for smart sizing
        let screenFrame = currentScreenFrame()
        let fontSize = baseFontSizeTranslated * fontScale
        
        // Use the longer text to determine ideal width
        let longerText = translatedText.count > originalText.count ? translatedText : originalText
        let idealWidth = calculateIdealWidth(for: longerText, fontSize: fontSize, screenWidth: screenFrame.width)
        
        // Update label widths based on new panel width
        let availableWidth = idealWidth - panelPadding * 2 - 10
        originalLabel.preferredMaxLayoutWidth = availableWidth
        translatedLabel.preferredMaxLayoutWidth = availableWidth
        
        contentStack.layoutSubtreeIfNeeded()
        let idealSize = contentStack.fittingSize
        let newWidth = max(idealWidth, idealSize.width + panelPadding * 2)
        let newHeight = min(max(idealSize.height + 10, 80), screenFrame.height * 0.7)
        
        var frame = self.frame
        let oldOrigin = frame.origin
        frame.size = NSSize(width: newWidth, height: newHeight)
        frame.origin = oldOrigin
        
        // Ensure still within screen bounds
        if frame.maxX > screenFrame.maxX {
            frame.origin.x = screenFrame.maxX - frame.width - 10
        }
        if frame.origin.y + frame.height > screenFrame.maxY {
            frame.origin.y = screenFrame.maxY - frame.height - 10
        }
        if frame.origin.y < screenFrame.minY {
            frame.origin.y = screenFrame.minY + 10
        }
        
        self.setFrame(frame, display: true, animate: true)
        updateAllLabelWidths()
    }
    
    /// Show a dictionary entry (formatted word lookup result)
    func showDictionaryEntry(at point: NSPoint, originalText: String, entry: DictionaryEntry) {
        // If panel is not visible yet (cache hit path), do full setup
        if !self.isVisible {
            positionNearMouse(point, text: originalText)
            makeKeyAndOrderFront(nil)
            setupDismissMonitors()
            setupFontZoomMonitors()
        }
        
        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true
        
        // Original text shows the word with phonetic
        var headerText = originalText
        if let ph = entry.phonetic, !ph.isEmpty {
            headerText += "  \(ph)"
        }
        originalLabel.stringValue = headerText
        
        // Format dictionary content
        translatedLabel.stringValue = formatDictionaryContent(entry)
        translatedLabel.isHidden = false
        
        // Resize to fit dictionary content (tends to be taller)
        let screenFrame = currentScreenFrame()
        let fontSize = baseFontSizeTranslated * fontScale
        let idealWidth = max(calculateIdealWidth(for: entry.formatForDisplay(), fontSize: fontSize, screenWidth: screenFrame.width), 280)
        
        let availableWidth = idealWidth - panelPadding * 2 - 10
        originalLabel.preferredMaxLayoutWidth = availableWidth
        translatedLabel.preferredMaxLayoutWidth = availableWidth
        
        contentStack.layoutSubtreeIfNeeded()
        let idealSize = contentStack.fittingSize
        let newWidth = max(idealWidth, idealSize.width + panelPadding * 2)
        let newHeight = min(max(idealSize.height + 10, 100), screenFrame.height * 0.7)
        
        var frame = self.frame
        let oldOrigin = frame.origin
        frame.size = NSSize(width: newWidth, height: newHeight)
        frame.origin = oldOrigin
        
        if frame.maxX > screenFrame.maxX {
            frame.origin.x = screenFrame.maxX - frame.width - 10
        }
        if frame.origin.y + frame.height > screenFrame.maxY {
            frame.origin.y = screenFrame.maxY - frame.height - 10
        }
        if frame.origin.y < screenFrame.minY {
            frame.origin.y = screenFrame.minY + 10
        }
        
        self.setFrame(frame, display: true, animate: true)
        updateAllLabelWidths()
    }
    
    /// Format dictionary entry content as a readable string
    private func formatDictionaryContent(_ entry: DictionaryEntry) -> String {
        var lines: [String] = []
        
        // Definitions
        for def in entry.definitions {
            lines.append("[\(def.pos)] \(def.cn)")
            if let en = def.en, !en.isEmpty {
                lines.append("    \(en)")
            }
        }
        
        // CS/AI note
        if let note = entry.csNote, !note.isEmpty {
            lines.append("")
            lines.append("💡 \(note)")
        }
        
        // Examples
        if let exs = entry.examples, !exs.isEmpty {
            lines.append("")
            for ex in exs.prefix(3) {
                lines.append("▸ \(ex)")
            }
        }
        
        // Phrases
        if let phr = entry.phrases, !phr.isEmpty {
            lines.append("")
            lines.append("⟡ \(phr.joined(separator: " · "))")
        }
        
        return lines.joined(separator: "\n")
    }
    
    func showError(message: String) {
        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true
        translatedLabel.stringValue = "⚠️ \(message)"
        translatedLabel.textColor = .systemRed
        translatedLabel.isHidden = false
        
        let screenFrame = currentScreenFrame()
        updateAllLabelWidths()
        contentStack.layoutSubtreeIfNeeded()
        let idealSize = contentStack.fittingSize
        var frame = self.frame
        frame.size = NSSize(width: min(max(idealSize.width + panelPadding * 2, 200), screenFrame.width * 0.5),
                            height: max(idealSize.height + 10, 80))
        self.setFrame(frame, display: true)
    }
    
    func dismiss() {
        orderOut(nil)
        removeDismissMonitors()
        removeFontZoomMonitors()
        translatedLabel.textColor = .labelColor
    }
    
    // MARK: - Screen Helpers
    
    private func currentScreenFrame() -> NSRect {
        let panelCenter = NSPoint(x: self.frame.midX, y: self.frame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(panelCenter) })
                     ?? NSScreen.main
                     ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    }
    
    // MARK: - Positioning (multi-monitor aware)
    
    private func calculateIdealWidth(for text: String, fontSize: CGFloat, screenWidth: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let singleLineWidth = (text as NSString).size(withAttributes: attrs).width + panelPadding * 2 + 20
        
        let charCount = text.count
        let maxWidth = screenWidth * 0.65
        
        if charCount <= 15 {
            return min(max(singleLineWidth, 140), maxWidth)
        } else if charCount <= 50 {
            let targetWidth = min(singleLineWidth, 420)
            return min(max(targetWidth, 200), maxWidth)
        } else if charCount <= 150 {
            let targetWidth = min(singleLineWidth * 0.5, 520)
            return min(max(targetWidth, 320), maxWidth)
        } else {
            let targetWidth = min(singleLineWidth * 0.3, 620)
            return min(max(targetWidth, 400), maxWidth)
        }
    }
    
    private func positionNearMouse(_ mouseLocation: NSPoint, text: String) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
                     ?? NSScreen.main
                     ?? NSScreen.screens.first
        
        guard let targetScreen = screen else { return }
        
        let screenFrame = targetScreen.visibleFrame
        self.maxSize = screenFrame.size
        
        let fontSize = baseFontSizeTranslated * fontScale
        let idealWidth = calculateIdealWidth(for: text, fontSize: fontSize, screenWidth: screenFrame.width)
        let panelSize = NSSize(width: idealWidth, height: 120)
        let padding: CGFloat = 10
        
        var x = mouseLocation.x + padding
        var y = mouseLocation.y - panelSize.height - padding
        
        if x + panelSize.width > screenFrame.maxX {
            x = mouseLocation.x - panelSize.width - padding
        }
        if x < screenFrame.minX {
            x = screenFrame.minX + padding
        }
        if y < screenFrame.minY {
            y = mouseLocation.y + padding
        }
        if y + panelSize.height > screenFrame.maxY {
            y = screenFrame.maxY - panelSize.height - padding
        }
        
        self.setFrame(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height),
                      display: true)
        updateAllLabelWidths()
    }
    
    // MARK: - Font Zoom Monitors
    
    private func setupFontZoomMonitors() {
        removeFontZoomMonitors()
        
        fontZoomMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return }
            guard event.modifierFlags.contains(.command) else { return }
            self.handleFontZoomKey(event)
        }
        
        localFontZoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            
            if event.keyCode == 53 {
                self.dismiss()
                return nil
            }
            
            if event.modifierFlags.contains(.command) {
                if self.handleFontZoomKey(event) {
                    return nil
                }
            }
            return event
        }
    }
    
    @discardableResult
    private func handleFontZoomKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 24 { // Cmd+=
            adjustFontScale(by: scaleStep)
            return true
        }
        if event.keyCode == 27 { // Cmd+-
            adjustFontScale(by: -scaleStep)
            return true
        }
        if event.keyCode == 29 { // Cmd+0
            fontScale = 1.0
            applyFontScale()
            return true
        }
        return false
    }
    
    private func removeFontZoomMonitors() {
        if let monitor = fontZoomMonitor {
            NSEvent.removeMonitor(monitor)
            fontZoomMonitor = nil
        }
        if let monitor = localFontZoomMonitor {
            NSEvent.removeMonitor(monitor)
            localFontZoomMonitor = nil
        }
    }
    
    // MARK: - Dismiss Monitors
    
    private func setupDismissMonitors() {
        removeDismissMonitors()
        
        // Click outside to dismiss (global) — respects pin
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isVisible, !self.isPinned else { return }
            if !self.frame.contains(NSEvent.mouseLocation) {
                self.dismiss()
            }
        }
        
        // Click outside to dismiss (local) — respects pin
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isVisible, !self.isPinned else { return event }
            if event.window != self {
                self.dismiss()
            }
            return event
        }
        
        // Esc always dismisses (even when pinned)
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dismiss()
            }
        }
    }
    
    private func removeDismissMonitors() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }
}
