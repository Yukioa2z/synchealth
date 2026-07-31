import Foundation
import BackgroundTasks
import HealthKit
import UIKit
import UserNotifications

/// A bounded, value-free journal for diagnosing HealthKit background delivery on a device.
///
/// Entries intentionally contain only event names, HealthKit type identifiers, timestamps,
/// protected-data availability, gate decisions, and coarse outcomes. Health samples, payloads,
/// tokens, headers, endpoints, and error descriptions must never be written here.
final class BackgroundSyncDiagnosticJournal: @unchecked Sendable {
    static let shared = BackgroundSyncDiagnosticJournal()

    private struct Entry: Codable {
        let timestamp: Date
        let event: String
        let typeIdentifier: String?
        let protectedDataAvailable: Bool?
        let gateDecision: String?
        let outcome: String?
    }

    private let directoryURL: URL
    private let fileManager: FileManager
    private let maximumFileSize: Int
    private let lock = NSLock()

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        maximumFileSize: Int = 96 * 1024
    ) {
        self.fileManager = fileManager
        self.maximumFileSize = maximumFileSize
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.directoryURL = applicationSupport
                .appendingPathComponent("BackgroundSyncDiagnostics", isDirectory: true)
        }
    }

    func record(
        _ event: String,
        typeIdentifier: String? = nil,
        protectedDataAvailable: Bool? = nil,
        gateDecision: String? = nil,
        outcome: String? = nil
    ) {
        let entry = Entry(
            timestamp: Date(),
            event: event,
            typeIdentifier: typeIdentifier,
            protectedDataAvailable: protectedDataAvailable,
            gateDecision: gateDecision,
            outcome: outcome
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)

        lock.lock()
        defer { lock.unlock() }

        do {
            try ensureDirectory()
            let currentURL = directoryURL.appendingPathComponent("events.jsonl")
            let previousURL = directoryURL.appendingPathComponent("events.previous.jsonl")
            let currentSize = (
                try? currentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            ) ?? 0

            if currentSize + data.count > maximumFileSize {
                if fileManager.fileExists(atPath: previousURL.path) {
                    try fileManager.removeItem(at: previousURL)
                }
                if fileManager.fileExists(atPath: currentURL.path) {
                    try fileManager.moveItem(at: currentURL, to: previousURL)
                }
            }

            if !fileManager.fileExists(atPath: currentURL.path) {
                fileManager.createFile(atPath: currentURL.path, contents: nil)
                try? fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: currentURL.path
                )
            }

            let handle = try FileHandle(forWritingTo: currentURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            // Diagnostics must never prevent or alter a HealthKit sync.
        }
    }

    private func ensureDirectory() throws {
        guard !fileManager.fileExists(atPath: directoryURL.path) else { return }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ]
        )
    }
}

enum BackgroundObserverSyncDecision: Equatable {
    case discard
    case deferUntilLater
    case run

    var diagnosticLabel: String {
        switch self {
        case .discard: return "discard"
        case .deferUntilLater: return "defer"
        case .run: return "run"
        }
    }
}

struct BackgroundObserverSyncGate {
    static func decision(
        isEnabled: Bool,
        isProtectedDataAvailable: Bool,
        isAnotherSyncRunning: Bool
    ) -> BackgroundObserverSyncDecision {
        guard isEnabled else { return .discard }
        guard isProtectedDataAvailable, !isAnotherSyncRunning else {
            return .deferUntilLater
        }
        return .run
    }
}

enum BackgroundObserverSyncResult: String {
    case succeeded
    case skippedNoBaseline = "skipped_no_baseline"
    case deferredWhileLocked = "deferred_while_locked"
    case cancelled
    case failed

    var shouldRetry: Bool {
        self == .cancelled || self == .failed || self == .deferredWhileLocked
    }
}

struct BackgroundObserverSyncContext {
    let state: SyncState
    let service: SyncService
}

@MainActor
enum BackgroundObserverSyncBootstrap {
    /// SyncService restores the persisted snapshot during initialization. Keep creation of the
    /// service and the subsequent baseline gate together so the gate never reads a blank state.
    static func makeContext(
        uploadQueue: UploadQueueService = .shared
    ) -> BackgroundObserverSyncContext {
        let state = SyncState()
        let service = SyncService(syncState: state, uploadQueue: uploadQueue)
        return BackgroundObserverSyncContext(state: state, service: service)
    }
}

/// Manages HKObserverQuery-based background delivery for continuous HealthKit → SyncHealth sync.
///
/// Other health apps use this pattern: register observer queries for each data type at launch,
/// enable background delivery, and HealthKit wakes the app when new data is written. Unlike
/// BGProcessingTask (which runs when the device is idle/locked), observer callbacks fire
/// close to when data is recorded — the device is typically unlocked, so HealthKit data is accessible.
@MainActor
final class BackgroundSyncManager {

    static let shared = BackgroundSyncManager()
    private static let pendingObserverSyncKey = "pendingHealthKitObserverSync"
    private static let restoredObserverIdentifier = "healthsync.pending-observer"

    private let healthStore = HealthKitService.shared.store
    private var observerQueries: [HKObserverQuery] = []
    private var pendingTypes: Set<String> = []
    private var debounceTask: Task<Void, Never>?
    private var observerSyncTask: Task<Void, Never>?
    private var isSyncing = false
    private var activeTypes: Set<String> = []
    private var observerBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var protectedDataObserver: NSObjectProtocol?
    private let diagnosticJournal = BackgroundSyncDiagnosticJournal.shared

    private init() {
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.retryPendingUpdatesAfterUnlock()
            }
        }
    }

    deinit {
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
        }
    }

    // MARK: - Public API

    /// Call once from AppDelegate.didFinishLaunchingWithOptions to start monitoring HealthKit.
    func startObserving() {
        if observerQueries.isEmpty {
            setupObserverQueries()
            enableBackgroundDelivery()
        }
        restorePendingObserverSyncIfNeeded()
    }

    /// HealthKit may wake the app while protected data is unavailable. Keep the observer
    /// identifiers pending and retry them once iOS reports that protected data can be read.
    func retryPendingUpdatesAfterUnlock() {
        restorePendingObserverSyncIfNeeded()
        guard !pendingTypes.isEmpty else { return }
        debounceAndSync()
    }

    private func restorePendingObserverSyncIfNeeded() {
        guard UserDefaults.standard.bool(forKey: Self.pendingObserverSyncKey) else { return }
        pendingTypes.insert(Self.restoredObserverIdentifier)
        debounceAndSync()
    }

    // MARK: - Observer Queries

    private func setupObserverQueries() {
        let readTypes = HealthDataTypes.allReadTypes

        for type in readTypes {
            guard let sampleType = type as? HKSampleType else { continue }

            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) {
                [weak self] _, completionHandler, error in
                Task { @MainActor in
                    self?.handleObserverUpdate(sampleType: sampleType, error: error)
                    // MUST always call completionHandler or iOS thinks the query is still running
                    completionHandler()
                }
            }

            healthStore.execute(query)
            observerQueries.append(query)
            diagnosticJournal.record(
                "observer_registered",
                typeIdentifier: sampleType.identifier,
                protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                outcome: "success"
            )
        }
    }

    private func enableBackgroundDelivery() {
        let readTypes = HealthDataTypes.allReadTypes

        for type in readTypes {
            guard let sampleType = type as? HKSampleType else { continue }
            let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable

            healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { success, error in
                self.diagnosticJournal.record(
                    "background_delivery_enabled",
                    typeIdentifier: sampleType.identifier,
                    protectedDataAvailable: protectedDataAvailable,
                    outcome: success && error == nil ? "success" : "failed"
                )
                if let error = error {
                    print("[BackgroundSyncManager] enableBackgroundDelivery failed for \(sampleType.identifier): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Observer Callback Handling

    private func handleObserverUpdate(sampleType: HKSampleType, error: Error?) {
        if let error = error {
            diagnosticJournal.record(
                "observer_callback",
                typeIdentifier: sampleType.identifier,
                protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                outcome: "failed"
            )
            postFailureNotification("HealthKit observer error: \(error.localizedDescription)")
            return
        }

        diagnosticJournal.record(
            "observer_callback",
            typeIdentifier: sampleType.identifier,
            protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
            outcome: "success"
        )
        pendingTypes.insert(sampleType.identifier)
        // Persist intent before acknowledging the HealthKit observer callback. If iOS
        // terminates the process while the phone is locked, the next launch still retries.
        UserDefaults.standard.set(true, forKey: Self.pendingObserverSyncKey)
        debounceAndSync()
    }

    /// Debounce rapid-fire observer callbacks. Multiple types can change at once
    /// (e.g. workout saves distance, energy, heart rate simultaneously). Wait 5s
    /// for all updates to arrive, then trigger a single incremental sync.
    private func debounceAndSync() {
        beginObserverBackgroundTimeIfNeeded()
        // Do not cancel a sync already in flight. New identifiers stay pending and receive
        // one follow-up pass after the active rolling-window sync completes.
        guard !isSyncing else { return }
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            guard !Task.isCancelled else { return }

            let types = pendingTypes
            guard !types.isEmpty else {
                endObserverBackgroundTime()
                return
            }

            let decision = BackgroundObserverSyncGate.decision(
                isEnabled: UserDefaults.standard.bool(forKey: "backgroundSyncEnabled"),
                isProtectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                isAnotherSyncRunning: SyncService.isSyncRunning
            )
            for type in types {
                diagnosticJournal.record(
                    "gate_decision",
                    typeIdentifier: type,
                    protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                    gateDecision: decision.diagnosticLabel
                )
            }

            if decision == .discard {
                pendingTypes.subtract(types)
                UserDefaults.standard.set(false, forKey: Self.pendingObserverSyncKey)
                endObserverBackgroundTime()
                return
            }

            if decision == .deferUntilLater {
                scheduleBackgroundRetry()
                endObserverBackgroundTime()
                return
            }

            // Only consume the triggering identifiers after the sync is eligible to start.
            // Observer callbacks received during the sync remain pending for a follow-up pass.
            pendingTypes.subtract(types)
            activeTypes.formUnion(types)
            for type in types {
                diagnosticJournal.record(
                    "sync_started",
                    typeIdentifier: type,
                    protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable
                )
            }
            let result = await triggerIncrementalSync()
            for type in types {
                diagnosticJournal.record(
                    "sync_finished",
                    typeIdentifier: type,
                    protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                    outcome: result.rawValue
                )
            }
            activeTypes.subtract(types)
            if result.shouldRetry {
                pendingTypes.formUnion(types)
                scheduleBackgroundRetry()
                endObserverBackgroundTime()
                return
            }

            if pendingTypes.isEmpty {
                UserDefaults.standard.set(false, forKey: Self.pendingObserverSyncKey)
                endObserverBackgroundTime()
            } else {
                debounceAndSync()
            }
        }
    }

    private func scheduleBackgroundRetry() {
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: "com.example.synchealth.sync"
        )
        let request = BGProcessingTaskRequest(identifier: "com.example.synchealth.sync")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func beginObserverBackgroundTimeIfNeeded() {
        guard observerBackgroundTaskID == .invalid else { return }
        observerBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "observer-debounce-sync"
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                for type in self.activeTypes.union(self.pendingTypes) {
                    self.diagnosticJournal.record(
                        "sync_cancelled",
                        typeIdentifier: type,
                        protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                        outcome: "background_time_expired"
                    )
                }
                self.debounceTask?.cancel()
                self.observerSyncTask?.cancel()
                self.endObserverBackgroundTime()
            }
        }
    }

    private func endObserverBackgroundTime() {
        guard observerBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(observerBackgroundTaskID)
        observerBackgroundTaskID = .invalid
    }

    // MARK: - Trigger Sync

    private func triggerIncrementalSync() async -> BackgroundObserverSyncResult {
        guard UserDefaults.standard.bool(forKey: "backgroundSyncEnabled") else {
            return .succeeded
        }
        guard !isSyncing, !SyncService.isSyncRunning else { return .failed }
        isSyncing = true
        defer { isSyncing = false }

        let config = FreeRepsConfig.load()

        // Background time starts before the debounce delay so iOS cannot suspend the app
        // between the observer callback and this sync.

        let context = BackgroundObserverSyncBootstrap.makeContext()
        let state = context.state
        let service = context.service
        guard state.hasCompletedFullSync, state.lastSyncDate != nil else {
            return .skippedNoBaseline
        }
        service.isBackgroundSync = true
        let task = Task { await service.runIncrementalSync(config: config) }
        observerSyncTask = task
        await task.value
        observerSyncTask = nil

        // Post notification on failure. Cancellation (expiry) sets no errorMessage,
        // so this only fires on genuine sync errors.
        if let error = state.errorMessage {
            postFailureNotification(error)
        }
        if state.currentOperation == "Sync cancelled" {
            return .cancelled
        }
        if state.errorMessage != nil {
            return .failed
        }
        if state.currentOperation == SyncService.deferredWhileLockedOperation {
            return .deferredWhileLocked
        }
        return state.currentOperation.hasPrefix("Incremental sync done")
            ? .succeeded
            : .failed
    }

    // MARK: - Failure Notifications

    func postFailureNotification(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "FreeReps Sync Failed"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "sync-failure",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[BackgroundSyncManager] Failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    /// Request notification permission. Call once at app launch.
    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error = error {
                print("[BackgroundSyncManager] Notification permission error: \(error.localizedDescription)")
            }
        }
    }
}
