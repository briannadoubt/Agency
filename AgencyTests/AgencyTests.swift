//
//  AgencyTests.swift
//  AgencyTests
//
//  Created by Brianna Zamora on 11/21/25.
//

import Foundation
import Testing
@testable import Agency

struct AgencyTests {

    @MainActor
    @Test func watcherRefreshesWhenNewPhaseAppears() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let projectURL = tempRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let initialPhaseURL = projectURL.appendingPathComponent("phase-0-seed", isDirectory: true)

        try makePhaseDirectories(at: initialPhaseURL, fileManager: fileManager)

        let seedCardURL = initialPhaseURL.appendingPathComponent("backlog/0.1-seed.md")
        try cardContents(code: "0.1", slug: "seed").write(to: seedCardURL, atomically: true, encoding: .utf8)

        let watcher = ProjectScannerWatcher(scanner: ProjectScanner())
        var iterator = watcher.watch(rootURL: tempRoot, debounce: .milliseconds(50)).makeAsyncIterator()

        let firstResult = await iterator.next()
        #expect(firstResult != nil)

        if case .success(let initialSnapshots)? = firstResult {
            #expect(initialSnapshots.count == 1)
            #expect(initialSnapshots.first?.phase.number == 0)
        }

        let newPhaseURL = projectURL.appendingPathComponent("phase-1-fresh", isDirectory: true)
        try makePhaseDirectories(at: newPhaseURL, fileManager: fileManager)

        // Allow the watcher to attach to the new phase directories before writing a card.
        try await Task.sleep(for: .milliseconds(150))

        let newCardURL = newPhaseURL.appendingPathComponent("backlog/1.1-fresh.md")
        try cardContents(code: "1.1", slug: "fresh").write(to: newCardURL, atomically: true, encoding: .utf8)

        var sawNewPhase = false
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))

        while ContinuousClock().now < deadline, !sawNewPhase {
            guard let update = await iterator.next() else { break }

            if case .success(let snapshots) = update {
                sawNewPhase = snapshots.contains { $0.phase.number == 1 }
            }
        }

        #expect(sawNewPhase)
    }

    @MainActor
    private func makePhaseDirectories(at url: URL, fileManager: FileManager) throws {
        for status in CardStatus.allCases {
            let statusURL = url.appendingPathComponent(status.folderName, isDirectory: true)
            try fileManager.createDirectory(at: statusURL, withIntermediateDirectories: true)
        }
    }

    private func cardContents(code: String, slug: String) -> String {
        "---\nowner: test\n---\nSummary:\n- Task \(code)-\(slug)\n"
    }
}
