import Cocoa

class SettingsPanel: NSWindow, NSWindowDelegate {
    
    private let panelWidth: CGFloat = 420
    private var urlField: NSTextField!
    private var keyField: NSSecureTextField!
    private var modelField: NSTextField!
    private var protocolPopup: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var testButton: NSButton!
    private var langAField: NSTextField!
    private var langBField: NSTextField!
    private var directionPopup: NSPopUpButton!
    
    var onSave: ((APIConfig) -> Void)?
    
    init() {
        // Large initial height — will be resized to fit content
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        
        self.title = "API 设置"
        self.isReleasedWhenClosed = false
        self.delegate = self
        
        // Build all views, then measure and resize
        buildUI()
        loadConfig()
    }
    
    // MARK: - Pure frame layout (no autolayout — simple and predictable)
    
    private func buildUI() {
        guard let cv = self.contentView else { return }
        
        let p: CGFloat = 14           // edge padding
        let lw: CGFloat = 64          // label width
        let fh: CGFloat = 26          // field height
        let sp: CGFloat = 10          // row spacing
        let fw = panelWidth - p * 2 - lw - 6  // field width
        
        var y: CGFloat = 0  // builds from bottom up
        
        func row(_ height: CGFloat = fh + sp) -> CGFloat {
            let r = y; y += height; return r
        }
        
        // --- Status bar (top) ---
        let infoY = row(22 + sp + 4)
        let infoRow = NSView(frame: NSRect(x: p, y: infoY, width: fw + lw + 6, height: 22))
        cv.addSubview(infoRow)
        
        let indicator = NSImageView(frame: NSRect(x: 0, y: 6, width: 10, height: 10))
        indicator.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        infoRow.addSubview(indicator)
        
        statusLabel = NSTextField(labelWithString: "检测中...")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 16, y: 3, width: 180, height: 16)
        infoRow.addSubview(statusLabel)
        
        testButton = NSButton(title: "测试连接", target: self, action: #selector(testConnection))
        testButton.bezelStyle = .rounded
        testButton.controlSize = .small
        testButton.font = NSFont.systemFont(ofSize: 11)
        testButton.frame = NSRect(x: 220, y: 1, width: 70, height: 20)
        infoRow.addSubview(testButton)
        
        // Separator
        sep(cv, y)
        _ = row(sp + 6)
        
        // --- API Section ---
        let apiLabel = NSTextField(labelWithString: "API 配置")
        apiLabel.font = NSFont.boldSystemFont(ofSize: 11)
        apiLabel.textColor = .secondaryLabelColor
        apiLabel.frame = NSRect(x: p, y: y, width: 200, height: 14)
        cv.addSubview(apiLabel)
        _ = row(16 + sp - 2)
        
        // Protocol
        let pl = fieldLabel("协议", y, cv)
        protocolPopup = NSPopUpButton(frame: NSRect(x: p + lw + 6, y: y - 2, width: fw, height: fh), pullsDown: false)
        protocolPopup.addItems(withTitles: APIProtocol.allCases.map { $0.displayName })
        protocolPopup.target = self; protocolPopup.action = #selector(protocolChanged)
        cv.addSubview(protocolPopup); cv.addSubview(pl)
        _ = row()
        
        // URL
        let ul = fieldLabel("URL", y, cv)
        urlField = field(p + lw + 6, y, fw, fh, "http://localhost:8765"); cv.addSubview(urlField); cv.addSubview(ul)
        _ = row()
        
        // Key
        let kl = fieldLabel("API Key", y, cv)
        keyField = NSSecureTextField(frame: NSRect(x: p + lw + 6, y: y, width: fw, height: fh))
        keyField.font = NSFont.systemFont(ofSize: 12); keyField.placeholderString = "sk-..."
        cv.addSubview(keyField); cv.addSubview(kl)
        _ = row()
        
        // Model
        let ml = fieldLabel("模型", y, cv)
        modelField = field(p + lw + 6, y, fw, fh, "deepseek-chat"); cv.addSubview(modelField); cv.addSubview(ml)
        _ = row(sp + 4)
        
        // Separator
        sep(cv, y); _ = row(sp + 6)
        
        // --- Translation Settings ---
        let transLabel = NSTextField(labelWithString: "翻译设置")
        transLabel.font = NSFont.boldSystemFont(ofSize: 11)
        transLabel.textColor = .secondaryLabelColor
        transLabel.frame = NSRect(x: p, y: y, width: 200, height: 14)
        cv.addSubview(transLabel); _ = row(16 + sp - 2)
        
        // Language A
        let lal = fieldLabel("语言 A", y, cv)
        langAField = field(p + lw + 6, y, fw, fh, "英文"); cv.addSubview(langAField); cv.addSubview(lal)
        _ = row()
        
        // Language B
        let lbl = fieldLabel("语言 B", y, cv)
        langBField = field(p + lw + 6, y, fw, fh, "中文"); cv.addSubview(langBField); cv.addSubview(lbl)
        _ = row()
        
        // Direction mode
        let dl = fieldLabel("默认方向", y, cv)
        directionPopup = NSPopUpButton(frame: NSRect(x: p + lw + 6, y: y - 2, width: fw, height: fh), pullsDown: false)
        directionPopup.addItems(withTitles: DirectionMode.allCases.map { $0.displayName })
        cv.addSubview(directionPopup); cv.addSubview(dl)
        _ = row(sp + 10)
        
        // --- Buttons ---
        let btnW: CGFloat = 70, btnH: CGFloat = 26
        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(close))
        cancelBtn.frame = NSRect(x: p, y: y, width: btnW, height: btnH)
        cancelBtn.bezelStyle = .rounded; cancelBtn.keyEquivalent = "\u{1b}"
        cv.addSubview(cancelBtn)
        
        let saveBtn = NSButton(title: "保存", target: self, action: #selector(saveConfig))
        saveBtn.frame = NSRect(x: panelWidth - p - btnW, y: y, width: btnW, height: btnH)
        saveBtn.bezelStyle = .rounded; saveBtn.keyEquivalent = "\r"; saveBtn.isHighlighted = true
        cv.addSubview(saveBtn)
        _ = row(btnH + p)
        
        // --- Resize window to fit ---
        self.setContentSize(NSSize(width: panelWidth, height: y))
        self.center()
    }
    
    // Helpers
    private func fieldLabel(_ text: String, _ y: CGFloat, _ parent: NSView) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right; l.font = NSFont.systemFont(ofSize: 12)
        l.frame = NSRect(x: 14, y: y + 2, width: 64, height: 22)
        return l
    }
    private func field(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ placeholder: String) -> NSTextField {
        let tf = NSTextField(frame: NSRect(x: x, y: y, width: w, height: h))
        tf.font = NSFont.systemFont(ofSize: 12); tf.isBezeled = true
        tf.bezelStyle = .squareBezel; tf.placeholderString = placeholder
        return tf
    }
    private func sep(_ parent: NSView, _ y: CGFloat) {
        let s = NSBox(frame: NSRect(x: 14, y: y, width: panelWidth - 28, height: 1))
        s.boxType = .separator; parent.addSubview(s)
    }
    
    // MARK: - Config
    
    private func loadConfig() {
        applyConfig(ConfigManager.shared.autoDetect())
    }
    
    func applyConfig(_ config: APIConfig) {
        urlField.stringValue = config.url
        keyField.stringValue = config.apiKey
        modelField.stringValue = config.model
        protocolPopup.selectItem(withTitle: config.protocol.displayName)
        langAField.stringValue = config.langA
        langBField.stringValue = config.langB
        directionPopup.selectItem(withTitle: config.directionMode.displayName)
        
        if !config.custom {
            let reachable = ConfigManager.shared.isProxyReachable()
            statusLabel.stringValue = reachable ? "✅ 检测到 deepseek-copilot-proxy" : "⚠️ 未检测到本地代理，请自定义"
            statusLabel.textColor = reachable ? .systemGreen : .systemOrange
        } else {
            statusLabel.stringValue = "⚙️ 自定义配置"
            statusLabel.textColor = .secondaryLabelColor
        }
    }
    
    @objc private func protocolChanged() {
        let proto = APIProtocol.allCases[safe: protocolPopup.indexOfSelectedItem] ?? .openai
        modelField.placeholderString = proto == .anthropic ? "claude-sonnet-4-20250514" : "deepseek-chat"
        keyField.placeholderString = proto == .anthropic ? "sk-ant-..." : "sk-..."
    }
    
    // MARK: - Actions
    
    @objc private func testConnection() {
        let config = buildConfig()
        testButton.title = "测试中..."; testButton.isEnabled = false
        
        var req = URLRequest(url: URL(string: config.chatURL)!)
        req.httpMethod = "POST"; req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if config.protocol == .anthropic {
            req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": config.model, "max_tokens": 1, "messages": [["role": "user", "content": "hi"]]])
        } else {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": config.model, "messages": [["role": "user", "content": "hi"]], "max_tokens": 1, "stream": false])
        }
        
        URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            DispatchQueue.main.async {
                self?.testButton.isEnabled = true; self?.testButton.title = "测试连接"
                if let hr = response as? HTTPURLResponse {
                    self?.statusLabel.stringValue = hr.statusCode == 200 ? "✅ 连接成功 (HTTP 200)" : "⚠️ HTTP \(hr.statusCode)"
                    self?.statusLabel.textColor = hr.statusCode == 200 ? .systemGreen : .systemOrange
                } else if let e = error {
                    self?.statusLabel.stringValue = "❌ \(e.localizedDescription)"
                    self?.statusLabel.textColor = .systemRed
                }
            }
        }.resume()
    }
    
    @objc private func saveConfig() {
        let config = buildConfig()
        ConfigManager.shared.save(config)
        onSave?(config)
        print("[SettingsPanel] ✅ Saved: \(config.protocol.displayName) | \(config.langA)↔\(config.langB)")
        close()
    }
    
    private func buildConfig() -> APIConfig {
        APIConfig(
            provider: "custom",
            url: urlField.stringValue.trimmingCharacters(in: .whitespaces),
            apiKey: keyField.stringValue.trimmingCharacters(in: .whitespaces),
            model: modelField.stringValue.trimmingCharacters(in: .whitespaces),
            protocol: APIProtocol.allCases[safe: protocolPopup.indexOfSelectedItem] ?? .openai,
            custom: true,
            langA: langAField.stringValue.trimmingCharacters(in: .whitespaces),
            langB: langBField.stringValue.trimmingCharacters(in: .whitespaces),
            directionMode: DirectionMode.allCases[safe: directionPopup.indexOfSelectedItem] ?? .toB
        )
    }
    
    func windowWillClose(_ notification: Notification) {}
}

// Safe array access
extension Array {
    subscript(safe idx: Int) -> Element? {
        indices.contains(idx) ? self[idx] : nil
    }
}
