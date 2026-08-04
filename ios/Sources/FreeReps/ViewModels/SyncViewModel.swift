import Combine
import Foundation
import HealthKit
import SwiftUI

enum SyncSummaryStatus {
    case syncing
    case healthy
    case needsBaseline
    case waitingToSend
    case needsAttention
    case notSynced
}

@MainActor
final class SyncViewModel: ObservableObject {

    private(set) var syncState: SyncState
    private let syncService: SyncService
    private var cancellables = Set<AnyCancellable>()
    private var syncTask: Task<Void, Never>?
    private let isDesignPreview: Bool

    @Published var prerequisiteIssues: [SyncPrerequisiteIssue] = []
    @Published var showPrerequisiteAlert = false
    @Published var isRefreshingStatus = false

    init(isDesignPreview: Bool = false) {
        self.isDesignPreview = isDesignPreview
        let state = SyncState()
        self.syncState = state
        self.syncService = SyncService(syncState: state)
        // Forward SyncState changes so SwiftUI views subscribed to this
        // view model re-render whenever any SyncState @Published property changes.
        state.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        #if DEBUG
        if isDesignPreview {
            applyDesignPreviewState()
        }
        #endif
    }

    var categories: [CategorySyncState] { syncState.categories }
    var isFullSyncRunning: Bool { syncState.isFullSyncRunning }
    var isAnySyncRunning: Bool { syncState.isAnySyncRunning }
    var sessionAcknowledgedPoints: Int { syncState.sessionAcknowledgedPoints }
    var lifetimeAcknowledgedPoints: Int { syncState.lifetimeAcknowledgedPoints }
    var lastSyncDate: Date? { syncState.lastSyncDate }
    var lastAcknowledgementDate: Date? { syncState.lastAcknowledgementDate }
    var lastRunDuration: TimeInterval? { syncState.lastRunDuration }
    var receiverStatus: ReceiverStatus? { syncState.receiverStatus }
    var receiverStatusError: String? { syncState.receiverStatusError }
    var pendingQueueCount: Int { syncState.pendingQueueCount }
    var lastDeliveryError: String? { syncState.lastDeliveryError }
    var overallProgress: Double { syncState.overallProgress }
    var currentOperation: String { syncState.currentOperation }
    var errorMessage: String? { syncState.errorMessage }
    var hasCompletedFullSync: Bool { syncState.hasCompletedFullSync }
    var hasIncompleteBaseline: Bool {
        syncState.backfillAnchorDate != nil
            && !syncState.hasCompletedFullSync
            && syncState.lastSyncDate == nil
    }

    var completedStreamCount: Int {
        categories.filter { $0.status == .completed }.count
    }

    var totalStreamCount: Int {
        categories.count
    }

    var lastStatusDate: Date? {
        [lastAcknowledgementDate, receiverStatus?.lastReceivedDate]
            .compactMap { $0 }
            .max()
    }

    var lastSyncRelativeLabel: String {
        guard let date = lastStatusDate else { return "not yet" }
        if abs(date.timeIntervalSinceNow) < 60 {
            return "just now"
        }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .full
        return rel.localizedString(for: date, relativeTo: Date())
    }

    var summaryStatus: SyncSummaryStatus {
        if isAnySyncRunning {
            return .syncing
        }
        if lastDeliveryError != nil || errorMessage != nil || receiverStatusError != nil {
            return .needsAttention
        }
        if pendingQueueCount > 0 {
            return .waitingToSend
        }
        if !hasCompletedFullSync {
            return .needsBaseline
        }
        let hasFailedStream = categories.contains {
            if case .failed = $0.status { return true }
            return false
        }
        if hasFailedStream || categories.contains(where: { $0.daysBehind != nil }) {
            return .needsAttention
        }
        return lastStatusDate == nil ? .notSynced : .healthy
    }

    func checkPrerequisites() {
        guard !isDesignPreview else { return }
        let config = FreeRepsConfig.load()
        Task {
            let issues = await syncService.validatePrerequisites(config: config)
            self.prerequisiteIssues = issues
        }
    }

    func startFullSync() {
        let config = FreeRepsConfig.load()
        // Fire off prerequisite validation without blocking the sync
        Task {
            let issues = await syncService.validatePrerequisites(config: config)
            self.prerequisiteIssues = issues
            if !issues.isEmpty {
                self.showPrerequisiteAlert = true
            }
        }
        let task = Task {
            await syncService.runFullSync(config: config)
            await syncService.refreshReceiverStatus(config: config)
            refreshLatestHealthKitDates()
        }
        syncTask = task
        syncService.taskForCancellation = task
    }

    func startIncrementalSync() {
        let config = FreeRepsConfig.load()
        let task = Task {
            if syncState.lastSyncDate == nil {
                await syncService.runFullSync(config: config)
            } else {
                await syncService.runIncrementalSync(config: config)
            }
            await syncService.refreshReceiverStatus(config: config)
            refreshLatestHealthKitDates()
        }
        syncTask = task
        syncService.taskForCancellation = task
    }

    func resumeBaselineIfNeeded() {
        guard hasIncompleteBaseline, !isAnySyncRunning else { return }
        startFullSync()
    }

    func cancelSync() {
        syncTask?.cancel()
        syncTask = nil
    }

    func startCategorySync(categoryID: String) {
        let config = FreeRepsConfig.load()
        syncTask = Task {
            await syncService.runSingleCategorySync(categoryID: categoryID, config: config)
            await syncService.refreshReceiverStatus(config: config)
            refreshLatestHealthKitDates()
        }
    }

    /// Re-syncs a list of categories sequentially (used by data validation repair).
    func repairCategories(categoryIDs: [String]) {
        let config = FreeRepsConfig.load()
        let task = Task {
            for catID in categoryIDs {
                await syncService.runSingleCategorySync(categoryID: catID, config: config)
            }
            await syncService.refreshReceiverStatus(config: config)
            refreshLatestHealthKitDates()
        }
        syncTask = task
        syncService.taskForCancellation = task
    }

    func resetCategory(categoryID: String) {
        guard !isAnySyncRunning else { return }
        // With FreeReps, server-side data management replaces client-side DB resets.
        // Reset local sync state so the next sync re-sends all data for this category.
        syncState.resetCategoryLocalState(categoryID)
    }

    func resetAllSyncState() {
        guard !isAnySyncRunning else { return }
        syncState.resetAllLocalState()
    }

    func refreshLatestHealthKitDates() {
        guard !isDesignPreview else { return }
        Task {
            for i in syncState.categories.indices {
                let date = await latestHKDate(for: syncState.categories[i].id)
                syncState.categories[i].latestHealthKitDate = date
            }
        }
    }

    private func latestHKDate(for catID: String) async -> Date? {
        if catID.hasPrefix("qty_") {
            guard let cat = HealthCategory.allCases.first(where: { "qty_\($0.rawValue)" == catID })
            else { return nil }
            let types = HealthDataTypes.allQuantityTypes.filter { $0.category == cat }
            return await withTaskGroup(of: Date?.self) { group in
                for td in types {
                    guard let hkType = td.hkType else { continue }
                    group.addTask { await HealthKitService.shared.latestSampleDate(for: hkType) }
                }
                var latest: Date? = nil
                for await date in group {
                    if let d = date, latest == nil || d > latest! { latest = d }
                }
                return latest
            }
        }
        switch catID {
        case "cat_category":
            return await withTaskGroup(of: Date?.self) { group in
                for td in HealthDataTypes.allCategoryTypes {
                    guard let hkType = td.hkType else { continue }
                    group.addTask { await HealthKitService.shared.latestSampleDate(for: hkType) }
                }
                var latest: Date? = nil
                for await date in group {
                    if let d = date, latest == nil || d > latest! { latest = d }
                }
                return latest
            }
        case "cat_workouts":
            return await HealthKitService.shared.latestSampleDate(for: .workoutType())
        case "cat_bp":
            guard let t = HKObjectType.correlationType(forIdentifier: .bloodPressure) else { return nil }
            return await HealthKitService.shared.latestSampleDate(for: t)
        case "cat_ecg":
            return await HealthKitService.shared.latestSampleDate(for: .electrocardiogramType())
        case "cat_audiogram":
            return await HealthKitService.shared.latestSampleDate(for: .audiogramSampleType())
        case "cat_workout_routes":
            return await HealthKitService.shared.latestSampleDate(for: HKSeriesType.workoutRoute())
        case "cat_vision":
            return await HealthKitService.shared.latestSampleDate(for: HKObjectType.visionPrescriptionType())
        case "cat_state_of_mind":
            if #available(iOS 18, *) {
                return await HealthKitService.shared.latestSampleDate(for: HKObjectType.stateOfMindType())
            }
            return nil
        case "cat_strength":
            return nil
        default:
            return nil
        }
    }

    func refreshStatus() {
        guard !isDesignPreview else { return }
        guard !isRefreshingStatus else { return }
        isRefreshingStatus = true
        let config = FreeRepsConfig.load()
        Task {
            await syncService.refreshQueueStatus()
            await syncService.refreshReceiverStatus(config: config)
            isRefreshingStatus = false
        }
    }

    #if DEBUG
    static func designPreview() -> SyncViewModel {
        SyncViewModel(isDesignPreview: true)
    }

    private func applyDesignPreviewState() {
        let now = Date()
        syncState.hasCompletedFullSync = true
        syncState.lastSyncDate = now
        syncState.lastAcknowledgementDate = now
        syncState.lastRunDuration = 1.3
        syncState.sessionAcknowledgedPoints = 0
        syncState.lifetimeAcknowledgedPoints = 5_589_597
        syncState.pendingQueueCount = 0
        syncState.receiverStatus = ReceiverStatus(
            indexedItems: 7_162_114,
            metricCount: 25,
            databaseBytes: 12_582_912,
            rawPayloads: 34,
            lastReceivedAt: now.timeIntervalSince1970
        )
        for index in syncState.categories.indices {
            syncState.categories[index].status = .completed
            syncState.categories[index].lastSyncDate = now
        }
        syncState.recalcOverall()
    }
    #endif
}
