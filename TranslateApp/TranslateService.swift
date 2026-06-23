import Foundation

// MARK: - Result Types

enum TranslateError: LocalizedError {
    case networkError(String)
    case apiError(String)
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .networkError(let msg): return "网络错误: \(msg)"
        case .apiError(let msg): return "API错误: \(msg)"
        case .timeout: return "翻译超时"
        }
    }
}

enum TranslateResult {
    case translation(String)
    case dictionary(DictionaryEntry)
}

// MARK: - Service

class TranslateService {
    static let shared = TranslateService()
    
    private var session: URLSession
    private var currentConfig: APIConfig
    
    /// Active paper context for domain-specific translation
    var paperContext: [String: String]? = nil
    
    /// Current translation direction override (toggle button)
    /// true = translate to langB, false = translate to langA
    var directionToB: Bool = true
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
        currentConfig = ConfigManager.shared.autoDetect()
        directionToB = true  // default: translate to langB (中文)
    }
    
    /// Reload config (called after user changes settings)
    func reloadConfig() {
        currentConfig = ConfigManager.shared.autoDetect()
        directionToB = true  // reset to default
        print("[TranslateService] Config reloaded: \(currentConfig.url) (\(currentConfig.protocol.displayName)), 翻译方向: →\(currentConfig.langB)")
    }
    
    /// Get current config (for display)
    var config: APIConfig { currentConfig }
    
    /// Direction label for toolbar display
    var directionLabel: String {
        return "→\(currentConfig.langB)"
    }
    
    /// Toggle translation direction
    func toggleDirection() {
        directionToB.toggle()
        print("[TranslateService] 翻译方向切换: →\(currentConfig.langB)=\(directionToB)")
    }
    
    /// Reset direction to default (langB)
    func resetDirection() {
        directionToB = true
    }
    
    // MARK: - Public API
    
    /// Main translate method: auto-detects word vs sentence and returns appropriate result
    func translate(text: String) async -> Result<TranslateResult, TranslateError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if isSingleWord(trimmed) {
            return await translateWord(trimmed)
        } else {
            let result = await translateSentence(trimmed)
            switch result {
            case .success(let text):
                return .success(.translation(text))
            case .failure(let error):
                return .failure(error)
            }
        }
    }
    
    // MARK: - Word Detection
    
    private func isSingleWord(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        
        if words.count == 1 && text.count <= 30 {
            let cjkRatio = cjkCharacterRatio(text)
            if cjkRatio > 0.5 && text.count > 4 {
                return false
            }
            return true
        }
        
        if words.count >= 2 && words.count <= 3 && text.count <= 40 {
            let hasEndPunctuation = text.last == "." || text.last == "?" || text.last == "!"
            let hasComma = text.contains(",")
            if !hasEndPunctuation && !hasComma {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - Dictionary Mode
    
    private func translateWord(_ word: String) async -> Result<TranslateResult, TranslateError> {
        let target = resolveTargetLanguage(for: word)
        let contextMatch = findContextMatch(for: word)
        
        let systemPrompt = buildDictionaryPrompt(target: target)
        var finalPrompt = systemPrompt
        
        if let match = contextMatch {
            finalPrompt += """
            
            
            ⚠️ 重要：用户正在阅读一篇特定论文。本词在该论文语境中的标准译法为：
            「\(match.term)」→「\(match.translation)」
            你的 definitions 第一条必须使用「\(match.translation)」作为中文释义（这是该论文中的确定含义），
            cs_note 中说明它在本文中的具体作用。其余字段（音标、例句、相关术语）正常补充。
            """
        } else if let context = paperContext, !context.isEmpty {
            let termsList = context.prefix(25).map { "\($0.key) → \($0.value)" }.joined(separator: "\n")
            finalPrompt += """
            
            
            当前论文语境术语对照（供消歧参考，若用户查询的词与其中某项相关，请优先采用该译法）：
            \(termsList)
            """
        }
        
        let result = await callAPI(systemPrompt: finalPrompt, userText: word)
        
        switch result {
        case .success(let responseText):
            if let entry = parseDictionaryResponse(responseText, originalWord: word) {
                return .success(.dictionary(entry))
            } else {
                return .success(.translation(responseText))
            }
        case .failure(let error):
            return .failure(error)
        }
    }
    
    /// Build dictionary prompt based on target language
    private func buildDictionaryPrompt(target: String) -> String {
        // Determine if target is Chinese/CJK-like
        let targetIsCJK = APIConfig.isCJK(target)
        
        if targetIsCJK {
            return """
            你是一个计算机科学/AI领域的专业词典。用户输入英文单词或术语，请将释义翻译为\(target)。
            
            要求：
            1. phonetic: 国际音标（如 /əˈtenʃən/）
            2. definitions: 所有常见词性和释义，CS/AI领域释义优先排列。中文释义使用\(target)
            3. cs_note: 如果该词在CS/AI领域有特殊含义，给出简短说明（1-2句话，用\(target)）
            4. examples: 2-3个CS/AI领域的例句（英文）
            5. phrases: 相关的CS/AI领域术语组合
            
            严格返回以下JSON格式，不要有任何其他文字：
            {"word":"xxx","phonetic":"/xxx/","definitions":[{"pos":"n.","cn":"\(target)释义","en":"English def"}],"cs_note":"CS领域说明","examples":["example sentence"],"phrases":["related term"]}
            """
        } else {
            return """
            你是一个计算机科学/AI领域的专业词典。用户输入词汇，请返回严格JSON格式的词典条目，所有释义使用\(target)。
            
            要求：
            1. 给出\(target)术语翻译
            2. definitions: \(target)释义，CS/AI领域释义优先
            3. cs_note: CS/AI领域的用法说明（用\(target)）
            4. examples: 英文例句
            5. phrases: 相关英文术语
            
            严格返回以下JSON格式，不要有任何其他文字：
            {"word":"\(target)术语","phonetic":"/xxx/","definitions":[{"pos":"n.","cn":"原词","en":"\(target) definition"}],"cs_note":"CS note","examples":["example"],"phrases":["related"]}
            """
        }
    }
    
    // MARK: - Context Matching
    
    func hasContextMatch(for word: String) -> Bool {
        return findContextMatch(for: word) != nil
    }
    
    private func findContextMatch(for word: String) -> (term: String, translation: String)? {
        guard let context = paperContext, !context.isEmpty else { return nil }
        
        let lowerWord = word.lowercased().trimmingCharacters(in: .whitespaces)
        
        for (key, value) in context {
            if key.lowercased() == lowerWord { return (key, value) }
        }
        
        for (key, value) in context {
            if let openParen = key.range(of: "("),
               let closeParen = key.range(of: ")") {
                let abbr = String(key[openParen.upperBound..<closeParen.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                if abbr.lowercased() == lowerWord { return (key, value) }
            }
        }
        
        for (key, value) in context {
            let lowerKey = key.lowercased()
            if lowerKey == lowerWord || lowerKey.hasPrefix(lowerWord + " ") {
                return (key, value)
            }
        }
        
        return nil
    }
    
    // MARK: - Sentence Translation
    
    private func translateSentence(_ text: String) async -> Result<String, TranslateError> {
        let target = resolveTargetLanguage(for: text)
        
        let systemPrompt = buildTranslationPrompt(target: target)
        
        // Inject paper context
        var finalPrompt = systemPrompt
        if let context = paperContext, !context.isEmpty {
            let termsList = context.prefix(20).map { "\($0.key) → \($0.value)" }.joined(separator: "\n")
            finalPrompt += """
            
            
            当前论文语境中的术语对照：
            \(termsList)
            请根据上述语境选择最合适的翻译。
            """
        }
        
        return await callAPI(systemPrompt: finalPrompt, userText: text)
    }
    
    private func buildTranslationPrompt(target: String) -> String {
        return """
        你是一个计算机科学/AI领域的专业翻译。将用户输入翻译为\(target)。
        
        翻译原则：
        1. 专业术语使用CS/AI领域的标准译法
        2. 保留无需翻译的专有名词（如 GPT、BERT、ResNet、Adam、Transformer）
        3. 保留公式和数学符号不翻译
        4. 译文要自然流畅，符合学术表达习惯
        5. 只输出翻译结果，不要解释
        """
    }
    
    // MARK: - Language Direction Resolver
    
    /// Determine target language for the given source text
    /// - Returns: target language name (e.g., "中文", "英文")
    private func resolveTargetLanguage(for sourceText: String) -> String {
        let config = currentConfig
        
        switch config.directionMode {
        case .toB:
            // Always translate to langB by default, but respect user toggle
            let target = directionToB ? config.langB : config.langA
            
            // If source already looks like the target language, flip
            let targetIsCJK = APIConfig.isCJK(target)
            let sourceIsCJK = cjkCharacterRatio(sourceText) > 0.3
            
            if targetIsCJK == sourceIsCJK {
                // Source and target are same type — flip to the other language
                return target == config.langB ? config.langA : config.langB
            }
            return target
            
        case .auto:
            // Auto-detect: CJK → non-CJK lang, Latin → CJK lang
            let sourceIsCJK = cjkCharacterRatio(sourceText) > 0.3
            let aIsCJK = APIConfig.isCJK(config.langA)
            let bIsCJK = APIConfig.isCJK(config.langB)
            
            if sourceIsCJK {
                // Return the non-CJK language
                return aIsCJK ? config.langB : config.langA
            } else {
                // Return the CJK language
                return bIsCJK ? config.langB : config.langA
            }
        }
    }
    
    // MARK: - API Call (supports both OpenAI and Anthropic)
    
    private func callAPI(systemPrompt: String, userText: String) async -> Result<String, TranslateError> {
        let config = currentConfig
        guard let url = URL(string: config.chatURL) else {
            return .failure(.apiError("无效的 API URL"))
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: Data
        
        if config.protocol == .anthropic {
            let payload: [String: Any] = [
                "model": config.model,
                "max_tokens": 2048,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": userText]
                ]
            ]
            
            guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
                return .failure(.apiError("JSON序列化失败"))
            }
            body = jsonData
            
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            let payload: [String: Any] = [
                "model": config.model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userText]
                ],
                "max_tokens": 2048,
                "stream": false,
                "temperature": 0.3
            ]
            
            guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
                return .failure(.apiError("JSON序列化失败"))
            }
            body = jsonData
            
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        request.httpBody = body
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.networkError("无效响应"))
            }
            
            guard httpResponse.statusCode == 200 else {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                return .failure(.apiError("HTTP \(httpResponse.statusCode): \(bodyStr.prefix(200))"))
            }
            
            let content: String
            if config.protocol == .anthropic {
                content = parseAnthropicResponse(data) ?? ""
            } else {
                content = parseOpenAIResponse(data) ?? ""
            }
            
            guard !content.isEmpty else {
                return .failure(.apiError("响应格式错误"))
            }
            
            return .success(content.trimmingCharacters(in: .whitespacesAndNewlines))
            
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.timeout)
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }
    }
    
    // MARK: - Response Parsing
    
    private func parseOpenAIResponse(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content
    }
    
    private func parseAnthropicResponse(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]],
              let firstBlock = contentBlocks.first,
              let text = firstBlock["text"] as? String else {
            return nil
        }
        return text
    }
    
    private func parseDictionaryResponse(_ text: String, originalWord: String) -> DictionaryEntry? {
        var jsonStr = text
        
        if jsonStr.contains("```") {
            let lines = jsonStr.components(separatedBy: "\n")
            var inBlock = false
            var blockLines: [String] = []
            for line in lines {
                if line.hasPrefix("```") {
                    inBlock.toggle()
                    continue
                }
                if inBlock { blockLines.append(line) }
            }
            if !blockLines.isEmpty { jsonStr = blockLines.joined(separator: "\n") }
        }
        
        if let start = jsonStr.firstIndex(of: "{"),
           let end = jsonStr.lastIndex(of: "}") {
            jsonStr = String(jsonStr[start...end])
        }
        
        guard let data = jsonStr.data(using: .utf8) else { return nil }
        
        do {
            return try JSONDecoder().decode(DictionaryEntry.self, from: data)
        } catch {
            print("[TranslateService] Failed to parse dictionary JSON: \(error)")
            return nil
        }
    }
    
    // MARK: - Unicode Helpers
    
    private func cjkCharacterRatio(_ text: String) -> Double {
        let cjkCount = text.unicodeScalars.filter { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value) ||
            (0x3000...0x303F).contains(scalar.value)
        }.count
        return Double(cjkCount) / Double(max(text.unicodeScalars.count, 1))
    }
}
