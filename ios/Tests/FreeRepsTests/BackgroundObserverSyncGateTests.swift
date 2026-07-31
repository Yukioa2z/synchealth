import XCTest
@testable import FreeReps

final class BackgroundObserverSyncGateTests: XCTestCase {
    private static let snapshotKey = "com.freereps.syncSnapshot"

    /// A locked device makes HealthKit reads fail per type. Those passes used to be reported as
    /// successful, which cleared the pending observer intent and advanced the sync cursor, so the
    /// samples were skipped permanently. The result must instead be retried.
    func testDeferredWhileLockedResultIsRetried() {
        XCTAssertTrue(BackgroundObserverSyncResult.deferredWhileLocked.shouldRetry)
        XCTAssertFalse(BackgroundObserverSyncResult.succeeded.shouldRetry)
        XCTAssertFalse(BackgroundObserverSyncResult.skippedNoBaseline.shouldRetry)
    }

    func testDisabledSyncDiscardsObserverWork() {
        XCTAssertEqual(
            BackgroundObserverSyncGate.decision(
                isEnabled: false,
                isProtectedDataAvailable: true,
                isAnotherSyncRunning: false
            ),
            .discard
        )
    }

    func testLockedDeviceDefersObserverWork() {
        XCTAssertEqual(
            BackgroundObserverSyncGate.decision(
                isEnabled: true,
                isProtectedDataAvailable: false,
                isAnotherSyncRunning: false
            ),
            .deferUntilLater
        )
    }

    func testConcurrentSyncDefersObserverWork() {
        XCTAssertEqual(
            BackgroundObserverSyncGate.decision(
                isEnabled: true,
                isProtectedDataAvailable: true,
                isAnotherSyncRunning: true
            ),
            .deferUntilLater
        )
    }

    func testAvailableIdleDeviceRunsObserverWork() {
        XCTAssertEqual(
            BackgroundObserverSyncGate.decision(
                isEnabled: true,
                isProtectedDataAvailable: true,
                isAnotherSyncRunning: false
            ),
            .run
        )
    }

    @MainActor
    func testObserverBootstrapRestoresBaselineBeforeEligibilityCheck() {
        let defaults = UserDefaults.standard
        let originalSnapshot = defaults.data(forKey: Self.snapshotKey)
        defer {
            if let originalSnapshot {
                defaults.set(originalSnapshot, forKey: Self.snapshotKey)
            } else {
                defaults.removeObject(forKey: Self.snapshotKey)
            }
        }

        let expectedLastSyncDate = Date(timeIntervalSinceReferenceDate: 123_456)
        let snapshot = PersistedSnapshot(
            lastSyncDate: expectedLastSyncDate,
            lastAcknowledgementDate: nil,
            categories: [],
            totalRecords: 42,
            hasCompletedFullSync: true,
            backfillCursors: nil,
            backfillAnchorDate: nil,
            pendingQueueCount: 0,
            lastDeliveryError: nil
        )
        defaults.set(try! JSONEncoder().encode(snapshot), forKey: Self.snapshotKey)

        let queueDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BackgroundObserverSyncGateTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: queueDirectory) }

        let context = BackgroundObserverSyncBootstrap.makeContext(
            uploadQueue: UploadQueueService(directoryURL: queueDirectory)
        )

        XCTAssertTrue(context.state.hasCompletedFullSync)
        XCTAssertEqual(context.state.lastSyncDate, expectedLastSyncDate)
        XCTAssertEqual(context.state.totalRecords, 42)
    }
}
