import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager!
    private var popupPanel: PopupPanel!
    
    // Python detection: try multiple locations
    private lazy var pythonPath: String = {
        return AppDelegate.detectPython()
    }()
    
    // Script path: bundled in app Resources, with fallback for dev
    private lazy var scriptPath: String = {
        if let bundled = Bundle.main.path(forResource: "paper_translate", ofType: "py") {
            return bundled
        }
        // Dev fallback: relative to executable
        let exeDir = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        return exeDir.appendingPathComponent("scripts/paper_translate.py").path
    }()
    
    /// Detect a working Python 3 with pymupdf
    static func detectPython() -> String {
        let candidates = [
            "python3",                                          // system PATH
            NSHomeDirectory() + "/miniconda3/envs/paper_agent/bin/python3",
            NSHomeDirectory() + "/anaconda3/envs/paper_agent/bin/python3",
            NSHomeDirectory() + "/miniforge3/envs/paper_agent/bin/python3",
            "/opt/homebrew/bin/python3",                        // Apple Silicon Homebrew
            "/usr/local/bin/python3",                           // Intel Homebrew
            "/usr/bin/python3",                                 // Xcode CLT
        ]
        
        for path in candidates {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-c", "import pymupdf; print('OK')"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            
            let outPipe = Pipe()
            process.standardOutput = outPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    print("[TranslateApp] ✅ Using Python: \(path)")
                    return path
                }
            } catch {
                continue
            }
        }
        
        // Fallback: return python3 from PATH, let it fail at import time
        print("[TranslateApp] ⚠️ No Python with pymupdf found, falling back to python3")
        return "/usr/bin/python3"
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        // Initialize database
        _ = VocabularyDB.shared
        
        // Load active paper contexts
        refreshActiveContext()
        
        setupStatusBar()
        popupPanel = PopupPanel()
        
        hotkeyManager = HotkeyManager { [weak self] in
            self?.handleHotkey()
        }
        hotkeyManager.register()
        checkAccessibility()
        
        let stats = VocabularyDB.shared.stats()
        let contexts = VocabularyDB.shared.getAllContexts()
        let activeCount = contexts.filter { $0.isActive }.count
        print("[TranslateApp] ✅ 启动完成 | 词库: \(stats.total) 词条 | 语境: \(activeCount)/\(contexts.count) 篇论文激活")
    }
    
    // MARK: - Context Management
    
    /// Reload merged active context into TranslateService
    private func refreshActiveContext() {
        let merged = VocabularyDB.shared.getMergedActiveContext()
        if merged.terms.isEmpty {
            TranslateService.shared.paperContext = nil
        } else {
            TranslateService.shared.paperContext = merged.terms
        }
    }
    
    private var isContextActive: Bool {
        return TranslateService.shared.paperContext != nil
    }
    
    // MARK: - Status Bar Menu
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "character.book.closed",
                                   accessibilityDescription: "Translate")
            ?? createFallbackIcon()
        }
        
        rebuildMenu()
    }
    
    private func rebuildMenu() {
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "划词翻译 (Option+D)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        // Paper import
        menu.addItem(NSMenuItem(title: "📄 导入论文 (可多选)...", action: #selector(importPaper), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        // Paper context list
        let contexts = VocabularyDB.shared.getAllContexts()
        
        if contexts.isEmpty {
            let emptyItem = NSMenuItem(title: "  暂无论文语境", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            let activeCount = contexts.filter { $0.isActive }.count
            let totalTerms = TranslateService.shared.paperContext?.count ?? 0
            
            let headerItem = NSMenuItem(title: "📄 论文语境 (\(activeCount)/\(contexts.count) 激活, \(totalTerms) 术语)", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            menu.addItem(headerItem)
            
            // Each paper as a toggleable item
            for (index, ctx) in contexts.enumerated() {
                let titleDisplay = ctx.title.count > 35 ? String(ctx.title.prefix(33)) + "..." : ctx.title
                let checkmark = ctx.isActive ? "✓" : "  "
                let item = NSMenuItem(title: "\(checkmark) \(titleDisplay) (\(ctx.termCount))", action: #selector(togglePaper(_:)), keyEquivalent: "")
                item.tag = index
                item.representedObject = ctx.hash as NSString
                menu.addItem(item)
            }
            
            menu.addItem(NSMenuItem.separator())
            
            // Batch actions
            if activeCount > 0 {
                menu.addItem(NSMenuItem(title: "  📋 查看合并术语对照", action: #selector(showContextDetails), keyEquivalent: ""))
                menu.addItem(NSMenuItem(title: "  ✏️ 编辑术语对照", action: #selector(editTerms), keyEquivalent: ""))
                menu.addItem(NSMenuItem(title: "  🔄 应用编辑", action: #selector(reloadTermEdits), keyEquivalent: ""))
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "  ✅ 全部激活", action: #selector(activateAll), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "  ⬜ 全部停用", action: #selector(deactivateAll), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "  🗑️ 清空所有语境", action: #selector(clearAllContexts), keyEquivalent: ""))
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Stats
        let stats = VocabularyDB.shared.stats()
        let statsItem = NSMenuItem(title: "📚 词库: \(stats.total) 词条 (\(stats.csTerms) CS)", action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        menu.addItem(statsItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "检查辅助功能权限", action: #selector(checkAccessibilityAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    private func createFallbackIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        let str = "译" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        str.draw(at: NSPoint(x: 2, y: 2), withAttributes: attrs)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
    
    // MARK: - Paper Context Actions
    
    @objc private func togglePaper(_ sender: NSMenuItem) {
        guard let hash = sender.representedObject as? NSString else { return }
        VocabularyDB.shared.toggleContext(paperHash: hash as String)
        refreshActiveContext()
        rebuildMenu()
    }
    
    @objc private func activateAll() {
        VocabularyDB.shared.setAllContextsActive(true)
        refreshActiveContext()
        rebuildMenu()
    }
    
    @objc private func deactivateAll() {
        VocabularyDB.shared.setAllContextsActive(false)
        refreshActiveContext()
        rebuildMenu()
    }
    
    @objc private func clearAllContexts() {
        // Confirm before deleting
        let contexts = VocabularyDB.shared.getAllContexts()
        for ctx in contexts {
            VocabularyDB.shared.deleteContext(paperHash: ctx.hash)
        }
        refreshActiveContext()
        rebuildMenu()
        print("[TranslateApp] 🗑️ 已清空所有论文语境")
    }
    
    @objc private func showContextDetails() {
        guard let terms = TranslateService.shared.paperContext, !terms.isEmpty else { return }
        
        let merged = VocabularyDB.shared.getMergedActiveContext()
        let titlesDisplay = merged.titles.prefix(3).joined(separator: ", ")
            + (merged.titles.count > 3 ? " 等\(merged.titles.count)篇" : "")
        
        // Format terms
        let sorted = terms.sorted(by: { $0.key.lowercased() < $1.key.lowercased() })
        var lines: [String] = []
        for (en, cn) in sorted {
            lines.append("\(en)  →  \(cn)")
        }
        let termsText = lines.joined(separator: "\n")
        
        // Show in popup
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let point = NSPoint(x: screenFrame.midX, y: screenFrame.maxY - 100)
        
        popupPanel.setMode("📄 \(titlesDisplay)")
        popupPanel.showLoading(at: point, originalText: "合并术语对照表 (\(terms.count) 个)")
        popupPanel.showResult(originalText: "合并术语对照表 (\(terms.count) 个, 来自 \(merged.titles.count) 篇论文 · 其中手动编辑 \(VocabularyDB.shared.getCustomTerms().count) 个)",
                             translatedText: termsText)
    }
    
    @objc private func editTerms() {
        guard let terms = TranslateService.shared.paperContext, !terms.isEmpty else { return }
        
        // Write terms to a temp file
        let filePath = NSHomeDirectory() + "/.translate/terms_edit.txt"
        let sorted = terms.sorted(by: { $0.key.lowercased() < $1.key.lowercased() })
        
        var lines: [String] = []
        lines.append("# 术语对照编辑文件")
        lines.append("# 格式: 英文术语 -> 中文翻译")
        lines.append("# 修改后保存文件，然后点击菜单「🔄 应用编辑」即可生效")
        lines.append("# 自定义编辑的翻译会覆盖 AI 自动生成的翻译")
        lines.append("")
        
        // Mark only truly customized terms (where edit differs from AI)
        let customs = VocabularyDB.shared.getCustomTerms()
        let aiTerms = VocabularyDB.shared.getAIGeneratedTerms()
        for (en, cn) in sorted {
            if let customValue = customs[en], customValue != aiTerms[en] {
                lines.append("# ✏️已手动编辑 (AI: \(aiTerms[en] ?? "?"))")
            }
            lines.append("\(en) -> \(cn)")
        }
        
        let content = lines.joined(separator: "\n")
        try? content.write(toFile: filePath, atomically: true, encoding: .utf8)
        
        // Open with default text editor
        NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
        
        print("[TranslateApp] ✏️ 术语编辑文件已打开: \(filePath)")
    }
    
    @objc private func reloadTermEdits() {
        let filePath = NSHomeDirectory() + "/.translate/terms_edit.txt"
        
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            print("[TranslateApp] ❌ 编辑文件未找到，请先执行「编辑术语对照」")
            return
        }
        
        // Get AI-generated terms to compare against
        let aiTerms = VocabularyDB.shared.getAIGeneratedTerms()
        
        var newTerms: [String: String] = [:]
        var changedCount = 0
        
        let lines = content.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let arrowRange = trimmed.range(of: "->") {
                let term = String(trimmed[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let trans = String(trimmed[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !term.isEmpty, !trans.isEmpty {
                    // Only save if the translation actually changed
                    if aiTerms[term] != trans {
                        newTerms[term] = trans
                        changedCount += 1
                    } else {
                        // Translation matches AI version — remove any previous custom override
                        VocabularyDB.shared.deleteCustomTerm(term)
                    }
                }
            }
        }
        
        if changedCount > 0 {
            VocabularyDB.shared.saveCustomTerms(newTerms)
        }
        
        // Refresh active context
        refreshActiveContext()
        rebuildMenu()
        
        print("[TranslateApp] ✅ 已应用 \(changedCount) 条手动修改（其余未改动项已清理）")
        
        // Show confirmation popup
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let point = NSPoint(x: screenFrame.midX, y: screenFrame.maxY - 100)
        
        popupPanel.setMode("✅ 编辑已应用")
        popupPanel.showLoading(at: point, originalText: "术语编辑已生效")
        
        if changedCount > 0 {
            popupPanel.showResult(originalText: "✅ 应用了 \(changedCount) 条手动修改",
                                 translatedText: "手动编辑的翻译会覆盖 AI 自动生成的。\n与 AI 翻译一致的条目已自动清理。")
        } else {
            popupPanel.showResult(originalText: "✅ 术语已同步",
                                 translatedText: "所有条目与 AI 翻译一致，自定义覆盖已清理。")
        }
    }
    
    // MARK: - Paper Import (multi-file)
    
    @objc private func importPaper() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["pdf"]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "选择要导入的 CS 论文 PDF（可多选）"
        panel.prompt = "导入"
        
        NSApp.activate(ignoringOtherApps: true)
        
        panel.begin { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let paths = panel.urls.map { $0.path }
            self?.processPapers(paths: paths)
        }
    }
    
    private func processPapers(paths: [String]) {
        let total = paths.count
        print("[TranslateApp] 📄 开始处理 \(total) 篇论文")
        
        DispatchQueue.main.async {
            if let button = self.statusItem.button {
                button.image = nil
                button.title = "📄 0/\(total)..."
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var successCount = 0
            var totalTerms = 0
            
            for (index, path) in paths.enumerated() {
                DispatchQueue.main.async {
                    if let button = self.statusItem.button {
                        button.title = "📄 \(index+1)/\(total)..."
                    }
                }
                
                if let result = self.processOnePaper(at: path, index: index, total: total) {
                    successCount += 1
                    totalTerms += result
                }
            }
            
            // All done — refresh context and notify
            self.refreshActiveContext()
            
            DispatchQueue.main.async {
                self.restoreMenuBarIcon()
                self.rebuildMenu()
                
                // Show completion notification
                let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
                let point = NSPoint(x: screenFrame.midX, y: screenFrame.maxY - 100)
                
                self.popupPanel.setMode("📄 导入完成")
                self.popupPanel.showLoading(at: point, originalText: "处理完成")
                self.popupPanel.showResult(
                    originalText: "✅ 成功导入 \(successCount)/\(total) 篇论文",
                    translatedText: "共提取 \(totalTerms) 个术语，语境已自动激活。\n点击菜单栏可勾选/取消各论文的语境。"
                )
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    if self.popupPanel.isVisible {
                        self.popupPanel.dismiss()
                    }
                }
            }
            
            print("[TranslateApp] ✅ 批量导入完成: \(successCount)/\(total) 成功, \(totalTerms) 术语")
        }
    }
    
    /// Process a single paper, returns term count on success
    private func processOnePaper(at path: String, index: Int, total: Int) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: self.pythonPath)
        process.arguments = [self.scriptPath, path]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Real-time progress from stderr
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            
            let lines = text.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                var statusText: String? = nil
                
                if trimmed.contains("翻译 chunk") || trimmed.contains("📝") {
                    if let range = trimmed.range(of: #"\d+/\d+"#, options: .regularExpression) {
                        let progress = trimmed[range]
                        statusText = "📄 [\(index+1)/\(total)] 翻译 \(progress)"
                    }
                } else if trimmed.contains("抽取关键术语") || trimmed.contains("🔍") {
                    statusText = "📄 [\(index+1)/\(total)] 术语..."
                }
                
                if let status = statusText {
                    DispatchQueue.main.async {
                        if let button = self?.statusItem.button {
                            button.title = status
                        }
                    }
                }
            }
        }
        
        do {
            try process.run()
            process.waitUntilExit()
            
            errorPipe.fileHandleForReading.readabilityHandler = nil
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            
            if process.terminationStatus == 0 && !output.isEmpty {
                // Parse result
                guard let data = output.data(using: .utf8),
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let terms = result["terms"] as? [String: String] else {
                    return nil
                }
                
                let paperHash = result["paper_hash"] as? String ?? ""
                let paperTitle = result["paper_title"] as? String
                
                VocabularyDB.shared.saveContext(paperHash: paperHash, paperTitle: paperTitle, terms: terms)
                print("[TranslateApp] ✅ [\(index+1)/\(total)] \(paperTitle ?? "unknown"): \(terms.count) 术语")
                return terms.count
            }
        } catch {
            print("[TranslateApp] ❌ [\(index+1)/\(total)] 处理失败: \(error)")
        }
        
        return nil
    }
    
    private func restoreMenuBarIcon() {
        if let button = self.statusItem.button {
            button.title = ""
            button.image = NSImage(systemSymbolName: "character.book.closed",
                                   accessibilityDescription: "Translate")
            ?? self.createFallbackIcon()
        }
    }
    
    // MARK: - Hotkey Handler
    
    private func handleHotkey() {
        TextGrabber.grabSelectedText { [weak self] text in
            guard let self = self, let text = text, !text.isEmpty else { return }
            
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            
            let mouseLocation = NSEvent.mouseLocation
            
            // Check local vocabulary first (for single words)
            // BUT skip cache if the word matches an active paper context term —
            // context/edited translations must take priority over stale cache
            if self.isSingleWord(trimmed) {
                let hasContext = TranslateService.shared.hasContextMatch(for: trimmed)
                if !hasContext, let cached = VocabularyDB.shared.lookup(trimmed) {
                    DispatchQueue.main.async {
                        self.popupPanel.setMode("📚 本地词库")
                        self.popupPanel.showDictionaryEntry(at: mouseLocation,
                                                           originalText: trimmed,
                                                           entry: cached)
                    }
                    return
                }
            }
            
            // Cache miss or sentence → show loading and call API
            DispatchQueue.main.async {
                let mode = self.isContextActive ? "🌐 AI翻译 · 📄语境" : "🌐 AI翻译"
                self.popupPanel.setMode(mode)
                self.popupPanel.showLoading(at: mouseLocation, originalText: trimmed)
            }
            
            Task {
                let hadContextMatch = TranslateService.shared.hasContextMatch(for: trimmed)
                let result = await TranslateService.shared.translate(text: trimmed)
                DispatchQueue.main.async {
                    switch result {
                    case .success(let translateResult):
                        switch translateResult {
                        case .dictionary(let entry):
                            // Don't cache context-influenced lookups (they're paper-specific, not general)
                            if !hadContextMatch {
                                VocabularyDB.shared.save(word: trimmed, entry: entry, domain: "cs")
                            }
                            self.popupPanel.showDictionaryEntry(at: mouseLocation,
                                                               originalText: trimmed,
                                                               entry: entry)
                        case .translation(let translation):
                            self.popupPanel.showResult(originalText: trimmed,
                                                      translatedText: translation)
                        }
                    case .failure(let error):
                        self.popupPanel.showError(message: error.localizedDescription)
                    }
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func isSingleWord(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        if words.count == 1 && text.count <= 30 {
            let cjkCount = text.unicodeScalars.filter { scalar in
                (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value)
            }.count
            let ratio = Double(cjkCount) / Double(max(text.unicodeScalars.count, 1))
            if ratio > 0.5 && text.count > 4 { return false }
            return true
        }
        if words.count >= 2 && words.count <= 3 && text.count <= 40 {
            let hasEndPunct = text.last == "." || text.last == "?" || text.last == "!"
            let hasComma = text.contains(",")
            if !hasEndPunct && !hasComma { return true }
        }
        return false
    }
    
    // MARK: - Accessibility
    
    private func checkAccessibility() {
        let trusted = AXIsProcessTrusted()
        if trusted {
            print("[TranslateApp] ✅ 辅助功能权限已授权")
        } else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            print("[TranslateApp] ⚠️ 等待用户授权辅助功能权限...")
        }
    }
    
    @objc private func checkAccessibilityAction() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted {
            print("[TranslateApp] ✅ 辅助功能权限已授权")
        }
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
