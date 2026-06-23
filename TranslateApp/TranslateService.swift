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
    
    private let endpoint = URL(string: "http://localhost:8765/v1/chat/completions")!
    private let session: URLSession
    
    /// Active paper context for domain-specific translation
    var paperContext: [String: String]? = nil
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }
    
    // MARK: - Public API
    
    /// Main translate method: auto-detects word vs sentence and returns appropriate result
    func translate(text: String) async -> Result<TranslateResult, TranslateError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if isSingleWord(trimmed) {
            // Dictionary mode: get detailed word entry
            return await translateWord(trimmed)
        } else {
            // Sentence/paragraph mode: CS/AI-aware translation
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
    
    /// Determine if input is a single word/short term (should use dictionary mode)
    private func isSingleWord(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        
        // Single word: always dictionary mode
        if words.count == 1 && text.count <= 30 {
            // But skip if it's a Chinese sentence
            let cjkRatio = cjkCharacterRatio(text)
            if cjkRatio > 0.5 && text.count > 4 {
                return false  // Chinese sentence, not a word
            }
            return true
        }
        
        // 2-3 word compound terms (common in CS: "machine learning", "neural network")
        if words.count >= 2 && words.count <= 3 && text.count <= 40 {
            // Check if it looks like a term (no punctuation, not a sentence)
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
        let targetLang = detectLanguage(word)
        
        // Find matching context term (exact, abbreviation, or substring)
        let contextMatch = findContextMatch(for: word)
        
        let systemPrompt: String
        if targetLang == .chinese {
            systemPrompt = """
            你是一个计算机科学/AI领域的专业词典。用户输入英文单词或术语，请返回严格JSON格式的词典条目。
            
            要求：
            1. phonetic: 国际音标（如 /əˈtenʃən/）
            2. definitions: 所有常见词性和释义，CS/AI领域释义优先排列
            3. cs_note: 如果该词在CS/AI领域有特殊含义，给出简短说明（1-2句话）
            4. examples: 2-3个CS/AI领域的例句（英文）
            5. phrases: 相关的CS/AI领域术语组合
            
            严格返回以下JSON格式，不要有任何其他文字：
            {"word":"xxx","phonetic":"/xxx/","definitions":[{"pos":"n.","cn":"中文释义","en":"English def"}],"cs_note":"CS领域说明","examples":["example sentence"],"phrases":["related term"]}
            """
        } else {
            systemPrompt = """
            你是一个计算机科学/AI领域的专业词典。用户输入中文词汇，请返回严格JSON格式的词典条目。
            
            要求：
            1. 给出对应的英文术语
            2. definitions: 英文释义，CS/AI领域释义优先
            3. cs_note: CS/AI领域的用法说明
            4. examples: 英文例句
            5. phrases: 相关英文术语
            
            严格返回以下JSON格式，不要有任何其他文字：
            {"word":"英文术语","phonetic":"/xxx/","definitions":[{"pos":"n.","cn":"原中文","en":"English definition"}],"cs_note":"CS note","examples":["example"],"phrases":["related"]}
            """
        }
        
        var finalPrompt = systemPrompt
        
        // Inject context match (strong hint) — forces the paper-specific translation
        if let match = contextMatch {
            finalPrompt += """
            
            
            ⚠️ 重要：用户正在阅读一篇特定论文。本词在该论文语境中的标准译法为：
            「\(match.term)」→「\(match.translation)」
            你的 definitions 第一条必须使用「\(match.translation)」作为中文释义（这是该论文中的确定含义），
            cs_note 中说明它在本文中的具体作用。其余字段（音标、例句、相关术语）正常补充。
            """
        } else if let context = paperContext, !context.isEmpty {
            // No direct match, but provide general context for disambiguation
            let termsList = context.prefix(25).map { "\($0.key) → \($0.value)" }.joined(separator: "\n")
            finalPrompt += """
            
            
            当前论文语境术语对照（供消歧参考，若用户查询的词与其中某项相关，请优先采用该译法）：
            \(termsList)
            """
        }
        
        let result = await callAPI(systemPrompt: finalPrompt, userText: word)
        
        switch result {
        case .success(let responseText):
            // Try to parse as JSON dictionary entry
            if let entry = parseDictionaryResponse(responseText, originalWord: word) {
                return .success(.dictionary(entry))
            } else {
                // Fallback: return as plain translation
                return .success(.translation(responseText))
            }
        case .failure(let error):
            return .failure(error)
        }
    }
    
    // MARK: - Context Matching
    
    /// Public check: does the word match any active context term? (used to bypass cache)
    func hasContextMatch(for word: String) -> Bool {
        return findContextMatch(for: word) != nil
    }
    
    /// Find a matching term in the paper context for the given word.
    /// Matches: exact key, abbreviation in parentheses, or word contained in key.
    private func findContextMatch(for word: String) -> (term: String, translation: String)? {
        guard let context = paperContext, !context.isEmpty else { return nil }
        
        let lowerWord = word.lowercased().trimmingCharacters(in: .whitespaces)
        
        // 1. Exact key match (case-insensitive)
        for (key, value) in context {
            if key.lowercased() == lowerWord {
                return (key, value)
            }
        }
        
        // 2. Abbreviation match: word appears in parentheses within a key
        //    e.g. "SFT" matches "Supervised fine-tuning (SFT)"
        for (key, value) in context {
            // Extract parenthetical abbreviations
            if let openParen = key.range(of: "("),
               let closeParen = key.range(of: ")") {
                let abbr = String(key[openParen.upperBound..<closeParen.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                if abbr.lowercased() == lowerWord {
                    return (key, value)
                }
            }
        }
        
        // 3. The word IS a known abbreviation key, or key starts with the word
        for (key, value) in context {
            let lowerKey = key.lowercased()
            // word matches the start of a multi-word key (e.g. "attention" → "attention mechanism")
            if lowerKey == lowerWord || lowerKey.hasPrefix(lowerWord + " ") {
                return (key, value)
            }
        }
        
        return nil
    }
    
    // MARK: - Sentence Translation (CS/AI Aware)
    
    private func translateSentence(_ text: String) async -> Result<String, TranslateError> {
        let targetLang = detectLanguage(text)
        
        var systemPrompt: String
        if targetLang == .chinese {
            systemPrompt = """
            你是一个计算机科学/AI领域的专业翻译。将用户输入翻译为中文。
            
            翻译原则：
            1. 专业术语使用CS/AI领域的标准译法（如 attention→注意力机制，transformer→Transformer，embedding→嵌入，fine-tuning→微调）
            2. 保留无需翻译的专有名词（如 GPT、BERT、ResNet、Adam）
            3. 译文要自然流畅，符合中文学术表达习惯
            4. 只输出翻译结果，不要解释
            """
        } else {
            systemPrompt = """
            你是一个计算机科学/AI领域的专业翻译。将用户输入翻译为英文。
            
            翻译原则：
            1. 使用CS/AI领域的标准英文术语
            2. 保持学术论文的正式语气
            3. 只输出翻译结果，不要解释
            """
        }
        
        // Inject paper context if available
        if let context = paperContext, !context.isEmpty {
            let termsList = context.prefix(20).map { "\($0.key) → \($0.value)" }.joined(separator: "\n")
            systemPrompt += """
            
            
            当前论文语境中的术语对照：
            \(termsList)
            请根据上述语境选择最合适的翻译。
            """
        }
        
        return await callAPI(systemPrompt: systemPrompt, userText: text)
    }
    
    // MARK: - API Call
    
    private func callAPI(systemPrompt: String, userText: String) async -> Result<String, TranslateError> {
        let body: [String: Any] = [
            "model": "deepseek-chat",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ],
            "max_tokens": 2048,
            "stream": false,
            "temperature": 0.3
        ]
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer placeholder", forHTTPHeaderField: "Authorization")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return .failure(.apiError("JSON序列化失败"))
        }
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.networkError("无效响应"))
            }
            
            guard httpResponse.statusCode == 200 else {
                return .failure(.apiError("HTTP \(httpResponse.statusCode)"))
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
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
    
    private func parseDictionaryResponse(_ text: String, originalWord: String) -> DictionaryEntry? {
        // The response might have markdown code fences or extra text
        var jsonStr = text
        
        // Strip markdown code block if present
        if jsonStr.contains("```") {
            let lines = jsonStr.components(separatedBy: "\n")
            var inBlock = false
            var blockLines: [String] = []
            for line in lines {
                if line.hasPrefix("```") {
                    inBlock.toggle()
                    continue
                }
                if inBlock {
                    blockLines.append(line)
                }
            }
            if !blockLines.isEmpty {
                jsonStr = blockLines.joined(separator: "\n")
            }
        }
        
        // Try to extract JSON object from response
        if let start = jsonStr.firstIndex(of: "{"),
           let end = jsonStr.lastIndex(of: "}") {
            jsonStr = String(jsonStr[start...end])
        }
        
        // Parse JSON
        guard let data = jsonStr.data(using: .utf8) else { return nil }
        
        do {
            let entry = try JSONDecoder().decode(DictionaryEntry.self, from: data)
            return entry
        } catch {
            print("[TranslateService] Failed to parse dictionary JSON: \(error)")
            return nil
        }
    }
    
    // MARK: - Language Detection
    
    enum TargetLanguage {
        case chinese
        case english
    }
    
    private func detectLanguage(_ text: String) -> TargetLanguage {
        let ratio = cjkCharacterRatio(text)
        return ratio > 0.3 ? .english : .chinese
    }
    
    private func cjkCharacterRatio(_ text: String) -> Double {
        let cjkCount = text.unicodeScalars.filter { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value) ||
            (0x3000...0x303F).contains(scalar.value)
        }.count
        return Double(cjkCount) / Double(max(text.unicodeScalars.count, 1))
    }
}
