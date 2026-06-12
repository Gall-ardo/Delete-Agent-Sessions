import CryptoKit
import Foundation
import SQLite3

public let delsesToolVersion = "0.1.0"

public enum Provider: String, Codable, CaseIterable, Equatable {
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }

    public var sessionsHeading: String {
        "\(displayName) sessions"
    }

    public func rootURL(env: [String: String], home: URL) -> URL {
        switch self {
        case .codex:
            return configuredURL(env["CODEX_HOME"], fallback: home.appendingPathComponent(".codex", isDirectory: true), home: home)
        case .claude:
            return configuredURL(env["CLAUDE_CONFIG_DIR"], fallback: home.appendingPathComponent(".claude", isDirectory: true), home: home)
        }
    }

    public func sessionDirectory(env: [String: String], home: URL) -> URL {
        switch self {
        case .codex:
            return rootURL(env: env, home: home).appendingPathComponent("sessions", isDirectory: true)
        case .claude:
            return rootURL(env: env, home: home).appendingPathComponent("projects", isDirectory: true)
        }
    }
}

public struct DelsesPaths: Equatable {
    public let home: URL

    public init(home: URL) {
        self.home = home.standardizedFileURL
    }

    public static func homeURL(env: [String: String]) -> URL {
        guard let home = env["HOME"], !home.isEmpty else {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
        }

        return configuredURL(home, fallback: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)).standardizedFileURL
    }

    public var root: URL {
        home.appendingPathComponent(".delses", isDirectory: true)
    }

    public var trashRoot: URL {
        root.appendingPathComponent("trash", isDirectory: true)
    }

    public var manifestsRoot: URL {
        root.appendingPathComponent("manifests", isDirectory: true)
    }

    public var logsRoot: URL {
        root.appendingPathComponent("logs", isDirectory: true)
    }
}

public enum DelsesError: Error, Equatable, CustomStringConvertible {
    case unsafeSource(String)
    case archiveMissing(String)
    case archiveOutsideTrash(String)
    case unsafeArchive(String)
    case destinationExists(String)
    case invalidCommand

    public var description: String {
        switch self {
        case .unsafeSource(let path):
            return "unsafe source file: \(path)"
        case .archiveMissing(let path):
            return "archive file is missing: \(path)"
        case .archiveOutsideTrash(let path):
            return "archive path is outside ~/.delses/trash: \(path)"
        case .unsafeArchive(let path):
            return "archive path is not a regular file in ~/.delses/trash: \(path)"
        case .destinationExists(let path):
            return "destination already exists: \(path)"
        case .invalidCommand:
            return "invalid command"
        }
    }
}

public protocol DelsesListItem {
    var title: String { get }
    var searchText: String { get }
    var sortDate: Date { get }
    var fileSize: Int64 { get }
    var detailPath: String { get }
}

public struct SessionCandidate: DelsesListItem, Equatable {
    public let provider: Provider
    public let url: URL
    public let title: String
    public let preview: String?
    public let modifiedAt: Date
    public let fileSize: Int64

    public init(provider: Provider, url: URL, title: String, preview: String? = nil, modifiedAt: Date, fileSize: Int64) {
        self.provider = provider
        self.url = url
        self.title = title
        self.preview = preview
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
    }

    public var searchText: String {
        "\(title) \(url.path)"
    }

    public var sortDate: Date {
        modifiedAt
    }

    public var detailPath: String {
        url.path
    }
}

public struct PagedList<Item: DelsesListItem> {
    public private(set) var items: [Item]
    public let pageSize: Int
    public private(set) var pageIndex: Int
    public private(set) var filter: String?

    public init(items: [Item], pageSize: Int = 15) {
        self.items = items
        self.pageSize = pageSize
        self.pageIndex = 0
        self.filter = nil
    }

    public var filteredItems: [Item] {
        guard let filter, !filter.isEmpty else {
            return items
        }

        return items.filter { $0.searchText.localizedCaseInsensitiveContains(filter) }
    }

    public var totalCount: Int {
        filteredItems.count
    }

    public var visibleStart: Int {
        totalCount == 0 ? 0 : pageIndex * pageSize + 1
    }

    public var visibleEnd: Int {
        min(totalCount, (pageIndex + 1) * pageSize)
    }

    public var currentPageItems: [Item] {
        let filtered = filteredItems
        let range = currentRange(total: filtered.count)
        return Array(filtered[range])
    }

    @discardableResult
    public mutating func nextPage() -> Bool {
        guard (pageIndex + 1) * pageSize < totalCount else {
            return false
        }

        pageIndex += 1
        return true
    }

    @discardableResult
    public mutating func previousPage() -> Bool {
        guard pageIndex > 0 else {
            return false
        }

        pageIndex -= 1
        return true
    }

    public mutating func setFilter(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        filter = normalized.isEmpty ? nil : normalized
        pageIndex = 0
    }

    public mutating func clearFilter() {
        filter = nil
        pageIndex = 0
    }

    public func item(displayNumber: Int) -> Item? {
        let index = displayNumber - 1
        let filtered = filteredItems
        let range = currentRange(total: filtered.count)
        guard range.contains(index) else {
            return nil
        }

        return filtered[index]
    }

    public func items(displayNumbers: [Int]) -> [Item]? {
        var resolved: [Item] = []
        for number in displayNumbers {
            guard let item = item(displayNumber: number) else {
                return nil
            }
            resolved.append(item)
        }

        return resolved
    }

    private func currentRange(total: Int) -> Range<Int> {
        guard total > 0 else {
            return 0..<0
        }

        let start = min(pageIndex * pageSize, total)
        let end = min(start + pageSize, total)
        return start..<end
    }
}

public final class SessionScanner {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func candidates(for provider: Provider, env: [String: String] = ProcessInfo.processInfo.environment, home: URL? = nil) throws -> [SessionCandidate] {
        let homeURL = home ?? DelsesPaths.homeURL(env: env)
        let sessionDirectory = provider.sessionDirectory(env: env, home: homeURL)
        let codexResolver = provider == .codex
            ? CodexSessionTitleResolver(codexRoot: provider.rootURL(env: env, home: homeURL), fileManager: fileManager)
            : nil

        guard isDirectory(sessionDirectory, fileManager: fileManager) else {
            return []
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]

        guard let enumerator = fileManager.enumerator(
            at: sessionDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var candidates: [SessionCandidate] = []

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)

            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if values.isDirectory == true {
                continue
            }

            guard values.isRegularFile == true else {
                continue
            }

            let codexTitle = codexResolver?.resolve(for: url)
            let title = codexTitle?.title ?? TitleExtractor.title(for: url, fileManager: fileManager)
            candidates.append(
                SessionCandidate(
                    provider: provider,
                    url: url.standardizedFileURL,
                    title: title,
                    preview: codexTitle?.preview,
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    fileSize: Int64(values.fileSize ?? 0)
                )
            )
        }

        return candidates.sorted {
            if $0.modifiedAt == $1.modifiedAt {
                return $0.url.path < $1.url.path
            }
            return $0.modifiedAt > $1.modifiedAt
        }
    }
}

public struct CodexTitleResolution: Equatable {
    public let title: String
    public let preview: String?

    public init(title: String, preview: String?) {
        self.title = title
        self.preview = preview
    }
}

public struct CodexSessionTitleResolver {
    private let codexRoot: URL
    private let fileManager: FileManager
    private let metadata: CodexTitleMetadata

    public init(codexRoot: URL, fileManager: FileManager = .default) {
        self.codexRoot = codexRoot.standardizedFileURL
        self.fileManager = fileManager
        self.metadata = CodexTitleMetadata.load(codexRoot: codexRoot.standardizedFileURL, fileManager: fileManager)
    }

    public func resolve(for url: URL) -> CodexTitleResolution {
        let standardizedURL = url.standardizedFileURL
        let fileInfo = CodexSessionFileInfo.read(url: standardizedURL, fileManager: fileManager)
        let keys = Self.lookupKeys(for: standardizedURL, codexRoot: codexRoot, identifiers: fileInfo.identifiers)

        let resolvedTitle = firstValue(in: metadata.resumeTitlesByKey, matching: keys)
            ?? fileInfo.metadataTitle
            ?? firstValue(in: metadata.historyTitlesByKey, matching: keys)
            ?? fileInfo.firstUserPrompt
            ?? "untitled session"

        let resolvedPreview = fileInfo.firstUserPrompt
            ?? firstValue(in: metadata.previewsByKey, matching: keys)

        return CodexTitleResolution(title: resolvedTitle, preview: resolvedPreview)
    }

    private func firstValue(in map: [String: String], matching keys: [String]) -> String? {
        for key in keys {
            if let value = map[key] {
                return value
            }
        }
        return nil
    }

    private static func lookupKeys(for url: URL, codexRoot: URL, identifiers: Set<String>) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()

        func appendKey(_ value: String?) {
            guard let key = CodexTitleMetadata.normalizedKey(value), !seen.contains(key) else {
                return
            }
            seen.insert(key)
            keys.append(key)
        }

        appendPathKeys(for: url, codexRoot: codexRoot, appendKey: appendKey)
        for identifier in identifiers {
            appendKey(identifier)
        }

        return keys
    }

    private static func appendPathKeys(for url: URL, codexRoot: URL, appendKey: (String?) -> Void) {
        appendKey(url.path)
        appendKey(url.lastPathComponent)
        appendKey(url.deletingPathExtension().lastPathComponent)

        let rootPath = codexRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            appendKey(String(path.dropFirst(rootPath.count + 1)))
        }

        appendKey(CodexTitleMetadata.uuid(in: url.lastPathComponent))
    }
}

private struct CodexTitleMetadata {
    var resumeTitlesByKey: [String: String] = [:]
    var historyTitlesByKey: [String: String] = [:]
    var previewsByKey: [String: String] = [:]

    static func load(codexRoot: URL, fileManager: FileManager) -> CodexTitleMetadata {
        var metadata = CodexTitleMetadata()
        metadata.loadStateDatabaseTitles(codexRoot: codexRoot, fileManager: fileManager)
        metadata.loadJSONMetadataTitles(codexRoot: codexRoot, fileManager: fileManager)
        return metadata
    }

    static func normalizedKey(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }

        return normalized.lowercased()
    }

    static func uuid(in value: String) -> String? {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let swiftRange = Range(match.range, in: value)
        else {
            return nil
        }

        return String(value[swiftRange])
    }

    private mutating func loadStateDatabaseTitles(codexRoot: URL, fileManager: FileManager) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: codexRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            return
        }

        let stateDatabases = urls.filter {
            $0.lastPathComponent.hasPrefix("state_")
                && $0.pathExtension == "sqlite"
                && isRegularFile($0, fileManager: fileManager)
        }

        for url in stateDatabases {
            loadStateDatabaseTitles(from: url, codexRoot: codexRoot)
        }
    }

    private mutating func loadStateDatabaseTitles(from url: URL, codexRoot: URL) {
        var database: OpaquePointer?
        let uri = sqliteReadOnlyURI(for: url)
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let database
        else {
            if database != nil {
                sqlite3_close(database)
            }
            return
        }

        defer {
            sqlite3_close(database)
        }

        let sql = "SELECT id, rollout_path, title, first_user_message, preview FROM threads"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            if statement != nil {
                sqlite3_finalize(statement)
            }
            return
        }

        defer {
            sqlite3_finalize(statement)
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            let identifiers = [sqliteColumnString(statement, 0)]
            let paths = [sqliteColumnString(statement, 1)]
            let keys = metadataKeys(identifiers: identifiers, paths: paths, codexRoot: codexRoot)

            if let title = SessionTitleSanitizer.normalizedTitle(sqliteColumnString(statement, 2)) {
                put(title, into: &resumeTitlesByKey, for: keys, replaceExisting: false)
            }

            let preview = SessionTitleSanitizer.normalizedPreview(sqliteColumnString(statement, 3))
                ?? SessionTitleSanitizer.normalizedPreview(sqliteColumnString(statement, 4))
            if let preview {
                put(preview, into: &previewsByKey, for: keys, replaceExisting: false)
            }
        }
    }

    private mutating func loadJSONMetadataTitles(codexRoot: URL, fileManager: FileManager) {
        for url in metadataJSONURLs(codexRoot: codexRoot, fileManager: fileManager) {
            let isHistory = url.lastPathComponent.lowercased().contains("history")
            for object in jsonObjects(from: url) {
                guard let title = CodexSessionFileInfo.metadataTitle(in: object) else {
                    continue
                }

                let identifiers = CodexSessionFileInfo.identifiers(in: object)
                let paths = Self.pathValues(in: object)
                let keys = metadataKeys(identifiers: Array(identifiers), paths: paths, codexRoot: codexRoot)
                if isHistory {
                    put(title, into: &historyTitlesByKey, for: keys, replaceExisting: false)
                } else {
                    put(title, into: &resumeTitlesByKey, for: keys, replaceExisting: false)
                }
            }
        }
    }

    private func metadataJSONURLs(codexRoot: URL, fileManager: FileManager) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: codexRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        return urls.filter { url in
            guard isRegularFile(url, fileManager: fileManager) else {
                return false
            }

            let name = url.lastPathComponent.lowercased()
            let extensionAllowed = url.pathExtension == "json" || url.pathExtension == "jsonl"
            let nameAllowed = name.contains("index") || name.contains("metadata") || name == "history.jsonl"
            return extensionAllowed && nameAllowed
        }
    }

    private func jsonObjects(from url: URL) -> [Any] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }

        if url.pathExtension == "json",
           let object = try? JSONSerialization.jsonObject(with: data)
        {
            if let array = object as? [Any] {
                return array
            }
            return [object]
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }

        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let lineData = String(line).data(using: .utf8) else {
                return nil
            }
            return try? JSONSerialization.jsonObject(with: lineData)
        }
    }

    private static func pathValues(in value: Any) -> [String?] {
        guard let dictionary = value as? [String: Any] else {
            return []
        }

        var values: [String?] = []
        for key in ["path", "rollout_path", "rolloutPath", "session_path", "sessionPath", "file", "filename"] {
            values.append(dictionary[key] as? String)
        }

        for key in ["payload", "metadata", "thread", "session"] {
            if let child = dictionary[key] as? [String: Any] {
                values.append(contentsOf: pathValues(in: child))
            }
        }

        return values
    }

    private func metadataKeys(identifiers: [String?], paths: [String?], codexRoot: URL) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()

        func appendKey(_ value: String?) {
            guard let key = Self.normalizedKey(value), !seen.contains(key) else {
                return
            }
            seen.insert(key)
            keys.append(key)
        }

        for identifier in identifiers {
            appendKey(identifier)
        }

        for path in paths {
            appendPathKeys(path, codexRoot: codexRoot, appendKey: appendKey)
        }

        return keys
    }

    private func appendPathKeys(_ rawPath: String?, codexRoot: URL, appendKey: (String?) -> Void) {
        guard let rawPath else {
            return
        }

        appendKey(rawPath)
        appendKey((rawPath as NSString).lastPathComponent)
        appendKey(((rawPath as NSString).lastPathComponent as NSString).deletingPathExtension)
        appendKey(Self.uuid(in: rawPath))

        let pathURL: URL
        if rawPath.hasPrefix("/") {
            pathURL = URL(fileURLWithPath: rawPath, isDirectory: false).standardizedFileURL
        } else {
            pathURL = codexRoot.appendingPathComponent(rawPath, isDirectory: false).standardizedFileURL
        }

        appendKey(pathURL.path)
        let rootPath = codexRoot.standardizedFileURL.path
        if pathURL.path.hasPrefix(rootPath + "/") {
            appendKey(String(pathURL.path.dropFirst(rootPath.count + 1)))
        }
    }

    private func put(_ value: String, into map: inout [String: String], for keys: [String], replaceExisting: Bool) {
        for key in keys {
            if replaceExisting || map[key] == nil {
                map[key] = value
            }
        }
    }

    private func sqliteReadOnlyURI(for url: URL) -> String {
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        return "file:\(path)?mode=ro&immutable=1"
    }

    private func sqliteColumnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else {
            return nil
        }

        return String(cString: UnsafeRawPointer(text).assumingMemoryBound(to: CChar.self))
    }
}

private struct CodexSessionFileInfo {
    var identifiers = Set<String>()
    var metadataTitle: String?
    var firstUserPrompt: String?

    static func read(url: URL, fileManager: FileManager) -> CodexSessionFileInfo {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return CodexSessionFileInfo()
        }

        defer {
            try? handle.close()
        }

        guard let data = try? handle.read(upToCount: 512 * 1024),
              let text = String(data: data, encoding: .utf8)
        else {
            return CodexSessionFileInfo()
        }

        var info = CodexSessionFileInfo()
        for line in text.split(whereSeparator: \.isNewline).prefix(400) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData)
            else {
                continue
            }

            info.identifiers.formUnion(identifiers(in: object))

            if info.metadataTitle == nil {
                info.metadataTitle = metadataTitle(in: object)
            }

            if info.firstUserPrompt == nil {
                info.firstUserPrompt = firstUserPrompt(in: object)
            }

            if info.metadataTitle != nil && info.firstUserPrompt != nil && !info.identifiers.isEmpty {
                break
            }
        }

        info.identifiers.insert(CodexTitleMetadata.uuid(in: url.lastPathComponent) ?? "")
        info.identifiers.remove("")
        return info
    }

    static func identifiers(in value: Any, depth: Int = 0) -> Set<String> {
        guard depth < 5 else {
            return []
        }

        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { result, item in
                result.formUnion(identifiers(in: item, depth: depth + 1))
            }
        }

        guard let dictionary = value as? [String: Any] else {
            return []
        }

        var values = Set<String>()
        for key in ["id", "session_id", "sessionId", "conversation_id", "conversationId", "thread_id", "threadId"] {
            if let value = dictionary[key] as? String {
                values.insert(value)
            }
        }

        for key in ["payload", "metadata", "thread", "session"] {
            if let child = dictionary[key] {
                values.formUnion(identifiers(in: child, depth: depth + 1))
            }
        }

        return values
    }

    static func metadataTitle(in value: Any) -> String? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }

        if let title = titleValue(in: dictionary, allowSummary: dictionaryHasSessionIdentity(dictionary)) {
            return title
        }

        for key in ["payload", "metadata", "thread", "session"] {
            guard let child = dictionary[key] as? [String: Any],
                  !isMessageOrToolPayload(child)
            else {
                continue
            }

            if let title = titleValue(in: child, allowSummary: dictionaryHasSessionIdentity(child)) {
                return title
            }
        }

        return nil
    }

    private static func titleValue(in dictionary: [String: Any], allowSummary: Bool) -> String? {
        let strongKeys = ["renamed_title", "renamedTitle", "custom_title", "customTitle", "thread_name", "threadName", "title", "name"]
        for key in strongKeys {
            if let title = SessionTitleSanitizer.normalizedTitle(dictionary[key] as? String) {
                return title
            }
        }

        if allowSummary,
           let title = SessionTitleSanitizer.normalizedTitle(dictionary["summary"] as? String)
        {
            return title
        }

        return nil
    }

    private static func firstUserPrompt(in value: Any) -> String? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }

        let payload = dictionary["payload"] as? [String: Any] ?? dictionary
        guard (payload["role"] as? String) == "user" else {
            return nil
        }

        if let content = payload["content"],
           let text = textFromContent(content)
        {
            return SessionTitleSanitizer.normalizedTitle(text)
        }

        if let message = payload["message"] as? String {
            return SessionTitleSanitizer.normalizedTitle(message)
        }

        if let text = payload["text"] as? String {
            return SessionTitleSanitizer.normalizedTitle(text)
        }

        return nil
    }

    private static func textFromContent(_ value: Any) -> String? {
        if let string = value as? String {
            return string
        }

        if let array = value as? [Any] {
            let parts = array.compactMap { item -> String? in
                guard let dictionary = item as? [String: Any] else {
                    return nil
                }

                let type = (dictionary["type"] as? String)?.lowercased()
                guard type == nil || type == "input_text" || type == "text" else {
                    return nil
                }

                return dictionary["text"] as? String
            }
            let joined = parts.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }

        if let dictionary = value as? [String: Any] {
            return dictionary["text"] as? String
        }

        return nil
    }

    private static func dictionaryHasSessionIdentity(_ dictionary: [String: Any]) -> Bool {
        for key in ["id", "session_id", "sessionId", "conversation_id", "conversationId", "thread_id", "threadId"] {
            if dictionary[key] is String {
                return true
            }
        }
        return false
    }

    private static func isMessageOrToolPayload(_ dictionary: [String: Any]) -> Bool {
        if let role = (dictionary["role"] as? String)?.lowercased(),
           role == "system" || role == "developer" || role == "assistant" || role == "tool"
        {
            return true
        }

        if let type = (dictionary["type"] as? String)?.lowercased(),
           type == "function_call" || type == "function_call_output" || type == "tool_output"
        {
            return true
        }

        return false
    }
}

private enum SessionTitleSanitizer {
    static func normalizedTitle(_ value: String?, maxLength: Int = 40) -> String? {
        normalized(value, maxLength: maxLength)
    }

    static func normalizedPreview(_ value: String?, maxLength: Int = 120) -> String? {
        normalized(value, maxLength: maxLength)
    }

    private static func normalized(_ value: String?, maxLength: Int) -> String? {
        guard let value else {
            return nil
        }

        let collapsed = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty, !isRejected(collapsed) else {
            return nil
        }

        guard collapsed.count > maxLength else {
            return collapsed
        }

        return "\(collapsed.prefix(max(1, maxLength - 3)))..."
    }

    private static func isRejected(_ value: String) -> Bool {
        let lower = value.lowercased()
        let rejectedPrefixes = [
            "<skills_instructions>",
            "## skills",
            "you are codex",
            "you are chatgpt",
            "you are an ai assistant",
            "context — read fully",
            "context - read fully",
            "environment",
            "knowledge cutoff:",
            "system",
            "system prompt",
            "developer",
            "developer prompt",
            "system:",
            "developer:",
            "<environment_context>",
            "<system",
            "<developer"
        ]

        if rejectedPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        let rejectedFragments = [
            "tools are grouped by namespace",
            "desired oververbosity",
            "filesystem sandboxing",
            "collaboration_mode",
            "developer instructions",
            "system message",
            "tool output",
            "<environment_context>"
        ]

        if rejectedFragments.contains(where: { lower.contains($0) }) {
            return true
        }

        return false
    }
}

public enum TitleExtractor {
    private static let maxBytes = 64 * 1024

    public static func title(for url: URL, fileManager: FileManager = .default) -> String {
        optionalTitle(for: url, fileManager: fileManager) ?? "untitled session"
    }

    public static func optionalTitle(for url: URL, fileManager: FileManager = .default) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }

        defer {
            try? handle.close()
        }

        guard let data = try? handle.read(upToCount: maxBytes),
              let title = title(from: data)
        else {
            return nil
        }

        return title
    }

    public static func title(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = text.split(whereSeparator: \.isNewline).prefix(80)
        for line in lines {
            let rawLine = String(line)
            guard let lineData = rawLine.data(using: .utf8) else {
                continue
            }

            if let json = try? JSONSerialization.jsonObject(with: lineData) {
                if let title = firstString(in: json, matching: ["title", "summary"], depth: 0) {
                    return title
                }
                if let title = firstString(in: json, matching: ["prompt", "input", "text", "content"], depth: 0) {
                    return title
                }
            } else if let title = normalized(rawLine) {
                return title
            }
        }

        return nil
    }

    private static func firstString(in value: Any, matching keys: [String], depth: Int) -> String? {
        guard depth < 8 else {
            return nil
        }

        if let array = value as? [Any] {
            for item in array {
                if let result = firstString(in: item, matching: keys, depth: depth + 1) {
                    return result
                }
            }
            return nil
        }

        guard let dictionary = value as? [String: Any] else {
            return nil
        }

        for key in keys {
            if let child = dictionary[key],
               let result = stringValue(in: child, matching: keys, depth: depth + 1)
            {
                return result
            }
        }

        for child in dictionary.values {
            if let result = firstString(in: child, matching: keys, depth: depth + 1) {
                return result
            }
        }

        return nil
    }

    private static func stringValue(in value: Any, matching keys: [String], depth: Int) -> String? {
        guard depth < 8 else {
            return nil
        }

        if let string = value as? String {
            return normalized(string)
        }

        if let array = value as? [Any] {
            for item in array {
                if let result = stringValue(in: item, matching: keys, depth: depth + 1) {
                    return result
                }
                if let result = firstString(in: item, matching: keys, depth: depth + 1) {
                    return result
                }
            }
            return nil
        }

        if let dictionary = value as? [String: Any] {
            return firstString(in: dictionary, matching: keys, depth: depth + 1)
        }

        return nil
    }

    private static func normalized(_ value: String) -> String? {
        SessionTitleSanitizer.normalizedTitle(value)
    }
}

public struct ArchiveManifest: Codable, Equatable {
    public let provider: Provider
    public let originalPath: String
    public let archivePath: String
    public let title: String?
    public let preview: String?
    public let sha256Before: String
    public let fileSize: Int64
    public let modifiedAt: Date
    public let archivedAt: Date
    public let toolVersion: String
    public let status: String?
    public let purgedAt: Date?

    public init(
        provider: Provider,
        originalPath: String,
        archivePath: String,
        title: String? = nil,
        preview: String? = nil,
        sha256Before: String,
        fileSize: Int64,
        modifiedAt: Date,
        archivedAt: Date,
        toolVersion: String,
        status: String? = nil,
        purgedAt: Date? = nil
    ) {
        self.provider = provider
        self.originalPath = originalPath
        self.archivePath = archivePath
        self.title = title
        self.preview = preview
        self.sha256Before = sha256Before
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.archivedAt = archivedAt
        self.toolVersion = toolVersion
        self.status = status
        self.purgedAt = purgedAt
    }

    public var isPurged: Bool {
        status == "purged"
    }

    public func purged(now: Date) -> ArchiveManifest {
        ArchiveManifest(
            provider: provider,
            originalPath: originalPath,
            archivePath: archivePath,
            title: title,
            preview: preview,
            sha256Before: sha256Before,
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            archivedAt: archivedAt,
            toolVersion: toolVersion,
            status: "purged",
            purgedAt: now
        )
    }

    public func withDisplayMetadata(title: String, preview: String) -> ArchiveManifest {
        ArchiveManifest(
            provider: provider,
            originalPath: originalPath,
            archivePath: archivePath,
            title: title,
            preview: preview,
            sha256Before: sha256Before,
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            archivedAt: archivedAt,
            toolVersion: toolVersion,
            status: status,
            purgedAt: purgedAt
        )
    }
}

public struct ArchivedSession: DelsesListItem, Equatable {
    public let manifestURL: URL
    public let manifest: ArchiveManifest
    public let title: String

    public init(manifestURL: URL, manifest: ArchiveManifest, title: String) {
        self.manifestURL = manifestURL
        self.manifest = manifest
        self.title = title
    }

    public var searchText: String {
        "\(manifest.provider.rawValue) \(title) \(manifest.originalPath) \(manifest.archivePath)"
    }

    public var sortDate: Date {
        manifest.archivedAt
    }

    public var fileSize: Int64 {
        manifest.fileSize
    }

    public var detailPath: String {
        manifest.originalPath
    }
}

public final class ArchiveService {
    private let fileManager: FileManager
    public let paths: DelsesPaths
    public let toolVersion: String

    public init(paths: DelsesPaths, fileManager: FileManager = .default, toolVersion: String = delsesToolVersion) {
        self.paths = paths
        self.fileManager = fileManager
        self.toolVersion = toolVersion
    }

    public convenience init(env: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default, toolVersion: String = delsesToolVersion) {
        self.init(paths: DelsesPaths(home: DelsesPaths.homeURL(env: env)), fileManager: fileManager, toolVersion: toolVersion)
    }

    public func archive(_ candidate: SessionCandidate, now: Date = Date()) throws -> ArchiveManifest {
        guard isRegularFile(candidate.url, fileManager: fileManager) else {
            throw DelsesError.unsafeSource(candidate.url.path)
        }

        try ensureStorageDirectories()

        let archiveID = UUID().uuidString.lowercased()
        let archiveDirectory = paths.trashRoot.appendingPathComponent(archiveID, isDirectory: true)
        try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)

        let destinationName = candidate.url.lastPathComponent.isEmpty ? "session" : candidate.url.lastPathComponent
        let archiveURL = archiveDirectory.appendingPathComponent(destinationName, isDirectory: false)

        let sha256Before = try sha256Hex(for: candidate.url)
        let manifest = ArchiveManifest(
            provider: candidate.provider,
            originalPath: candidate.url.path,
            archivePath: archiveURL.path,
            title: SessionTitleSanitizer.normalizedTitle(candidate.title) ?? "untitled session",
            preview: SessionTitleSanitizer.normalizedPreview(candidate.preview) ?? "",
            sha256Before: sha256Before,
            fileSize: candidate.fileSize,
            modifiedAt: candidate.modifiedAt,
            archivedAt: now,
            toolVersion: toolVersion
        )

        let manifestURL = paths.manifestsRoot.appendingPathComponent("\(archiveID).json", isDirectory: false)

        do {
            try fileManager.moveItem(at: candidate.url, to: archiveURL)
            let data = try manifestEncoder().encode(manifest)
            try data.write(to: manifestURL, options: [.atomic])
            appendLog("archive provider=\(candidate.provider.rawValue) original=\(candidate.url.path) archive=\(archiveURL.path)", now: now)
            return manifest
        } catch {
            if fileManager.fileExists(atPath: archiveURL.path),
               !fileManager.fileExists(atPath: candidate.url.path)
            {
                try? fileManager.moveItem(at: archiveURL, to: candidate.url)
            }
            throw error
        }
    }

    public func archivedSessions() throws -> [ArchivedSession] {
        guard isDirectory(paths.manifestsRoot, fileManager: fileManager) else {
            return []
        }

        let manifestURLs = try fileManager.contentsOfDirectory(
            at: paths.manifestsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        )

        var archived: [ArchivedSession] = []
        for manifestURL in manifestURLs where manifestURL.pathExtension == "json" {
            guard isRegularFile(manifestURL, fileManager: fileManager) else {
                continue
            }

            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? manifestDecoder().decode(ArchiveManifest.self, from: data)
            else {
                continue
            }

            guard !manifest.isPurged else {
                continue
            }

            let archiveURL = URL(fileURLWithPath: manifest.archivePath, isDirectory: false)
            guard isPath(archiveURL, inside: paths.trashRoot) else {
                continue
            }
            guard isRegularFile(archiveURL, fileManager: fileManager) else {
                continue
            }

            archived.append(
                resolvedArchivedSession(
                    manifestURL: manifestURL.standardizedFileURL,
                    manifest: manifest,
                    archiveURL: archiveURL
                )
            )
        }

        return archived.sorted {
            if $0.manifest.archivedAt == $1.manifest.archivedAt {
                return $0.manifest.originalPath < $1.manifest.originalPath
            }
            return $0.manifest.archivedAt > $1.manifest.archivedAt
        }
    }

    public func restore(_ archivedSession: ArchivedSession, now: Date = Date()) throws {
        let archiveURL = URL(fileURLWithPath: archivedSession.manifest.archivePath, isDirectory: false)
        let originalURL = URL(fileURLWithPath: archivedSession.manifest.originalPath, isDirectory: false)

        guard isPath(archiveURL, inside: paths.trashRoot) else {
            throw DelsesError.archiveOutsideTrash(archiveURL.path)
        }

        guard isRegularFile(archiveURL, fileManager: fileManager) else {
            throw DelsesError.archiveMissing(archiveURL.path)
        }

        guard !fileManager.fileExists(atPath: originalURL.path) else {
            throw DelsesError.destinationExists(originalURL.path)
        }

        try fileManager.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: archiveURL, to: originalURL)
        try? fileManager.removeItem(at: archivedSession.manifestURL)
        appendLog("restore provider=\(archivedSession.manifest.provider.rawValue) original=\(originalURL.path) archive=\(archiveURL.path)", now: now)
    }

    public func purge(_ archivedSession: ArchivedSession, now: Date = Date()) throws {
        let archiveURL = URL(fileURLWithPath: archivedSession.manifest.archivePath, isDirectory: false)
        try validatePurgableArchiveURL(archiveURL)

        let purgedManifest = archivedSession.manifest.purged(now: now)
        let data = try manifestEncoder().encode(purgedManifest)
        try data.write(to: archivedSession.manifestURL, options: [.atomic])

        try fileManager.removeItem(at: archiveURL)
    }

    private func resolvedArchivedSession(manifestURL: URL, manifest: ArchiveManifest, archiveURL: URL) -> ArchivedSession {
        if let title = SessionTitleSanitizer.normalizedTitle(manifest.title) {
            return ArchivedSession(manifestURL: manifestURL, manifest: manifest, title: title)
        }

        if let fallback = titleFromOriginalPath(manifest) {
            let migrated = manifest.withDisplayMetadata(title: fallback.title, preview: fallback.preview)
            if writeManifest(migrated, to: manifestURL) {
                return ArchivedSession(manifestURL: manifestURL, manifest: migrated, title: fallback.title)
            }

            return ArchivedSession(manifestURL: manifestURL, manifest: manifest, title: "untitled session")
        }

        if let archiveTitle = TitleExtractor.optionalTitle(for: archiveURL, fileManager: fileManager) {
            return ArchivedSession(manifestURL: manifestURL, manifest: manifest, title: archiveTitle)
        }

        return ArchivedSession(manifestURL: manifestURL, manifest: manifest, title: "untitled session")
    }

    private func titleFromOriginalPath(_ manifest: ArchiveManifest) -> (title: String, preview: String)? {
        let originalURL = URL(fileURLWithPath: manifest.originalPath, isDirectory: false).standardizedFileURL

        switch manifest.provider {
        case .codex:
            guard let codexRoot = inferredRoot(for: originalURL, marker: "sessions") else {
                return nil
            }

            let resolved = CodexSessionTitleResolver(codexRoot: codexRoot, fileManager: fileManager).resolve(for: originalURL)
            guard let title = SessionTitleSanitizer.normalizedTitle(resolved.title),
                  title != "untitled session"
            else {
                return nil
            }

            return (title, SessionTitleSanitizer.normalizedPreview(resolved.preview) ?? "")

        case .claude:
            guard isRegularFile(originalURL, fileManager: fileManager),
                  let title = TitleExtractor.optionalTitle(for: originalURL, fileManager: fileManager)
            else {
                return nil
            }

            return (title, "")
        }
    }

    private func inferredRoot(for url: URL, marker: String) -> URL? {
        let components = url.standardizedFileURL.pathComponents
        guard let markerIndex = components.firstIndex(of: marker), markerIndex > 0 else {
            return nil
        }

        let rootComponents = Array(components.prefix(markerIndex))
        guard !rootComponents.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: NSString.path(withComponents: rootComponents), isDirectory: true).standardizedFileURL
    }

    private func writeManifest(_ manifest: ArchiveManifest, to url: URL) -> Bool {
        guard let data = try? manifestEncoder().encode(manifest) else {
            return false
        }

        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private func validatePurgableArchiveURL(_ archiveURL: URL) throws {
        guard isPath(archiveURL, inside: paths.trashRoot) else {
            throw DelsesError.archiveOutsideTrash(archiveURL.path)
        }

        let canonicalTrashRoot = paths.trashRoot.resolvingSymlinksInPath().standardizedFileURL
        let canonicalArchiveURL = archiveURL.resolvingSymlinksInPath().standardizedFileURL
        guard isPath(canonicalArchiveURL, inside: canonicalTrashRoot) else {
            throw DelsesError.archiveOutsideTrash(archiveURL.path)
        }

        guard fileManager.fileExists(atPath: archiveURL.path) else {
            throw DelsesError.archiveMissing(archiveURL.path)
        }

        guard isRegularFile(archiveURL, fileManager: fileManager) else {
            throw DelsesError.unsafeArchive(archiveURL.path)
        }
    }

    private func ensureStorageDirectories() throws {
        try fileManager.createDirectory(at: paths.trashRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.manifestsRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.logsRoot, withIntermediateDirectories: true)
    }

    private func appendLog(_ message: String, now: Date) {
        try? fileManager.createDirectory(at: paths.logsRoot, withIntermediateDirectories: true)
        let logURL = paths.logsRoot.appendingPathComponent("delses.log", isDirectory: false)
        let line = "\(isoFormatter().string(from: now)) \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        if !fileManager.fileExists(atPath: logURL.path) {
            try? data.write(to: logURL, options: [.atomic])
            return
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            return
        }

        defer {
            try? handle.close()
        }

        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

public protocol DelsesIO: AnyObject {
    func write(_ value: String)
    func readLine() -> String?
}

public final class ConsoleIO: DelsesIO {
    public init() {}

    public func write(_ value: String) {
        Swift.print(value, terminator: "")
    }

    public func readLine() -> String? {
        Swift.readLine()
    }
}

public final class DelsesApp {
    private let env: [String: String]
    private let fileManager: FileManager
    private let io: DelsesIO
    private let now: () -> Date

    public init(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        io: DelsesIO = ConsoleIO(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.env = env
        self.fileManager = fileManager
        self.io = io
        self.now = now
    }

    public func run(arguments: [String]) -> Int {
        guard arguments.count == 1 else {
            io.write(Self.usage)
            return 2
        }

        do {
            switch arguments[0] {
            case "codex":
                return try runProvider(.codex)
            case "claude":
                return try runProvider(.claude)
            case "restore":
                return try runRestore()
            case "purge":
                return try runPurge()
            default:
                io.write(Self.usage)
                return 2
            }
        } catch let error as DelsesError {
            io.write("Error: \(error.description)\n")
            return 1
        } catch {
            io.write("Error: \(error.localizedDescription)\n")
            return 1
        }
    }

    private func runProvider(_ provider: Provider) throws -> Int {
        let home = DelsesPaths.homeURL(env: env)
        let scanner = SessionScanner(fileManager: fileManager)
        let candidates = try scanner.candidates(for: provider, env: env, home: home)
        var list = PagedList(items: candidates, pageSize: 15)

        while true {
            io.write(TerminalRenderer.renderList(heading: provider.sessionsHeading, list: list, dateLabel: "modified", now: now()))

            guard let input = io.readLine() else {
                return 0
            }

            let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if command == "q" {
                return 0
            } else if command == "n" {
                _ = list.nextPage()
            } else if command == "p" {
                _ = list.previousPage()
            } else if command == "/clear" {
                list.clearFilter()
            } else if command.hasPrefix("/") {
                list.setFilter(String(command.dropFirst()))
            } else if let selectedNumbers = Self.parseSelectionInput(command),
                      let selectedItems = list.items(displayNumbers: selectedNumbers)
            {
                io.write(TerminalRenderer.renderSelectedSessions(selection: zip(selectedNumbers, selectedItems).map { ($0, $1) }, now: now()))
                let confirmation = io.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard confirmation == "yes" else {
                    io.write("Archive cancelled.\n")
                    return 0
                }

                let service = ArchiveService(paths: DelsesPaths(home: home), fileManager: fileManager)
                for selected in selectedItems {
                    _ = try service.archive(selected, now: now())
                }
                io.write("Moved to local archive.\nRestore with: delses restore\n")
                return 0
            } else {
                io.write("Invalid input.\n")
            }
        }
    }

    private func runRestore() throws -> Int {
        let home = DelsesPaths.homeURL(env: env)
        let service = ArchiveService(paths: DelsesPaths(home: home), fileManager: fileManager)
        var list = PagedList(items: try service.archivedSessions(), pageSize: 15)

        while true {
            io.write(TerminalRenderer.renderList(heading: "Local archive", list: list, dateLabel: "archived", now: now()))

            guard let input = io.readLine() else {
                return 0
            }

            let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if command == "q" {
                return 0
            } else if command == "n" {
                _ = list.nextPage()
            } else if command == "p" {
                _ = list.previousPage()
            } else if command == "/clear" {
                list.clearFilter()
            } else if command.hasPrefix("/") {
                list.setFilter(String(command.dropFirst()))
            } else if let selectedNumbers = Self.parseSelectionInput(command),
                      let selectedItems = list.items(displayNumbers: selectedNumbers)
            {
                io.write(TerminalRenderer.renderSelectedArchives(selection: zip(selectedNumbers, selectedItems).map { ($0, $1) }, now: now()))
                let confirmation = io.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard confirmation == "yes" else {
                    io.write("Restore cancelled.\n")
                    return 0
                }

                var restored = 0
                var skipped: [String] = []
                for selected in selectedItems {
                    do {
                        try service.restore(selected, now: now())
                        restored += 1
                    } catch DelsesError.destinationExists {
                        skipped.append(selected.title)
                    }
                }

                io.write(TerminalRenderer.renderRestoreResult(restoredCount: restored, skippedTitles: skipped))
                return 0
            } else {
                io.write("Invalid input.\n")
            }
        }
    }

    private func runPurge() throws -> Int {
        let home = DelsesPaths.homeURL(env: env)
        let service = ArchiveService(paths: DelsesPaths(home: home), fileManager: fileManager)
        var list = PagedList(items: try service.archivedSessions(), pageSize: 15)

        while true {
            io.write(TerminalRenderer.renderArchivedList(heading: "Archived sessions", list: list, now: now()))

            guard let input = io.readLine() else {
                return 0
            }

            let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if command == "q" {
                return 0
            } else if command == "n" {
                _ = list.nextPage()
            } else if command == "p" {
                _ = list.previousPage()
            } else if command == "/clear" {
                list.clearFilter()
            } else if command.hasPrefix("/") {
                list.setFilter(String(command.dropFirst()))
            } else if let selectedNumbers = Self.parseSelectionInput(command),
                      let selectedItems = list.items(displayNumbers: selectedNumbers)
            {
                io.write(TerminalRenderer.renderSelectedPurges(selection: zip(selectedNumbers, selectedItems).map { ($0, $1) }, now: now()))
                let confirmation = io.readLine()
                guard confirmation == "purge" else {
                    io.write("Purge cancelled.\n")
                    return 0
                }

                for selected in selectedItems {
                    try service.purge(selected, now: now())
                }
                io.write("Purged archived copy.\n")
                return 0
            } else {
                io.write("Invalid input.\n")
            }
        }
    }

    private static func parseSelectionInput(_ input: String) -> [Int]? {
        guard input.range(of: #"^[0-9,\s]+$"#, options: .regularExpression) != nil else {
            return nil
        }

        let tokens = input.split { $0 == "," || $0.isWhitespace }
        guard !tokens.isEmpty else {
            return nil
        }

        var numbers: [Int] = []
        var seen = Set<Int>()
        for token in tokens {
            guard let number = Int(token), number > 0 else {
                return nil
            }

            if seen.insert(number).inserted {
                numbers.append(number)
            }
        }

        return numbers
    }

    private static let usage = """
    Usage:
    delses codex
    delses claude
    delses restore
    delses purge
    """
}

public enum TerminalRenderer {
    public static func renderList<Item: DelsesListItem>(heading: String, list: PagedList<Item>, dateLabel: String, now: Date) -> String {
        var output = ""
        output += "\(heading)\n"
        output += "Showing \(list.visibleStart)-\(list.visibleEnd) of \(list.totalCount)\n\n"

        let startNumber = list.visibleStart
        for (offset, item) in list.currentPageItems.enumerated() {
            let number = startNumber + offset
            let title = paddedTitle(item.title)
            let date = formatRelativeDate(item.sortDate, now: now)
            let size = formatSize(item.fileSize)
            output += "[\(number)] \(title) \(dateLabel): \(date)   size: \(size)\n"
        }

        if list.totalCount == 0 {
            output += "No sessions found.\n"
        }

        output += "\n"
        output += "Commands:\n"
        output += "number = choose\n"
        output += "n = next page\n"
        output += "p = previous page\n"
        output += "/word = filter\n"
        output += "/clear = clear filter\n"
        output += "q = quit\n\n"
        output += "Input: "
        return output
    }

    public static func renderArchivedList(heading: String, list: PagedList<ArchivedSession>, now: Date) -> String {
        var output = ""
        output += "\(heading)\n"
        output += "Showing \(list.visibleStart)-\(list.visibleEnd) of \(list.totalCount)\n\n"

        let startNumber = list.visibleStart
        for (offset, item) in list.currentPageItems.enumerated() {
            let number = startNumber + offset
            let title = paddedTitle(item.title)
            let provider = paddedProvider(item.manifest.provider.displayName)
            let date = formatRelativeDate(item.manifest.archivedAt, now: now)
            let size = formatSize(item.fileSize)
            output += "[\(number)] \(title) provider: \(provider) archived: \(date)   size: \(size)\n"
        }

        if list.totalCount == 0 {
            output += "No sessions found.\n"
        }

        output += "\n"
        output += "Commands:\n"
        output += "number = choose\n"
        output += "n = next page\n"
        output += "p = previous page\n"
        output += "/word = filter\n"
        output += "/clear = clear filter\n"
        output += "q = quit\n\n"
        output += "Input: "
        return output
    }

    public static func renderSelectedSession(number: Int, session: SessionCandidate, now: Date) -> String {
        let previewLine = session.preview.map { "Preview: \($0)\n" } ?? ""
        return """

        Selected:
        [\(number)] \(session.title)
        Modified: \(formatRelativeDate(session.modifiedAt, now: now))
        Size: \(formatSize(session.fileSize))
        \(previewLine)\
        Path: \(session.url.path)

        This will move the selected session to local archive, not permanently remove it.
        Continue? type yes: 
        """
    }

    public static func renderSelectedSessions(selection: [(Int, SessionCandidate)], now: Date) -> String {
        var output = "\nSelected:\n"
        for (number, session) in selection {
            output += "[\(number)] \(session.title)\n"
            output += "Modified: \(formatRelativeDate(session.modifiedAt, now: now))\n"
            output += "Size: \(formatSize(session.fileSize))\n"
            if let preview = session.preview {
                output += "Preview: \(preview)\n"
            }
            output += "Path: \(session.url.path)\n\n"
        }

        output += "This will move the selected session to local archive, not permanently remove it.\n"
        output += "Continue? type yes: "
        return output
    }

    public static func renderSelectedArchive(number: Int, archived: ArchivedSession, now: Date) -> String {
        """

        Selected:
        [\(number)] \(archived.title)
        Provider: \(archived.manifest.provider.rawValue)
        Archived: \(formatRelativeDate(archived.manifest.archivedAt, now: now))
        Size: \(formatSize(archived.fileSize))
        Original path: \(archived.manifest.originalPath)
        Archive path: \(archived.manifest.archivePath)

        This will restore the selected session to its original path.
        Existing files are not overwritten.
        Continue? type yes: 
        """
    }

    public static func renderSelectedArchives(selection: [(Int, ArchivedSession)], now: Date) -> String {
        var output = "\nSelected:\n"
        for (number, archived) in selection {
            output += "[\(number)] \(archived.title)\n"
            output += "Provider: \(archived.manifest.provider.displayName)\n"
            output += "Archived: \(formatRelativeDate(archived.manifest.archivedAt, now: now))\n"
            output += "Size: \(formatSize(archived.fileSize))\n"
            output += "Original path: \(archived.manifest.originalPath)\n"
            output += "Archive path: \(archived.manifest.archivePath)\n\n"
        }

        output += "This will restore the selected session to its original path.\n"
        output += "Existing files are not overwritten.\n"
        output += "Continue? type yes: "
        return output
    }

    public static func renderSelectedPurge(number: Int, archived: ArchivedSession, now: Date) -> String {
        """

        Selected:
        [\(number)] \(archived.title)
        Provider: \(archived.manifest.provider.displayName)
        Archived: \(formatRelativeDate(archived.manifest.archivedAt, now: now))
        Size: \(formatSize(archived.fileSize))
        Original path: \(archived.manifest.originalPath)
        Archive path: \(archived.manifest.archivePath)

        This will permanently remove this archived copy.
        It will not touch the original Codex/Claude directories.
        Continue? type purge: 
        """
    }

    public static func renderSelectedPurges(selection: [(Int, ArchivedSession)], now: Date) -> String {
        var output = "\nSelected:\n"
        for (number, archived) in selection {
            output += "[\(number)] \(archived.title)\n"
            output += "Provider: \(archived.manifest.provider.displayName)\n"
            output += "Archived: \(formatRelativeDate(archived.manifest.archivedAt, now: now))\n"
            output += "Size: \(formatSize(archived.fileSize))\n"
            output += "Original path: \(archived.manifest.originalPath)\n"
            output += "Archive path: \(archived.manifest.archivePath)\n\n"
        }

        output += "This will permanently remove this archived copy.\n"
        output += "It will not touch the original Codex/Claude directories.\n"
        output += "Continue? type purge: "
        return output
    }

    public static func renderRestoreResult(restoredCount: Int, skippedTitles: [String]) -> String {
        var lines: [String] = []
        if restoredCount == 1 {
            lines.append("Restored 1 archived copy.")
        } else {
            lines.append("Restored \(restoredCount) archived copies.")
        }

        if !skippedTitles.isEmpty {
            let joined = skippedTitles.joined(separator: ", ")
            lines.append("Skipped \(skippedTitles.count) due to existing destination: \(joined)")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public static func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        }

        let kb = Double(bytes) / 1024.0
        if kb < 1024 {
            return "\(Int(kb.rounded())) KB"
        }

        let mb = kb / 1024.0
        if mb < 1024 {
            return String(format: "%.1f MB", mb)
        }

        let gb = mb / 1024.0
        return String(format: "%.1f GB", gb)
    }

    public static func formatRelativeDate(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return "today"
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "yesterday"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }

        return formatter.string(from: date)
    }

    private static func paddedTitle(_ rawTitle: String) -> String {
        let title: String
        if rawTitle.count > 40 {
            title = "\(rawTitle.prefix(37))..."
        } else {
            title = rawTitle
        }

        let padCount = max(1, 42 - title.count)
        return title + String(repeating: " ", count: padCount)
    }

    private static func paddedProvider(_ rawProvider: String) -> String {
        let padCount = max(1, 9 - rawProvider.count)
        return rawProvider + String(repeating: " ", count: padCount)
    }
}

private func configuredURL(_ value: String?, fallback: URL, home: URL) -> URL {
    guard let value, !value.isEmpty else {
        return fallback.standardizedFileURL
    }

    if value == "~" {
        return home.standardizedFileURL
    }

    if value.hasPrefix("~/") {
        return home.appendingPathComponent(String(value.dropFirst(2)), isDirectory: true).standardizedFileURL
    }

    return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
}

private func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else {
        return false
    }

    let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
    return values?.isSymbolicLink != true
}

private func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
        return false
    }

    return values.isRegularFile == true && values.isSymbolicLink != true
}

private func isPath(_ url: URL, inside directory: URL) -> Bool {
    let path = url.standardizedFileURL.path
    let directoryPath = directory.standardizedFileURL.path
    return path == directoryPath || path.hasPrefix(directoryPath + "/")
}

private func sha256Hex(for url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
        try? handle.close()
    }

    var hasher = SHA256()
    while true {
        let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
        if data.isEmpty {
            break
        }
        hasher.update(data: data)
    }

    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func manifestEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private func manifestDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

private func isoFormatter() -> ISO8601DateFormatter {
    ISO8601DateFormatter()
}
