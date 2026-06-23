import Cocoa

class SettingsPanel: NSWindow, NSWindowDelegate {
    
    private let panelWidth: CGFloat = 420
    private var urlField: NSTextField!
    private var keyField: NSSecureTextField!
    private var modelField: NSTextField!
    private var protocolPopup: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var testButton: NSButton!
    
    var onSave: ((APIConfig) -> Void)?
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        
        self.title = "API 设置"
        self.isReleasedWhenClosed = false
        self.delegate = self
        setupUI()
        loadConfig()
    }
    
    // MARK: - UI Setup
    
    private func setupUI() {
        guard let contentView = self.contentView else { return }
        
        let padding: CGFloat = 16
        let labelWidth: CGFloat = 60
        let fieldHeight: CGFloat = 26
        let spacing: CGFloat = 10
        
        // Container
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)
        
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
        
        var nextY: CGFloat = 0
        let fieldWidth = contentView.frame.width - padding * 2 - labelWidth - 8
        
        // Status / info row
        let infoRow = NSStackView()
        infoRow.orientation = .horizontal
        infoRow.spacing = 6
        infoRow.translatesAutoresizingMaskIntoConstraints = false
        
        let indicator = NSImageView()
        indicator.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        indicator.setContentHuggingPriority(.required, for: .horizontal)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.widthAnchor.constraint(equalToConstant: 10).isActive = true
        indicator.heightAnchor.constraint(equalToConstant: 10).isActive = true
        
        statusLabel = NSTextField(labelWithString: "检测中...")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        testButton = NSButton(title: "测试连接", target: self, action: #selector(testConnection))
        testButton.bezelStyle = .rounded
        testButton.controlSize = .small
        testButton.font = NSFont.systemFont(ofSize: 11)
        testButton.setContentHuggingPriority(.required, for: .horizontal)
        
        infoRow.addArrangedSubview(indicator)
        infoRow.addArrangedSubview(statusLabel)
        infoRow.addArrangedSubview(testButton)
        
        container.addSubview(infoRow)
        infoRow.frame = NSRect(x: 0, y: nextY, width: container.frame.width, height: 22)
        nextY += 22 + spacing + 4
        
        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sep)
        sep.frame = NSRect(x: 0, y: nextY, width: container.frame.width, height: 1)
        nextY += 1 + spacing + 4
        
        // Protocol picker
        let protoLabel = makeLabel("协议", y: nextY, width: labelWidth, height: fieldHeight)
        container.addSubview(protoLabel)
        
        protocolPopup = NSPopUpButton(frame: NSRect(x: labelWidth + 8, y: nextY - 2, width: fieldWidth, height: fieldHeight), pullsDown: false)
        protocolPopup.addItems(withTitles: APIProtocol.allCases.map { $0.displayName })
        protocolPopup.target = self
        protocolPopup.action = #selector(protocolChanged)
        container.addSubview(protocolPopup)
        nextY += fieldHeight + spacing
        
        // URL field
        let urlLabel = makeLabel("URL", y: nextY, width: labelWidth, height: fieldHeight)
        container.addSubview(urlLabel)
        urlField = makeTextField(frame: NSRect(x: labelWidth + 8, y: nextY, width: fieldWidth, height: fieldHeight))
        urlField.placeholderString = "http://localhost:8765"
        container.addSubview(urlField)
        nextY += fieldHeight + spacing
        
        // API Key field
        let keyLabel = makeLabel("API Key", y: nextY, width: labelWidth, height: fieldHeight)
        container.addSubview(keyLabel)
        keyField = NSSecureTextField(frame: NSRect(x: labelWidth + 8, y: nextY, width: fieldWidth, height: fieldHeight))
        keyField.placeholderString = "sk-..."
        container.addSubview(keyField)
        nextY += fieldHeight + spacing
        
        // Model field
        let modelLabel = makeLabel("模型", y: nextY, width: labelWidth, height: fieldHeight)
        container.addSubview(modelLabel)
        modelField = makeTextField(frame: NSRect(x: labelWidth + 8, y: nextY, width: fieldWidth, height: fieldHeight))
        modelField.placeholderString = "deepseek-chat"
        container.addSubview(modelField)
        nextY += fieldHeight + spacing + 8
        
        // Action buttons
        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 8
        btnRow.translatesAutoresizingMaskIntoConstraints = false
        
        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(close))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"  // Esc
        
        let saveBtn = NSButton(title: "保存", target: self, action: #selector(saveConfig))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.isHighlighted = true
        
        btnRow.addArrangedSubview(cancelBtn)
        btnRow.addArrangedSubview(NSView()) // spacer
        btnRow.addArrangedSubview(saveBtn)
        
        container.addSubview(btnRow)
        btnRow.frame = NSRect(x: 0, y: nextY, width: container.frame.width, height: 28)
        nextY += 28 + 8
        
        // Size the window to fit
        let totalHeight = nextY + padding
        self.setContentSize(NSSize(width: panelWidth, height: totalHeight))
        
        // Ensure all items fit
        container.frame = NSRect(x: 0, y: 0, width: panelWidth - padding * 2, height: nextY)
        
        // Center on screen
        self.center()
    }
    
    private func makeLabel(_ text: String, y: CGFloat, width: CGFloat, height: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.font = NSFont.systemFont(ofSize: 12)
        return label
    }
    
    private func makeTextField(frame: NSRect) -> NSTextField {
        let tf = NSTextField(frame: frame)
        tf.font = NSFont.systemFont(ofSize: 12)
        tf.isBezeled = true
        tf.bezelStyle = .squareBezel
        return tf
    }
    
    // MARK: - Config
    
    private func loadConfig() {
        let config = ConfigManager.shared.autoDetect()
        applyConfig(config)
    }
    
    func applyConfig(_ config: APIConfig) {
        urlField.stringValue = config.url
        keyField.stringValue = config.apiKey
        modelField.stringValue = config.model
        protocolPopup.selectItem(withTitle: config.protocol.displayName)
        
        // Update status
        if !config.custom {
            let reachable = ConfigManager.shared.isProxyReachable()
            if reachable {
                statusLabel.stringValue = "✅ 检测到 deepseek-copilot-proxy"
                statusLabel.textColor = .systemGreen
            } else {
                statusLabel.stringValue = "⚠️ 未检测到本地代理，请自定义"
                statusLabel.textColor = .systemOrange
            }
        } else {
            statusLabel.stringValue = "⚙️ 自定义配置"
            statusLabel.textColor = .secondaryLabelColor
        }
    }
    
    @objc private func protocolChanged() {
        let idx = protocolPopup.indexOfSelectedItem
        guard idx >= 0, idx < APIProtocol.allCases.count else { return }
        let proto = APIProtocol.allCases[idx]
        
        // Update placeholder based on protocol
        if !urlField.stringValue.isEmpty {
            // Don't override user input
        }
        // Offer to append chat path
        if proto == .anthropic {
            modelField.placeholderString = "claude-sonnet-4-20250514"
            keyField.placeholderString = "sk-ant-..."
        } else {
            modelField.placeholderString = "deepseek-chat"
            keyField.placeholderString = "sk-..."
        }
    }
    
    // MARK: - Actions
    
    @objc private func testConnection() {
        let config = buildConfig()
        testButton.title = "测试中..."
        testButton.isEnabled = false
        
        // Build request based on protocol
        var request = URLRequest(url: URL(string: config.chatURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        
        if config.protocol == .openai {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": config.model,
                "messages": [["role": "user", "content": "hi"]],
                "max_tokens": 1,
                "stream": false
            ])
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": config.model,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "hi"]]
            ])
        }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.testButton.isEnabled = true
                self?.testButton.title = "测试连接"
                
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        self?.statusLabel.stringValue = "✅ 连接成功 (HTTP 200)"
                        self?.statusLabel.textColor = .systemGreen
                    } else {
                        self?.statusLabel.stringValue = "⚠️ HTTP \(httpResponse.statusCode)"
                        self?.statusLabel.textColor = .systemOrange
                    }
                } else if let error = error {
                    self?.statusLabel.stringValue = "❌ \(error.localizedDescription)"
                    self?.statusLabel.textColor = .systemRed
                }
            }
        }.resume()
    }
    
    @objc private func saveConfig() {
        let config = buildConfig()
        ConfigManager.shared.save(config)
        onSave?(config)
        print("[SettingsPanel] ✅ Config saved: \(config.url) (\(config.protocol.displayName))")
        close()
    }
    
    private func buildConfig() -> APIConfig {
        let protoIdx = protocolPopup.indexOfSelectedItem
        let proto = (protoIdx >= 0 && protoIdx < APIProtocol.allCases.count)
            ? APIProtocol.allCases[protoIdx] : APIProtocol.openai
        
        return APIConfig(
            provider: "custom",
            url: urlField.stringValue.trimmingCharacters(in: .whitespaces),
            apiKey: keyField.stringValue.trimmingCharacters(in: .whitespaces),
            model: modelField.stringValue.trimmingCharacters(in: .whitespaces),
            protocol: proto,
            custom: true
        )
    }
    
    // MARK: - Window lifecycle
    
    func windowWillClose(_ notification: Notification) {
        // Window closing without saving — just dismiss
    }
}
