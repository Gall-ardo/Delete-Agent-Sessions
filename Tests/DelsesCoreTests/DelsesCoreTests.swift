import Foundation
@testable import DelsesCore
import SQLite3
import Testing

@Suite("DelsesCore")
struct DelsesCoreTests {
    private let fileManager = FileManager.default
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func codexScansOnlyTempCodexHomeSessions() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let included = codexRoot.appendingPathComponent("sessions/session.jsonl")
        let outsideSessions = codexRoot.appendingPathComponent("history.json")
        let fallbackCodex = fixture.home.appendingPathComponent(".codex/sessions/ignored.jsonl")

        try writeSession(included, title: "included")
        try writeSession(outsideSessions, title: "outside")
        try writeSession(fallbackCodex, title: "fallback")

        let candidates = try SessionScanner(fileManager: fileManager).candidates(for: .codex, env: fixture.env)

        #expect(candidates.map(\.url.path) == [included.standardizedFileURL.path])
    }

    @Test func claudeScansOnlyTempClaudeProjects() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let claudeRoot = URL(fileURLWithPath: fixture.env["CLAUDE_CONFIG_DIR"]!, isDirectory: true)
        let included = claudeRoot.appendingPathComponent("projects/project/session.jsonl")
        let outsideProjects = claudeRoot.appendingPathComponent("session.jsonl")

        try writeSession(included, title: "included")
        try writeSession(outsideProjects, title: "outside")

        let candidates = try SessionScanner(fileManager: fileManager).candidates(for: .claude, env: fixture.env)

        #expect(candidates.map(\.url.path) == [included.standardizedFileURL.path])
    }

    @Test func firstPageShowsAtMostFifteenRecords() {
        let list = PagedList(items: makeCandidates(count: 20), pageSize: 15)

        #expect(list.visibleStart == 1)
        #expect(list.visibleEnd == 15)
        #expect(list.currentPageItems.count == 15)
    }

    @Test func nextAndPreviousPaginationWork() {
        var list = PagedList(items: makeCandidates(count: 20), pageSize: 15)

        let didMoveNext = list.nextPage()
        #expect(didMoveNext)
        #expect(list.visibleStart == 16)
        #expect(list.visibleEnd == 20)
        #expect(list.currentPageItems.count == 5)

        let didMovePrevious = list.previousPage()
        #expect(didMovePrevious)
        #expect(list.visibleStart == 1)
        let didMoveBeforeFirstPage = list.previousPage()
        #expect(!didMoveBeforeFirstPage)
    }

    @Test func wordFilterWorks() {
        var list = PagedList(
            items: [
                makeCandidate(title: "website update", index: 1),
                makeCandidate(title: "deleteThis", index: 2),
                makeCandidate(title: "old session", index: 3)
            ],
            pageSize: 15
        )

        list.setFilter("web")

        #expect(list.totalCount == 1)
        #expect(list.currentPageItems.first?.title == "website update")

        list.clearFilter()
        #expect(list.totalCount == 3)
    }

    @Test func numberSelectionChoosesVisibleRecord() {
        var list = PagedList(items: makeCandidates(count: 20), pageSize: 15)

        let didMoveNext = list.nextPage()
        #expect(didMoveNext)
        #expect(list.item(displayNumber: 16)?.title == "session-16")
        #expect(list.item(displayNumber: 1) == nil)
    }

    @Test func archiveDoesNotRunWithoutYesConfirmation() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let session = codexRoot.appendingPathComponent("sessions/session.jsonl")
        try writeSession(session, title: "keep")

        let io = TestIO(inputs: ["1", "no"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["codex"]) == 0)
        #expect(fileManager.fileExists(atPath: session.path))
        #expect(!fileManager.fileExists(atPath: DelsesPaths(home: fixture.home).trashRoot.path))
    }

    @Test func archiveMultipleSelectionWorksWithSpaces() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let first = codexRoot.appendingPathComponent("sessions/first.jsonl")
        let second = codexRoot.appendingPathComponent("sessions/second.jsonl")
        try writeSession(first, title: "first")
        try writeSession(second, title: "second")

        let io = TestIO(inputs: ["1 2", "yes"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["codex"]) == 0)
        #expect(!fileManager.fileExists(atPath: first.path))
        #expect(!fileManager.fileExists(atPath: second.path))
    }

    @Test func archiveMultipleSelectionWorksWithCommas() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let first = codexRoot.appendingPathComponent("sessions/first.jsonl")
        let second = codexRoot.appendingPathComponent("sessions/second.jsonl")
        try writeSession(first, title: "first")
        try writeSession(second, title: "second")

        let io = TestIO(inputs: ["1,2", "yes"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["codex"]) == 0)
        #expect(!fileManager.fileExists(atPath: first.path))
        #expect(!fileManager.fileExists(atPath: second.path))
    }

    @Test func yesMovesFileToDelsesTrash() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let session = codexRoot.appendingPathComponent("sessions/session.jsonl")
        try writeSession(session, title: "archive me")

        let io = TestIO(inputs: ["1", "yes"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["codex"]) == 0)
        #expect(!fileManager.fileExists(atPath: session.path))

        let trashRoot = DelsesPaths(home: fixture.home).trashRoot
        let archivedFiles = try fileManager.subpathsOfDirectory(atPath: trashRoot.path)
        #expect(archivedFiles.contains { $0.hasSuffix("session.jsonl") })
    }

    @Test func archiveWritesManifest() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let session = codexRoot.appendingPathComponent("sessions/session.jsonl")
        try writeSession(session, title: "manifest")

        let io = TestIO(inputs: ["1", "yes"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })
        #expect(app.run(arguments: ["codex"]) == 0)

        let manifestURLs = try fileManager.contentsOfDirectory(
            at: DelsesPaths(home: fixture.home).manifestsRoot,
            includingPropertiesForKeys: nil
        )
        #expect(manifestURLs.count == 1)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: try #require(manifestURLs.first))
        let manifest = try decoder.decode(ArchiveManifest.self, from: data)

        #expect(manifest.provider == .codex)
        #expect(manifest.originalPath == session.standardizedFileURL.path)
        #expect(manifest.archivePath.contains("/.delses/trash/"))
        #expect(manifest.sha256Before.count == 64)
        #expect(manifest.toolVersion == delsesToolVersion)
    }

    @Test func archiveManifestStoresDisplayedTitleAndPreview() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let session = fixture.home.appendingPathComponent("candidate.jsonl")
        try writePlainFile(session, contents: "<skills_instructions> ## Skills A ski...\n")
        let candidate = SessionCandidate(
            provider: .codex,
            url: session,
            title: "deleteThis",
            preview: "first real user prompt",
            modifiedAt: fixedNow,
            fileSize: 42
        )

        let service = ArchiveService(env: fixture.env, fileManager: fileManager)
        let manifest = try service.archive(candidate, now: fixedNow)

        #expect(manifest.title == "deleteThis")
        #expect(manifest.preview == "first real user prompt")
    }

    @Test func restoreMovesArchiveBackToOriginalPath() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let session = codexRoot.appendingPathComponent("sessions/session.jsonl")
        try writeSession(session, title: "restore me")

        _ = try archiveFirstCodexSession(env: fixture.env)
        #expect(!fileManager.fileExists(atPath: session.path))

        let io = TestIO(inputs: ["1", "yes"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["restore"]) == 0)
        #expect(fileManager.fileExists(atPath: session.path))
        #expect(try String(contentsOf: session).contains("restore me"))
    }

    @Test func restoreMultipleSelectionWorks() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let first = try archiveCodexSession(env: fixture.env, fileName: "first-restore.jsonl", title: "first restore", archivedAt: fixedNow.addingTimeInterval(20))
        let second = try archiveCodexSession(env: fixture.env, fileName: "second-restore.jsonl", title: "second restore", archivedAt: fixedNow.addingTimeInterval(10))

        let io = TestIO(inputs: ["1 2", "yes"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["restore"]) == 0)
        #expect(!fileManager.fileExists(atPath: first.archivePath))
        #expect(!fileManager.fileExists(atPath: second.archivePath))
        #expect(fileManager.fileExists(atPath: first.originalPath))
        #expect(fileManager.fileExists(atPath: second.originalPath))
    }

    @Test func restoreInvalidMixedInputDoesNotProcessAnything() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let archived = try archiveCodexSession(env: fixture.env, fileName: "invalid-restore.jsonl", title: "invalid restore", archivedAt: fixedNow)

        let io = TestIO(inputs: ["1 x", "q"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["restore"]) == 0)
        #expect(fileManager.fileExists(atPath: archived.archivePath))
        #expect(!fileManager.fileExists(atPath: archived.originalPath))
        #expect(io.output.contains("Invalid input."))
    }

    @Test func restoreDuplicateSelectionRestoresOnlyOnce() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let archived = try archiveCodexSession(env: fixture.env, fileName: "duplicate-restore.jsonl", title: "duplicate restore", archivedAt: fixedNow)

        let io = TestIO(inputs: ["1, 1", "yes"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["restore"]) == 0)
        #expect(!fileManager.fileExists(atPath: archived.archivePath))
        #expect(fileManager.fileExists(atPath: archived.originalPath))
        #expect(io.output.contains("Restored 1 archived copy."))
    }

    @Test func restoreSkipsOverwriteConflictsAndContinues() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let first = try archiveCodexSession(env: fixture.env, fileName: "safe-restore.jsonl", title: "safe restore", archivedAt: fixedNow.addingTimeInterval(20))
        let second = try archiveCodexSession(env: fixture.env, fileName: "conflict-restore.jsonl", title: "conflict restore", archivedAt: fixedNow.addingTimeInterval(10))
        try writePlainFile(URL(fileURLWithPath: second.originalPath), contents: "existing file")

        let io = TestIO(inputs: ["1,2", "yes"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["restore"]) == 0)
        #expect(fileManager.fileExists(atPath: first.originalPath))
        #expect(fileManager.fileExists(atPath: second.archivePath))
        #expect(try String(contentsOfFile: second.originalPath) == "existing file")
        #expect(io.output.contains("Restored 1 archived copy."))
        #expect(io.output.contains("Skipped 1 due to existing destination: conflict restore"))
    }

    @Test func restoreDoesNotOverwriteExistingFile() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let session = codexRoot.appendingPathComponent("sessions/session.jsonl")
        try writeSession(session, title: "original")

        let manifest = try archiveFirstCodexSession(env: fixture.env)
        try writeSession(session, title: "replacement")

        let io = TestIO(inputs: ["1", "yes"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["restore"]) == 0)
        #expect(try String(contentsOf: session).contains("replacement"))
        #expect(fileManager.fileExists(atPath: manifest.archivePath))
        #expect(io.output.contains("Restored 0 archived copies."))
        #expect(io.output.contains("Skipped 1 due to existing destination: untitled session"))
    }

    @Test func symlinkIsNotCandidate() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let sessions = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        let target = fixture.home.appendingPathComponent("outside.jsonl")
        let symlink = sessions.appendingPathComponent("linked.jsonl")

        try writeSession(target, title: "target")
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: target)

        let candidates = try SessionScanner(fileManager: fileManager).candidates(for: .codex, env: fixture.env)

        #expect(candidates.isEmpty)
    }

    @Test func historyIndexAndDatabaseFilesAreNotChanged() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let session = codexRoot.appendingPathComponent("sessions/session.jsonl")
        let history = codexRoot.appendingPathComponent("history.json")
        let index = codexRoot.appendingPathComponent("index.json")
        let database = codexRoot.appendingPathComponent("database.sqlite")

        try writeSession(session, title: "archive")
        try writePlainFile(history, contents: "history")
        try writePlainFile(index, contents: "index")
        try writePlainFile(database, contents: "database")

        let io = TestIO(inputs: ["1", "yes"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })
        #expect(app.run(arguments: ["codex"]) == 0)

        #expect(try String(contentsOf: history) == "history")
        #expect(try String(contentsOf: index) == "index")
        #expect(try String(contentsOf: database) == "database")
    }

    @Test func injectedTempHomeAndConfigRootsAreUsed() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let injectedHome = fixture.home.appendingPathComponent("injected-home", isDirectory: true)
        let codexRoot = fixture.home.appendingPathComponent("custom-codex", isDirectory: true)
        let env = [
            "HOME": injectedHome.path,
            "CODEX_HOME": codexRoot.path,
            "CLAUDE_CONFIG_DIR": fixture.home.appendingPathComponent("custom-claude").path
        ]

        let selected = codexRoot.appendingPathComponent("sessions/selected.jsonl")
        let ignoredHomeDefault = injectedHome.appendingPathComponent(".codex/sessions/ignored.jsonl")
        try writeSession(selected, title: "selected")
        try writeSession(ignoredHomeDefault, title: "ignored")

        let candidates = try SessionScanner(fileManager: fileManager).candidates(for: .codex, env: env)

        #expect(DelsesPaths.homeURL(env: env) == injectedHome.standardizedFileURL)
        #expect(candidates.map(\.url.path) == [selected.standardizedFileURL.path])
    }

    @Test func codexIndexTitleBeatsUserPrompt() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let session = codexRoot.appendingPathComponent("sessions/session-a.jsonl")
        try writeCodexSession(session, id: "session-a", userMessages: ["first user prompt"])
        try writeSessionIndex(codexRoot.appendingPathComponent("session_index.jsonl"), id: "session-a", title: "Metadata Title")

        let candidate = try firstCodexCandidate(env: fixture.env)

        #expect(candidate.title == "Metadata Title")
        #expect(candidate.preview == "first user prompt")
    }

    @Test func codexRenamedTitleFromStateDatabaseIsListed() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let session = codexRoot.appendingPathComponent("sessions/renamed.jsonl")
        try writeCodexSession(session, id: "renamed-id", userMessages: ["original prompt"])
        try writeStateDatabase(
            codexRoot.appendingPathComponent("state_5.sqlite"),
            id: "renamed-id",
            rolloutPath: session.path,
            title: "resme",
            firstUserMessage: "original prompt"
        )

        let candidate = try firstCodexCandidate(env: fixture.env)

        #expect(candidate.title == "resme")
    }

    @Test func codexSessionMetadataTitleBeatsUserPrompt() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let session = codexRoot.appendingPathComponent("sessions/metadata.jsonl")
        try writeCodexSession(
            session,
            id: "metadata-id",
            metadataTitle: "Session Metadata Title",
            userMessages: ["first user prompt"]
        )

        let candidate = try firstCodexCandidate(env: fixture.env)

        #expect(candidate.title == "Session Metadata Title")
    }

    @Test func codexFallsBackToFirstRealUserPrompt() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let session = codexRoot.appendingPathComponent("sessions/fallback.jsonl")
        try writeCodexSession(session, id: "fallback-id", userMessages: ["implement title fallback"])

        let candidate = try firstCodexCandidate(env: fixture.env)

        #expect(candidate.title == "implement title fallback")
    }

    @Test func codexNeverUsesYouAreCodexAsTitle() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let session = codexRoot.appendingPathComponent("sessions/systemish.jsonl")
        try writeCodexSession(
            session,
            id: "systemish-id",
            userMessages: [
                "You are Codex, a coding agent based on GPT-5.",
                "Actual request title"
            ]
        )

        let candidate = try firstCodexCandidate(env: fixture.env)

        #expect(candidate.title == "Actual request title")
        #expect(candidate.title != "You are Codex, a coding agent based...")
    }

    @Test func codexSessionIDMatchesIndexTitle() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let session = codexRoot.appendingPathComponent("sessions/odd-file-name.jsonl")
        try writeCodexSession(session, id: "session-id-only", userMessages: ["file prompt"])
        try writeSessionIndex(codexRoot.appendingPathComponent("session_index.jsonl"), id: "session-id-only", title: "Matched by ID")

        let candidate = try firstCodexCandidate(env: fixture.env)

        #expect(candidate.title == "Matched by ID")
    }

    @Test func codexUnmatchedIndexUsesFileUserPrompt() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let session = codexRoot.appendingPathComponent("sessions/no-match.jsonl")
        try writeCodexSession(session, id: "real-id", userMessages: ["file prompt wins"])
        try writeSessionIndex(codexRoot.appendingPathComponent("session_index.jsonl"), id: "other-id", title: "Wrong title")

        let candidate = try firstCodexCandidate(env: fixture.env)

        #expect(candidate.title == "file prompt wins")
    }

    @Test func codexTitleExtractionDoesNotWriteIndexHistoryOrDatabaseFiles() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let session = codexRoot.appendingPathComponent("sessions/readonly.jsonl")
        let index = codexRoot.appendingPathComponent("session_index.jsonl")
        let history = codexRoot.appendingPathComponent("history.jsonl")
        let database = codexRoot.appendingPathComponent("state_5.sqlite")

        try writeCodexSession(session, id: "readonly-id", userMessages: ["readonly prompt"])
        try writeSessionIndex(index, id: "readonly-id", title: "Readonly Title")
        try writeJSONLines(history, [["session_id": "readonly-id", "ts": 1, "title": "History Title"]])
        try writeStateDatabase(database, id: "readonly-id", rolloutPath: session.path, title: "Readonly Title", firstUserMessage: "readonly prompt")

        let beforeIndex = try Data(contentsOf: index)
        let beforeHistory = try Data(contentsOf: history)
        let beforeDatabase = try Data(contentsOf: database)

        _ = try firstCodexCandidate(env: fixture.env)

        #expect(try Data(contentsOf: index) == beforeIndex)
        #expect(try Data(contentsOf: history) == beforeHistory)
        #expect(try Data(contentsOf: database) == beforeDatabase)
        #expect(!fileManager.fileExists(atPath: DelsesPaths(home: fixture.home).root.path))
    }

    @Test func purgeListsArchivedSessions() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        _ = try archiveCodexSession(env: fixture.env, fileName: "delete-this.jsonl", title: "deleteThis", archivedAt: fixedNow)
        _ = try archiveCodexSession(env: fixture.env, fileName: "trash.jsonl", title: "trash", archivedAt: fixedNow.addingTimeInterval(-10))

        let io = TestIO(inputs: ["q"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["purge"]) == 0)
        #expect(io.output.contains("Archived sessions"))
        #expect(io.output.contains("Showing 1-2 of 2"))
        #expect(io.output.contains("deleteThis"))
        #expect(io.output.contains("provider: Codex"))
    }

    @Test func purgeListUsesManifestTitle() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        _ = try archiveFileWithDisplayedTitle(
            env: fixture.env,
            home: fixture.home,
            archiveContents: "<skills_instructions> ## Skills A ski...\n",
            displayedTitle: "deleteThis"
        )

        let io = TestIO(inputs: ["q"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["purge"]) == 0)
        #expect(io.output.contains("deleteThis"))
        #expect(!io.output.contains("<skills_instructions>"))
        #expect(!io.output.contains("## Skills"))
    }

    @Test func restoreListUsesManifestTitle() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        _ = try archiveFileWithDisplayedTitle(
            env: fixture.env,
            home: fixture.home,
            archiveContents: "<skills_instructions> ## Skills A ski...\n",
            displayedTitle: "trash"
        )

        let io = TestIO(inputs: ["q"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["restore"]) == 0)
        #expect(io.output.contains("trash"))
        #expect(!io.output.contains("<skills_instructions>"))
        #expect(!io.output.contains("## Skills"))
    }

    @Test func archiveFileStartingWithSkillsInstructionsStillShowsManifestTitleInPurge() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        _ = try archiveFileWithDisplayedTitle(
            env: fixture.env,
            home: fixture.home,
            archiveContents: "<skills_instructions> ## Skills A ski...\n",
            displayedTitle: "deleteThis"
        )

        let io = TestIO(inputs: ["q"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["purge"]) == 0)
        #expect(io.output.contains("deleteThis"))
        #expect(!io.output.contains("<skills_instructions>"))
    }

    @Test func readmeContainsRequiredProjectText() throws {
        let readme = try String(contentsOfFile: "/Users/gallardo/Projects/delses/README.md")

        #expect(readme.contains("# Delete Agent Sessions"))
        #expect(readme.contains("A tiny macOS CLI to safely archive, restore, and purge local Codex and Claude Code sessions."))
        #expect(readme.contains("delses codex"))
        #expect(readme.contains("delses claude"))
        #expect(readme.contains("delses restore"))
        #expect(readme.contains("delses purge"))
        #expect(readme.contains("`n`, `p`, `/word`, `/clear`, `q`"))
        #expect(readme.contains("`1`, `1 2`, `1,2` selection"))
        #expect(readme.contains("archive/restore confirmation: `yes`"))
        #expect(readme.contains("purge confirmation: `purge`"))
        #expect(readme.contains("`macOS 13+`"))
        #expect(readme.contains("Apple Silicon and Intel Mac supported via local build"))
        #expect(readme.contains("No shell integration, no telemetry, no network, no background daemon."))
    }

    @Test func legacyManifestDoesNotUseSkillsInstructionsAsTitle() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let paths = DelsesPaths(home: fixture.home)
        let archiveURL = paths.trashRoot.appendingPathComponent("legacy-skills.jsonl")
        try writePlainFile(archiveURL, contents: "<skills_instructions> ## Skills A ski...\n")
        _ = try writeManualManifest(home: fixture.home, archiveURL: archiveURL)

        let io = TestIO(inputs: ["q"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["purge"]) == 0)
        #expect(io.output.contains("untitled session"))
        #expect(!io.output.contains("<skills_instructions>"))
        #expect(!io.output.contains("## Skills"))
    }

    @Test func legacyManifestFallsBackToOriginalPathMetadataTitleAndMigratesManifest() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let original = codexRoot.appendingPathComponent("sessions/original.jsonl")
        let archiveURL = DelsesPaths(home: fixture.home).trashRoot.appendingPathComponent("legacy.jsonl")
        try writePlainFile(archiveURL, contents: "<skills_instructions> ## Skills A ski...\n")
        try writeSessionIndex(codexRoot.appendingPathComponent("session_index.jsonl"), id: "original-id", title: "metadata title")
        try writeCodexSession(original, id: "original-id", userMessages: ["user prompt"])
        let manifestURL = try writeManualManifest(home: fixture.home, originalURL: original, archiveURL: archiveURL)

        let io = TestIO(inputs: ["q"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["purge"]) == 0)
        #expect(io.output.contains("metadata title"))
        #expect(try decodeManifest(at: manifestURL).title == "metadata title")
    }

    @Test func legacyManifestEmptyFallbackShowsUntitledSession() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let archiveURL = DelsesPaths(home: fixture.home).trashRoot.appendingPathComponent("empty.jsonl")
        try writePlainFile(archiveURL, contents: "\n")
        _ = try writeManualManifest(home: fixture.home, archiveURL: archiveURL)

        let io = TestIO(inputs: ["q"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["purge"]) == 0)
        #expect(io.output.contains("untitled session"))
    }

    @Test func purgeNumberSelectionMapsToCorrectArchivedRecord() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let newest = try archiveCodexSession(env: fixture.env, fileName: "newest.jsonl", title: "newest", archivedAt: fixedNow.addingTimeInterval(20))
        let older = try archiveCodexSession(env: fixture.env, fileName: "older.jsonl", title: "older", archivedAt: fixedNow.addingTimeInterval(10))

        let io = TestIO(inputs: ["2", "purge"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["purge"]) == 0)
        #expect(fileManager.fileExists(atPath: newest.archivePath))
        #expect(!fileManager.fileExists(atPath: older.archivePath))
    }

    @Test func purgeMultipleSelectionWorks() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let first = try archiveCodexSession(env: fixture.env, fileName: "first.jsonl", title: "first", archivedAt: fixedNow.addingTimeInterval(20))
        let second = try archiveCodexSession(env: fixture.env, fileName: "second.jsonl", title: "second", archivedAt: fixedNow.addingTimeInterval(10))

        let io = TestIO(inputs: ["1, 2", "purge"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["purge"]) == 0)
        #expect(!fileManager.fileExists(atPath: first.archivePath))
        #expect(!fileManager.fileExists(atPath: second.archivePath))
    }

    @Test func invalidMixedInputDoesNotProcessAnything() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let first = codexRoot.appendingPathComponent("sessions/first.jsonl")
        let second = codexRoot.appendingPathComponent("sessions/second.jsonl")
        try writeSession(first, title: "first")
        try writeSession(second, title: "second")

        let io = TestIO(inputs: ["1 x", "q"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["codex"]) == 0)
        #expect(fileManager.fileExists(atPath: first.path))
        #expect(fileManager.fileExists(atPath: second.path))
        #expect(io.output.contains("Invalid input."))
    }

    @Test func purgeDoesNothingWithoutPurgeConfirmation() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let manifest = try archiveCodexSession(env: fixture.env, fileName: "cancel.jsonl", title: "cancel", archivedAt: fixedNow)

        let io = TestIO(inputs: ["1", "delete"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["purge"]) == 0)
        #expect(fileManager.fileExists(atPath: manifest.archivePath))
        #expect(try decodedManifest(home: fixture.home).status == nil)
    }

    @Test func purgeDoesNotAcceptYesConfirmation() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let manifest = try archiveCodexSession(env: fixture.env, fileName: "yes.jsonl", title: "yes title", archivedAt: fixedNow)

        let io = TestIO(inputs: ["1", "yes"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["purge"]) == 0)
        #expect(fileManager.fileExists(atPath: manifest.archivePath))
        #expect(try decodedManifest(home: fixture.home).status == nil)
    }

    @Test func purgeDeletesOnlyArchivedFileUnderTrash() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexSentinel = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
            .appendingPathComponent("sessions/live.jsonl")
        let claudeSentinel = URL(fileURLWithPath: fixture.env["CLAUDE_CONFIG_DIR"]!, isDirectory: true)
            .appendingPathComponent("projects/live/session.jsonl")
        try writePlainFile(codexSentinel, contents: "codex live")
        try writePlainFile(claudeSentinel, contents: "claude live")

        let manifest = try archiveCodexSession(env: fixture.env, fileName: "purge.jsonl", title: "purge me", archivedAt: fixedNow)

        let io = TestIO(inputs: ["1", "purge"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["purge"]) == 0)
        #expect(!fileManager.fileExists(atPath: manifest.archivePath))
        #expect(try String(contentsOf: codexSentinel) == "codex live")
        #expect(try String(contentsOf: claudeSentinel) == "claude live")
    }

    @Test func purgeUpdatesManifestAsPurged() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        _ = try archiveCodexSession(env: fixture.env, fileName: "manifest.jsonl", title: "manifest purge", archivedAt: fixedNow)

        let io = TestIO(inputs: ["1", "purge"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })

        #expect(app.run(arguments: ["purge"]) == 0)

        let manifest = try decodedManifest(home: fixture.home)
        #expect(manifest.status == "purged")
        #expect(manifest.purgedAt == fixedNow)
    }

    @Test func purgedRecordDoesNotAppearInRestoreList() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        _ = try archiveCodexSession(env: fixture.env, fileName: "restore-hidden.jsonl", title: "restore hidden", archivedAt: fixedNow)

        let purgeIO = TestIO(inputs: ["1", "purge"])
        let purgeApp = DelsesApp(env: fixture.env, fileManager: fileManager, io: purgeIO, now: { fixedNow })
        #expect(purgeApp.run(arguments: ["purge"]) == 0)

        let restoreIO = TestIO(inputs: ["q"])
        let restoreApp = DelsesApp(env: fixture.env, fileManager: fileManager, io: restoreIO, now: { fixedNow })
        #expect(restoreApp.run(arguments: ["restore"]) == 0)
        #expect(restoreIO.output.contains("Showing 0-0 of 0"))
    }

    @Test func purgeRejectsArchivePathOutsideTrashRoot() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let paths = DelsesPaths(home: fixture.home)
        let outside = fixture.home.appendingPathComponent("outside-archive.jsonl")
        let manifestURL = try writeManualManifest(home: fixture.home, archiveURL: outside)
        try writePlainFile(outside, contents: "outside")

        let manifest = try decodeManifest(at: manifestURL)
        let archived = ArchivedSession(manifestURL: manifestURL, manifest: manifest, title: "outside")
        let service = ArchiveService(paths: paths, fileManager: fileManager)

        do {
            try service.purge(archived, now: fixedNow)
            throw TestFailure("purge should have rejected outside archive path")
        } catch DelsesError.archiveOutsideTrash {
            #expect(fileManager.fileExists(atPath: outside.path))
            #expect(try decodeManifest(at: manifestURL).status == nil)
        }
    }

    @Test func purgeRejectsSymlinkArchivePath() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let paths = DelsesPaths(home: fixture.home)
        let target = fixture.home.appendingPathComponent("outside-target.jsonl")
        let symlink = paths.trashRoot.appendingPathComponent("linked.jsonl")
        try writePlainFile(target, contents: "target")
        try fileManager.createDirectory(at: paths.trashRoot, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: target)
        let manifestURL = try writeManualManifest(home: fixture.home, archiveURL: symlink)

        let manifest = try decodeManifest(at: manifestURL)
        let archived = ArchivedSession(manifestURL: manifestURL, manifest: manifest, title: "linked")
        let service = ArchiveService(paths: paths, fileManager: fileManager)

        do {
            try service.purge(archived, now: fixedNow)
            throw TestFailure("purge should have rejected symlink archive path")
        } catch {
            #expect(fileManager.fileExists(atPath: symlink.path))
            #expect(fileManager.fileExists(atPath: target.path))
            #expect(try decodeManifest(at: manifestURL).status == nil)
        }
    }

    @Test func purgeRejectsDirectoryArchivePath() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let paths = DelsesPaths(home: fixture.home)
        let directory = paths.trashRoot.appendingPathComponent("directory-archive", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = try writeManualManifest(home: fixture.home, archiveURL: directory)

        let manifest = try decodeManifest(at: manifestURL)
        let archived = ArchivedSession(manifestURL: manifestURL, manifest: manifest, title: "directory")
        let service = ArchiveService(paths: paths, fileManager: fileManager)

        do {
            try service.purge(archived, now: fixedNow)
            throw TestFailure("purge should have rejected directory archive path")
        } catch DelsesError.unsafeArchive {
            #expect(fileManager.fileExists(atPath: directory.path))
            #expect(try decodeManifest(at: manifestURL).status == nil)
        }
    }

    @Test func purgeUsesTempHomeAndDoesNotTouchLiveSessionRoots() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.home) }

        let codexRoot = URL(fileURLWithPath: fixture.env["CODEX_HOME"]!, isDirectory: true)
        let claudeRoot = URL(fileURLWithPath: fixture.env["CLAUDE_CONFIG_DIR"]!, isDirectory: true)
        let codexHistory = codexRoot.appendingPathComponent("history.jsonl")
        let claudeConfig = fixture.home.appendingPathComponent(".claude.json")
        let claudeProject = claudeRoot.appendingPathComponent("projects/project/live.jsonl")
        try writePlainFile(codexHistory, contents: "codex history")
        try writePlainFile(claudeConfig, contents: "claude config")
        try writePlainFile(claudeProject, contents: "claude project")

        _ = try archiveCodexSession(env: fixture.env, fileName: "temp-home.jsonl", title: "temp home", archivedAt: fixedNow)

        let io = TestIO(inputs: ["1", "purge"])
        let app = DelsesApp(env: fixture.env, fileManager: fileManager, io: io, now: { fixedNow })
        #expect(app.run(arguments: ["purge"]) == 0)

        #expect(try String(contentsOf: codexHistory) == "codex history")
        #expect(try String(contentsOf: claudeConfig) == "claude config")
        #expect(try String(contentsOf: claudeProject) == "claude project")
    }

    private func makeFixture() throws -> (home: URL, env: [String: String]) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("delses-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)

        let env = [
            "HOME": home.path,
            "CODEX_HOME": home.appendingPathComponent("codex-home", isDirectory: true).path,
            "CLAUDE_CONFIG_DIR": home.appendingPathComponent("claude-home", isDirectory: true).path
        ]
        return (home, env)
    }

    private func cleanup(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }

    private func writeSession(_ url: URL, title: String, modifiedAt: Date? = nil) throws {
        let content = "{\"summary\":\"\(title)\"}\n"
        try writePlainFile(url, contents: content)
        if let modifiedAt {
            try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
    }

    private func writePlainFile(_ url: URL, contents: String) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
    }

    private func writeCodexSession(_ url: URL, id: String, metadataTitle: String? = nil, userMessages: [String]) throws {
        var objects: [[String: Any]] = [
            [
                "timestamp": "2026-06-12T00:00:00Z",
                "type": "session_meta",
                "payload": ["id": id]
            ]
        ]

        if let metadataTitle {
            objects.append(
                [
                    "timestamp": "2026-06-12T00:00:01Z",
                    "type": "session_meta",
                    "payload": [
                        "id": id,
                        "title": metadataTitle
                    ]
                ]
            )
        }

        for message in userMessages {
            objects.append(
                [
                    "timestamp": "2026-06-12T00:00:02Z",
                    "type": "message",
                    "payload": [
                        "type": "message",
                        "role": "user",
                        "content": [
                            [
                                "type": "input_text",
                                "text": message
                            ]
                        ]
                    ]
                ]
            )
        }

        try writeJSONLines(url, objects)
    }

    private func writeSessionIndex(_ url: URL, id: String, title: String) throws {
        try writeJSONLines(url, [["id": id, "thread_name": title, "updated_at": "2026-06-12T00:00:00Z"]])
    }

    private func writeJSONLines(_ url: URL, _ objects: [[String: Any]]) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try objects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(data: data, encoding: .utf8)!
        }.joined(separator: "\n") + "\n"
        try lines.data(using: .utf8)!.write(to: url)
    }

    private func writeStateDatabase(_ url: URL, id: String, rolloutPath: String, title: String, firstUserMessage: String) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var database: OpaquePointer?
        try checkSQLite(sqlite3_open(url.path, &database))
        defer {
            sqlite3_close(database)
        }

        try execSQL(
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT,
                title TEXT,
                first_user_message TEXT,
                preview TEXT
            );
            """,
            database: database
        )

        try execSQL(
            """
            INSERT INTO threads (id, rollout_path, title, first_user_message, preview)
            VALUES (\(sqlQuote(id)), \(sqlQuote(rolloutPath)), \(sqlQuote(title)), \(sqlQuote(firstUserMessage)), \(sqlQuote(firstUserMessage)));
            """,
            database: database
        )
    }

    private func execSQL(_ sql: String, database: OpaquePointer?) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if status != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "sqlite error \(status)"
            sqlite3_free(errorMessage)
            throw TestFailure(message)
        }
    }

    private func checkSQLite(_ status: Int32) throws {
        if status != SQLITE_OK {
            throw TestFailure("sqlite error \(status)")
        }
    }

    private func sqlQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func archiveCodexSession(env: [String: String], fileName: String, title: String, archivedAt: Date) throws -> ArchiveManifest {
        let codexRoot = URL(fileURLWithPath: env["CODEX_HOME"]!, isDirectory: true)
        let session = codexRoot.appendingPathComponent("sessions/\(fileName)")
        try writeCodexSession(session, id: UUID().uuidString.lowercased(), metadataTitle: title, userMessages: [title])
        try fileManager.setAttributes([.modificationDate: archivedAt], ofItemAtPath: session.path)

        let scanner = SessionScanner(fileManager: fileManager)
        let candidates = try scanner.candidates(for: .codex, env: env)
        let candidate = try #require(candidates.first { $0.url.path == session.standardizedFileURL.path })
        let service = ArchiveService(env: env, fileManager: fileManager)
        return try service.archive(candidate, now: archivedAt)
    }

    private func archiveFileWithDisplayedTitle(env: [String: String], home: URL, archiveContents: String, displayedTitle: String) throws -> ArchiveManifest {
        let source = home.appendingPathComponent("source-\(UUID().uuidString).jsonl")
        try writePlainFile(source, contents: archiveContents)
        let candidate = SessionCandidate(
            provider: .codex,
            url: source,
            title: displayedTitle,
            preview: "preview",
            modifiedAt: fixedNow,
            fileSize: Int64(archiveContents.utf8.count)
        )

        return try ArchiveService(env: env, fileManager: fileManager).archive(candidate, now: fixedNow)
    }

    private func decodedManifest(home: URL) throws -> ArchiveManifest {
        let manifestURLs = try fileManager.contentsOfDirectory(
            at: DelsesPaths(home: home).manifestsRoot,
            includingPropertiesForKeys: nil
        )
        return try decodeManifest(at: try #require(manifestURLs.first))
    }

    private func decodeManifest(at url: URL) throws -> ArchiveManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ArchiveManifest.self, from: Data(contentsOf: url))
    }

    private func writeManualManifest(home: URL, originalURL: URL? = nil, archiveURL: URL) throws -> URL {
        let paths = DelsesPaths(home: home)
        try fileManager.createDirectory(at: paths.manifestsRoot, withIntermediateDirectories: true)
        let manifestURL = paths.manifestsRoot.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        let manifest = ArchiveManifest(
            provider: .codex,
            originalPath: (originalURL ?? home.appendingPathComponent(".codex/sessions/original.jsonl")).path,
            archivePath: archiveURL.path,
            sha256Before: String(repeating: "0", count: 64),
            fileSize: 6,
            modifiedAt: fixedNow,
            archivedAt: fixedNow,
            toolVersion: delsesToolVersion
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: [.atomic])
        return manifestURL
    }

    private func makeCandidates(count: Int) -> [SessionCandidate] {
        (1...count).map { makeCandidate(title: "session-\($0)", index: $0) }
    }

    private func makeCandidate(title: String, index: Int) -> SessionCandidate {
        SessionCandidate(
            provider: .codex,
            url: URL(fileURLWithPath: "/tmp/session-\(index).jsonl"),
            title: title,
            modifiedAt: fixedNow.addingTimeInterval(TimeInterval(index)),
            fileSize: Int64(index)
        )
    }

    private func archiveFirstCodexSession(env: [String: String]) throws -> ArchiveManifest {
        let scanner = SessionScanner(fileManager: fileManager)
        let candidates = try scanner.candidates(for: .codex, env: env)
        let candidate = try #require(candidates.first)
        let service = ArchiveService(env: env, fileManager: fileManager)
        return try service.archive(candidate, now: fixedNow)
    }

    private func firstCodexCandidate(env: [String: String]) throws -> SessionCandidate {
        let scanner = SessionScanner(fileManager: fileManager)
        let candidates = try scanner.candidates(for: .codex, env: env)
        return try #require(candidates.first)
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private final class TestIO: DelsesIO {
    private var inputs: [String]
    private(set) var output = ""

    init(inputs: [String]) {
        self.inputs = inputs
    }

    func write(_ value: String) {
        output += value
    }

    func readLine() -> String? {
        if inputs.isEmpty {
            return nil
        }

        return inputs.removeFirst()
    }
}
