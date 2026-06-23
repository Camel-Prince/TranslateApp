import Foundation
import SQLite3

/// Local vocabulary database using SQLite
/// Stores dictionary entries as JSON for fast offline lookup
class VocabularyDB {
    static let shared = VocabularyDB()
    
    private var db: OpaquePointer?
    private let dbPath: String
    private let queue = DispatchQueue(label: "com.translate.vocabdb", qos: .userInitiated)
    
    private init() {
        // Store in ~/.translate/vocabulary.db
        let dir = NSHomeDirectory() + "/.translate"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dbPath = dir + "/vocabulary.db"
        
        openDatabase()
        createTables()
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    // MARK: - Database Setup
    
    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[VocabularyDB] ❌ Failed to open database: \(dbPath)")
        }
        // Enable WAL mode for better concurrent performance
        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA synchronous=NORMAL")
    }
    
    private func createTables() {
        // Main vocabulary table
        execute("""
            CREATE TABLE IF NOT EXISTS vocabulary (
                word TEXT PRIMARY KEY COLLATE NOCASE,
                data TEXT NOT NULL,
                domain TEXT DEFAULT 'general',
                hits INTEGER DEFAULT 1,
                created_at TEXT DEFAULT (datetime('now')),
                updated_at TEXT DEFAULT (datetime('now'))
            )
        """)
        
        // Context table for paper-level term mappings
        execute("""
            CREATE TABLE IF NOT EXISTS context (
                paper_hash TEXT PRIMARY KEY,
                paper_title TEXT,
                terms TEXT NOT NULL,
                is_active INTEGER DEFAULT 1,
                created_at TEXT DEFAULT (datetime('now'))
            )
        """)
        
        // Migration: add is_active column if missing (for existing DBs)
        execute("ALTER TABLE context ADD COLUMN is_active INTEGER DEFAULT 1")
        
        // Custom term overrides (user-edited translations)
        execute("""
            CREATE TABLE IF NOT EXISTS custom_terms (
                term TEXT PRIMARY KEY COLLATE NOCASE,
                translation TEXT NOT NULL,
                updated_at TEXT DEFAULT (datetime('now'))
            )
        """)
        
        // Index for fast lookups
        execute("CREATE INDEX IF NOT EXISTS idx_vocab_domain ON vocabulary(domain)")
        execute("CREATE INDEX IF NOT EXISTS idx_context_hash ON context(paper_hash)")
    }
    
    // MARK: - Public API
    
    /// Look up a word in the local database
    /// Returns the cached DictionaryEntry JSON string if found, nil otherwise
    func lookup(_ word: String) -> DictionaryEntry? {
        var result: DictionaryEntry?
        queue.sync {
            let query = "SELECT data FROM vocabulary WHERE word = ? COLLATE NOCASE"
            var stmt: OpaquePointer?
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (word as NSString).utf8String, -1, nil)
                
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let cStr = sqlite3_column_text(stmt, 0) {
                        let json = String(cString: cStr)
                        result = DictionaryEntry.fromJSON(json)
                    }
                }
            }
            sqlite3_finalize(stmt)
            
            // Increment hit count
            if result != nil {
                execute("UPDATE vocabulary SET hits = hits + 1, updated_at = datetime('now') WHERE word = '\(word.replacingOccurrences(of: "'", with: "''"))' COLLATE NOCASE")
            }
        }
        return result
    }
    
    /// Save a dictionary entry to the database
    func save(word: String, entry: DictionaryEntry, domain: String = "cs") {
        queue.sync {
            guard let json = entry.toJSON() else { return }
            
            let query = """
                INSERT OR REPLACE INTO vocabulary (word, data, domain, hits, updated_at)
                VALUES (?, ?, ?, COALESCE((SELECT hits FROM vocabulary WHERE word = ? COLLATE NOCASE), 0) + 1, datetime('now'))
            """
            var stmt: OpaquePointer?
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (word as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (json as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (domain as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (word as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }
    
    /// Save paper context (terms mapping), active by default
    func saveContext(paperHash: String, paperTitle: String?, terms: [String: String]) {
        queue.sync {
            guard let jsonData = try? JSONSerialization.data(withJSONObject: terms),
                  let json = String(data: jsonData, encoding: .utf8) else { return }
            
            let query = "INSERT OR REPLACE INTO context (paper_hash, paper_title, terms, is_active, created_at) VALUES (?, ?, ?, 1, datetime('now'))"
            var stmt: OpaquePointer?
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (paperHash as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, ((paperTitle ?? "") as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (json as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }
    
    /// List all paper contexts with metadata
    func getAllContexts() -> [(hash: String, title: String, termCount: Int, isActive: Bool, createdAt: String)] {
        var results: [(hash: String, title: String, termCount: Int, isActive: Bool, createdAt: String)] = []
        queue.sync {
            let query = "SELECT paper_hash, paper_title, terms, is_active, created_at FROM context ORDER BY created_at DESC"
            var stmt: OpaquePointer?
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let hash = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "未知"
                    let termsJson = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "{}"
                    let isActive = sqlite3_column_int(stmt, 3) == 1
                    let createdAt = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                    
                    // Count terms
                    var termCount = 0
                    if let data = termsJson.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                        termCount = dict.count
                    }
                    
                    results.append((hash: hash, title: title, termCount: termCount, isActive: isActive, createdAt: createdAt))
                }
            }
            sqlite3_finalize(stmt)
        }
        return results
    }
    
    /// Toggle a paper context's active state
    func toggleContext(paperHash: String) {
        queue.sync {
            execute("UPDATE context SET is_active = CASE WHEN is_active = 1 THEN 0 ELSE 1 END WHERE paper_hash = '\(paperHash.replacingOccurrences(of: "'", with: "''"))'")
        }
    }
    
    /// Set all contexts active or inactive
    func setAllContextsActive(_ active: Bool) {
        queue.sync {
            execute("UPDATE context SET is_active = \(active ? 1 : 0)")
        }
    }
    
    /// Delete a paper context
    func deleteContext(paperHash: String) {
        queue.sync {
            execute("DELETE FROM context WHERE paper_hash = '\(paperHash.replacingOccurrences(of: "'", with: "''"))'")
        }
    }
    
    /// Get merged terms from active papers WITHOUT custom term overlay
    private func getRawMergedContext() -> [String: String] {
        var merged: [String: String] = [:]
        let query = "SELECT terms FROM context WHERE is_active = 1 ORDER BY created_at DESC"
        var stmt: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let termsJson = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "{}"
                if let data = termsJson.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    for (k, v) in dict {
                        merged[k] = v
                    }
                }
            }
        }
        sqlite3_finalize(stmt)
        return merged
    }
    
    /// Get the AI-generated terms only (without user customizations)
    func getAIGeneratedTerms() -> [String: String] {
        return getRawMergedContext()
    }
    
    func getMergedActiveContext() -> (titles: [String], terms: [String: String]) {
        var titles: [String] = []
        var merged: [String: String] = [:]
        queue.sync {
            let query = "SELECT paper_title, terms FROM context WHERE is_active = 1 ORDER BY created_at DESC"
            var stmt: OpaquePointer?
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let title = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let termsJson = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "{}"
                    
                    if !title.isEmpty { titles.append(title) }
                    
                    if let data = termsJson.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                        for (k, v) in dict {
                            merged[k] = v  // later papers override earlier ones
                        }
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        
        // Overlay custom user-edited terms (highest priority)
        let customs = getCustomTerms()
        for (k, v) in customs {
            merged[k] = v
        }
        
        return (titles: titles, terms: merged)
    }
    
    /// Get all user-customized term translations
    func getCustomTerms() -> [String: String] {
        var result: [String: String] = [:]
        queue.sync {
            let query = "SELECT term, translation FROM custom_terms ORDER BY term"
            var stmt: OpaquePointer?
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let term = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let trans = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    if !term.isEmpty { result[term] = trans }
                }
            }
            sqlite3_finalize(stmt)
        }
        return result
    }
    
    /// Save a single custom term translation
    func saveCustomTerm(term: String, translation: String) {
        queue.sync {
            let query = "INSERT OR REPLACE INTO custom_terms (term, translation, updated_at) VALUES (?, ?, datetime('now'))"
            var stmt: OpaquePointer?
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (term as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (translation as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }
    
    /// Bulk save custom terms from a dictionary
    func saveCustomTerms(_ terms: [String: String]) {
        queue.sync {
            for (term, translation) in terms {
                let query = "INSERT OR REPLACE INTO custom_terms (term, translation, updated_at) VALUES (?, ?, datetime('now'))"
                var stmt: OpaquePointer?
                
                if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (term as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 2, (translation as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
        }
    }
    
    /// Delete a custom term entry
    func deleteCustomTerm(_ term: String) {
        queue.sync {
            execute("DELETE FROM custom_terms WHERE term = '\(term.replacingOccurrences(of: "'", with: "''"))' COLLATE NOCASE")
        }
    }
    
    /// Backward-compatible: get merged active context terms only
    func getLatestContext() -> [String: String]? {
        let result = getMergedActiveContext()
        return result.terms.isEmpty ? nil : result.terms
    }
    
    /// Get vocabulary stats
    func stats() -> (total: Int, csTerms: Int) {
        var total = 0
        var cs = 0
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM vocabulary", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    total = Int(sqlite3_column_int(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
            
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM vocabulary WHERE domain = 'cs'", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    cs = Int(sqlite3_column_int(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
        }
        return (total, cs)
    }
    
    // MARK: - Helpers
    
    @discardableResult
    private func execute(_ sql: String) -> Bool {
        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            if let err = errMsg {
                print("[VocabularyDB] SQL Error: \(String(cString: err))")
                sqlite3_free(err)
            }
            return false
        }
        return true
    }
}

// MARK: - Data Models

struct DictionaryEntry: Codable {
    let word: String
    let phonetic: String?
    let definitions: [Definition]
    let csNote: String?       // CS/AI domain-specific note
    let examples: [String]?
    let phrases: [String]?
    
    enum CodingKeys: String, CodingKey {
        case word, phonetic, definitions, examples, phrases
        case csNote = "cs_note"
    }
    
    func toJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    static func fromJSON(_ json: String) -> DictionaryEntry? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DictionaryEntry.self, from: data)
    }
    
    /// Format as readable text for the popup
    func formatForDisplay() -> String {
        var lines: [String] = []
        
        // Word + phonetic
        var header = word
        if let ph = phonetic, !ph.isEmpty {
            header += "  \(ph)"
        }
        lines.append(header)
        lines.append("")
        
        // Definitions
        for def in definitions {
            lines.append("\(def.pos) \(def.cn)")
            if let en = def.en, !en.isEmpty {
                lines.append("   \(en)")
            }
        }
        
        // CS/AI note
        if let note = csNote, !note.isEmpty {
            lines.append("")
            lines.append("💡 CS/AI: \(note)")
        }
        
        // Examples
        if let exs = examples, !exs.isEmpty {
            lines.append("")
            lines.append("📝 例句:")
            for ex in exs.prefix(3) {
                lines.append("  • \(ex)")
            }
        }
        
        // Phrases
        if let phr = phrases, !phr.isEmpty {
            lines.append("")
            lines.append("🔗 相关: \(phr.joined(separator: ", "))")
        }
        
        return lines.joined(separator: "\n")
    }
}

struct Definition: Codable {
    let pos: String    // part of speech: "n.", "v.", "adj." etc.
    let cn: String     // Chinese definition
    let en: String?    // English definition (optional)
}
