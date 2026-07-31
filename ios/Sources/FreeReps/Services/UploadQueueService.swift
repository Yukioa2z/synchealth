import Foundation

struct QueueDelivery: Equatable {
    let batchID: String
    let acknowledgement: IngestAcknowledgement
}

/// Durable, oldest-first queue for encoded HealthKit upload batches.
actor UploadQueueService {
    static let shared = UploadQueueService()

    private let directoryURL: URL
    private let fileManager: FileManager
    private var drainInProgress = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastEnqueueOrder: Int64 = 0

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.directoryURL = applicationSupport
                .appendingPathComponent("SyncHealthUploadQueue", isDirectory: true)
        }
    }

    @discardableResult
    func enqueue(_ encodedPayload: Data) throws -> String {
        try ensureDirectory()

        let currentOrder = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let enqueueOrder = max(currentOrder, lastEnqueueOrder + 1)
        lastEnqueueOrder = enqueueOrder
        let batchID = String(
            format: "%020lld-%@",
            enqueueOrder,
            UUID().uuidString.lowercased()
        )
        let temporaryURL = directoryURL.appendingPathComponent(".\(batchID).tmp")
        let finalURL = directoryURL.appendingPathComponent("\(batchID).json")

        do {
            try encodedPayload.write(to: temporaryURL, options: .atomic)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: temporaryURL.path
            )
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: finalURL.path
            )
            return batchID
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    func pendingCount() throws -> Int {
        try queuedFiles().count
    }

    /// Sends queued batches oldest first and removes each file only after a decoded HTTP 200.
    func drain(using service: FreeRepsService) async throws -> [QueueDelivery] {
        await acquireDrain()
        defer { releaseDrain() }

        var deliveries: [QueueDelivery] = []
        for fileURL in try queuedFiles() {
            let payload = try Data(contentsOf: fileURL)
            let acknowledgement = try await service.ingest(encodedPayload: payload)
            try fileManager.removeItem(at: fileURL)
            deliveries.append(
                QueueDelivery(
                    batchID: fileURL.deletingPathExtension().lastPathComponent,
                    acknowledgement: acknowledgement
                )
            )
        }
        return deliveries
    }

    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }

            // Preserve a stranded payload if the queue path was unexpectedly created as a
            // file (for example by an interrupted migration or device restore), then repair
            // the directory in place so launch-time retry can continue without data loss.
            let recoveryURL = directoryURL.deletingLastPathComponent()
                .appendingPathComponent(".SyncHealthUploadQueue-\(UUID().uuidString).recovery")
            try fileManager.moveItem(at: directoryURL, to: recoveryURL)
            do {
                try createDirectory()
                let recoveredBatchURL = directoryURL.appendingPathComponent(
                    "00000000000000000000-recovered-\(UUID().uuidString.lowercased()).json"
                )
                try fileManager.moveItem(at: recoveryURL, to: recoveredBatchURL)
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: recoveredBatchURL.path
                )
            } catch {
                if !fileManager.fileExists(atPath: directoryURL.path) {
                    try? fileManager.moveItem(at: recoveryURL, to: directoryURL)
                }
                throw error
            }
            return
        }

        try createDirectory()
    }

    private func createDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ]
        )
    }

    private func queuedFiles() throws -> [URL] {
        try ensureDirectory()
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func acquireDrain() async {
        if !drainInProgress {
            drainInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
    }

    private func releaseDrain() {
        if drainWaiters.isEmpty {
            drainInProgress = false
        } else {
            drainWaiters.removeFirst().resume()
        }
    }
}
