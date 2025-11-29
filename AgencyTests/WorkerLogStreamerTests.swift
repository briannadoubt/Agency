import XCTest
@testable import Agency

final class WorkerLogStreamerTests: XCTestCase {
    @MainActor
    func testStreamCancelsWhenLogNeverAppears() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("worker.log")

        let streamer = WorkerLogStreamer()
        let stream = streamer.stream(logURL: missing)

        let task = Task { () -> Bool in
            do {
                for try await _ in stream { }
                return true
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        let completed = await task.value

        XCTAssertTrue(completed, "Stream should respect cancellation even when log file is absent")
    }
}
