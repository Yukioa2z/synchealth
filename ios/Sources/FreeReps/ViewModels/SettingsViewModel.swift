import Foundation
import HealthKit
import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {

    @Published var config: FreeRepsConfig = .load()
    @Published var endpointError: String?
    @Published var tokenDraft = ""
    @Published var hasStoredToken = HealthTokenStore.shared.containsToken()
    @Published var tokenStatusMessage: String?
    @Published var permissionsRequested: Bool = UserDefaults.standard.bool(forKey: "hk_permissions_requested")
    @Published var deniedTypes: [HKObjectType] = []
    @Published var grantedTypes: [HKObjectType] = []
    @Published var errorMessage: String?
    @Published var isRequestingPermissions = false

    private let healthKit = HealthKitService.shared

    init() { }

    func saveConfig() {
        do {
            _ = try config.validatedEndpointURL()
            endpointError = config.save() ? nil : "Could not save the endpoint."
        } catch {
            endpointError = error.localizedDescription
        }
    }

    func saveToken() {
        let value = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try HealthTokenStore.shared.save(value)
            tokenDraft = ""
            hasStoredToken = true
            tokenStatusMessage = "Token stored securely in Keychain."
        } catch {
            tokenStatusMessage = error.localizedDescription
        }
    }

    func clearToken() {
        do {
            try HealthTokenStore.shared.clear()
            tokenDraft = ""
            hasStoredToken = false
            tokenStatusMessage = "Token removed."
        } catch {
            tokenStatusMessage = error.localizedDescription
        }
    }

    // MARK: - HealthKit permissions

    func refreshPermissionsState() {
        let (granted, denied) = healthKit.checkAllPermissionStatuses()
        self.grantedTypes = granted
        self.deniedTypes = denied
        if !granted.isEmpty {
            permissionsRequested = true
            UserDefaults.standard.set(true, forKey: "hk_permissions_requested")
        } else {
            permissionsRequested = UserDefaults.standard.bool(forKey: "hk_permissions_requested")
        }
    }

    var hasDeniedPermissions: Bool {
        !deniedTypes.isEmpty
    }

    func requestAllPermissions() {
        guard !isRequestingPermissions else { return }
        isRequestingPermissions = true
        Task {
            do {
                try await healthKit.requestAllPermissions()
            } catch {
                errorMessage = "HealthKit authorization failed: \(error.localizedDescription)"
            }
            UserDefaults.standard.set(true, forKey: "hk_permissions_requested")
            permissionsRequested = true
            refreshPermissionsState()
            isRequestingPermissions = false
        }
    }

    func requestMissingPermissions() {
        guard !deniedTypes.isEmpty, !isRequestingPermissions else { return }
        isRequestingPermissions = true
        let types = Set(deniedTypes)
        Task {
            do {
                try await healthKit.requestPermissions(for: types)
            } catch {
                errorMessage = "HealthKit authorization failed: \(error.localizedDescription)"
            }
            refreshPermissionsState()
            isRequestingPermissions = false
        }
    }

    // MARK: - Per-object authorization (medications & vision prescriptions)

    func requestVisionPrescriptionAccess() {
        Task {
            await healthKit.requestVisionPrescriptionAuthorization()
        }
    }

    func requestMedicationAccess() {
        Task {
            if #available(iOS 26, *) {
                await healthKit.requestMedicationAuthorization()
            }
        }
    }
}
