import Foundation

/// Supported API protocols
enum APIProtocol: String, Codable, CaseIterable {
    case openai = "openai"
    case anthropic = "anthropic"
    
    var displayName: String {
        switch self {
        case .openai: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        }
    }
    
    /// Default endpoint suffix for chat completions
    var chatPath: String {
        switch self {
        case .openai: return "/v1/chat/completions"
        case .anthropic: return "/v1/messages"
        }
    }
}

/// API provider configuration
struct APIConfig: Codable {
    var provider: String          // "deepseek-proxy" or "custom"
    var url: String               // base URL (e.g., http://localhost:8765)
    var apiKey: String
    var model: String
    var `protocol`: APIProtocol
    var custom: Bool              // true = user-configured, false = auto-detected proxy
    
    /// Full chat endpoint URL
    var chatURL: String {
        let base = url.hasSuffix("/") ? String(url.dropLast()) : url
        // If the URL already ends with the chat path, don't append again
        if base.hasSuffix(`protocol`.chatPath) {
            return base
        }
        return base + `protocol`.chatPath
    }
    
    /// Default config for deepseek-copilot-proxy
    static let proxyDefault = APIConfig(
        provider: "deepseek-proxy",
        url: "http://localhost:8765",
        apiKey: "placeholder",
        model: "deepseek-chat",
        protocol: .openai,
        custom: false
    )
}

/// Manages API configuration persistence
class ConfigManager {
    static let shared = ConfigManager()
    
    private let configDir: String
    private let configPath: String
    
    private init() {
        configDir = NSHomeDirectory() + "/.translate"
        configPath = configDir + "/config.json"
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    }
    
    /// Load config from disk. Returns proxy default if no config exists.
    func load() -> APIConfig {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? JSONDecoder().decode(APIConfig.self, from: data) else {
            return .proxyDefault
        }
        return config
    }
    
    /// Save config to disk
    func save(_ config: APIConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: URL(fileURLWithPath: configPath))
    }
    
    /// Check if the proxy at localhost:8765 is reachable
    func isProxyReachable() -> Bool {
        guard let url = URL(string: "http://localhost:8765/v1/chat/completions") else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer placeholder", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "deepseek-chat",
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1,
            "stream": false
        ])
        request.timeoutInterval = 3
        
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if response is HTTPURLResponse {
                // Any response (even 4xx/5xx) means the proxy is alive
                reachable = true
            }
            semaphore.signal()
        }.resume()
        
        _ = semaphore.wait(timeout: .now() + 3.5)
        return reachable
    }
    
    /// Auto-detect and return the best config
    func autoDetect() -> APIConfig {
        let saved = load()
        
        // If user has explicitly set custom config, use it
        if saved.custom {
            print("[ConfigManager] Using custom config: \(saved.url) (\(saved.protocol.displayName))")
            return saved
        }
        
        // Check if deepseek-copilot-proxy is running
        if isProxyReachable() {
            print("[ConfigManager] ✅ deepseek-copilot-proxy detected at localhost:8765")
            return .proxyDefault
        }
        
        // Proxy not found, but we have a saved non-custom config
        if !saved.custom {
            print("[ConfigManager] ⚠️ deepseek-copilot-proxy not detected at localhost:8765")
        }
        
        return saved
    }
}
