import SwiftUI
import UIKit

struct SyncDashboardView: View {
    @ObservedObject var vm: SyncViewModel
    @State private var navigateToHealthPermissions = false
    @AppStorage("keepScreenOnDuringSync") private var keepScreenOnDuringSync = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        syncSummaryCard
                        statisticsCards
                        syncActionsCard
                    }
                    .padding(.vertical, 2)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                // No-full-sync warning banner
                if !vm.hasCompletedFullSync && !vm.isAnySyncRunning {
                    Section {
                        noticeBanner(
                            icon: "exclamationmark.triangle.fill",
                            color: .yellow,
                            title: "No Complete Baseline",
                            message: "A full sync has never completed. Historical data may be missing from SyncHealth. Run Full Sync to establish a complete baseline."
                        )
                    }
                }

                // Full sync screen-on reminder
                if vm.isFullSyncRunning {
                    Section {
                        noticeBanner(
                            icon: "lock.open.display",
                            color: .blue,
                            title: "Keep Screen On",
                            message: "Apple HealthKit is not accessible when the device is locked. Keep the screen on until the full sync completes."
                        )
                    }
                }

                // Error banner
                if let err = vm.errorMessage {
                    Section {
                        noticeBanner(
                            icon: "exclamationmark.triangle.fill",
                            color: .red,
                            title: nil,
                            message: err
                        )
                    }
                }

                if let err = vm.lastDeliveryError {
                    Section {
                        noticeBanner(
                            icon: "tray.and.arrow.up.fill",
                            color: .orange,
                            title: "Last Delivery Error",
                            message: err
                        )
                    }
                }

                if let err = vm.receiverStatusError {
                    Section {
                        noticeBanner(
                            icon: "internaldrive.fill",
                            color: .orange,
                            title: "Mac Status Unavailable",
                            message: err
                        )
                    }
                }

                // Prerequisite issues banner
                if !vm.prerequisiteIssues.isEmpty && !vm.isAnySyncRunning {
                    Section("Action Required") {
                        ForEach(vm.prerequisiteIssues) { issue in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.orange)
                                    Text(issue.title)
                                        .font(.subheadline.weight(.semibold))
                                }
                                Text(issue.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !issue.actionLabel.isEmpty {
                                    Button(issue.actionLabel) {
                                        handlePrerequisiteAction(issue)
                                    }
                                    .font(.caption.weight(.semibold))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                // Category cards
                Section("Categories") {
                    ForEach(vm.categories) { cat in
                        CategoryStatusCard(
                            state: cat,
                            onReset: { vm.resetCategory(categoryID: cat.id) },
                            onSync: { vm.startCategorySync(categoryID: cat.id) },
                            isSyncRunning: vm.isAnySyncRunning
                        )
                    }
                }

                BrandFooter()
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SyncHealth")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $navigateToHealthPermissions) {
                HealthPermissionsView(vm: SettingsViewModel())
            }
            .onAppear {
                vm.refreshStatus()
                vm.checkPrerequisites()
                vm.refreshLatestHealthKitDates()
                vm.resumeBaselineIfNeeded()
            }
            .onChange(of: vm.isFullSyncRunning) { _, isRunning in
                UIApplication.shared.isIdleTimerDisabled = isRunning && keepScreenOnDuringSync
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
            .alert("Sync Prerequisites", isPresented: $vm.showPrerequisiteAlert) {
                Button("Continue Anyway") { }
                Button("Cancel Sync", role: .cancel) {
                    vm.cancelSync()
                }
            } message: {
                let titles = vm.prerequisiteIssues.map { $0.title }
                Text("Issues found:\n\(titles.joined(separator: "\n"))\n\nThe sync will continue but some data may be missing. Fix these issues in Settings for a complete sync.")
            }
        }
    }

    private var syncSummaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ZStack {
                    Circle()
                        .fill(summaryColor)
                        .frame(width: 36, height: 36)
                    Image(systemName: summaryIcon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }

                Text(summaryTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    vm.refreshStatus()
                } label: {
                    Group {
                        if vm.isRefreshingStatus {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(vm.isRefreshingStatus)
                .accessibilityLabel("Refresh sync status")
            }

            if vm.lastStatusDate != nil {
                HStack(spacing: 4) {
                    Text("Last synced")
                        .foregroundStyle(.secondary)
                    Text(vm.lastSyncRelativeLabel)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                }
                .font(.subheadline)
            } else {
                Text("No acknowledged sync yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                summaryMetric(
                    icon: "arrow.up.circle.fill",
                    value: "\(vm.sessionAcknowledgedPoints.formatted()) sent"
                )
                summaryMetric(
                    icon: "checkmark.circle",
                    value: "\(vm.completedStreamCount)/\(vm.totalStreamCount) streams"
                )
                Spacer(minLength: 4)
                Text(durationLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private var statisticsCards: some View {
        HStack(spacing: 12) {
            statisticCard(
                icon: "arrow.up.to.line.compact",
                value: vm.lifetimeAcknowledgedPoints.formatted(),
                label: "lifetime sent"
            )
            statisticCard(
                icon: "internaldrive.fill",
                value: vm.receiverStatus?.indexedItems.formatted() ?? "—",
                label: receiverStorageLabel
            )
        }
    }

    private var syncActionsCard: some View {
        VStack(spacing: 12) {
            syncButtons
            if vm.isAnySyncRunning {
                overallProgress
            }
            if !vm.currentOperation.isEmpty {
                Text(vm.currentOperation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func summaryMetric(icon: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.subheadline)
    }

    private func statisticCard(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.red.opacity(0.78))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 17)
        .frame(maxWidth: .infinity, minHeight: 88)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private var summaryTitle: String {
        switch vm.summaryStatus {
        case .syncing: return "Syncing"
        case .healthy: return "Sync healthy"
        case .needsBaseline: return "Full sync needed"
        case .waitingToSend: return "Waiting to send"
        case .needsAttention: return "Sync needs attention"
        case .notSynced: return "Not synced yet"
        }
    }

    private var summaryIcon: String {
        switch vm.summaryStatus {
        case .syncing: return "arrow.triangle.2.circlepath"
        case .healthy: return "checkmark"
        case .needsBaseline: return "arrow.clockwise"
        case .waitingToSend: return "arrow.up"
        case .needsAttention: return "exclamationmark"
        case .notSynced: return "minus"
        }
    }

    private var summaryColor: Color {
        switch vm.summaryStatus {
        case .syncing: return .blue
        case .healthy: return .green
        case .needsBaseline, .waitingToSend: return .orange
        case .needsAttention: return .red
        case .notSynced: return .gray
        }
    }

    private var durationLabel: String {
        guard let duration = vm.lastRunDuration else { return "—" }
        if duration < 10 {
            return duration.formatted(.number.precision(.fractionLength(1))) + "s"
        }
        return duration.formatted(.number.precision(.fractionLength(0))) + "s"
    }

    private var receiverStorageLabel: String {
        guard let bytes = vm.receiverStatus?.databaseBytes else {
            return "health index on Mac"
        }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) health index"
    }

    private var syncButtons: some View {
        VStack(spacing: 12) {
            Button {
                vm.startIncrementalSync()
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .font(.subheadline.weight(.semibold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(vm.isAnySyncRunning)
            .opacity(vm.isAnySyncRunning ? 0.5 : 1)

            HStack(spacing: 12) {
                Button {
                    vm.startFullSync()
                } label: {
                    Label("Full Sync", systemImage: "arrow.clockwise.icloud.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.blue)
                        .font(.subheadline.weight(.semibold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(vm.isAnySyncRunning)
                .opacity(vm.isAnySyncRunning ? 0.5 : 1)

                if vm.isAnySyncRunning {
                    Button {
                        vm.cancelSync()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.red)
                            .font(.subheadline.weight(.semibold))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

        }
    }

    private var overallProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Overall Progress")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(vm.overallProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: vm.overallProgress)
                .tint(.blue)
        }
    }

    private func noticeBanner(icon: String, color: Color, title: String?, message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(title != nil ? .secondary : color)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    private func handlePrerequisiteAction(_ issue: SyncPrerequisiteIssue) {
        switch issue {
        case .healthPermissionsNotRequested, .somePermissionsDenied:
            navigateToHealthPermissions = true
        case .connectionFailed:
            break
        case .healthDataUnavailable:
            break
        }
    }
}
