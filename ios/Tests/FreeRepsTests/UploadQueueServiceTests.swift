import XCTest
@testable import FreeReps

final class UploadQueueServiceTests: XCTestCase {
    private var directoryURL: URL!

    override func setUp() {
        super.setUp()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UploadQueueServiceTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        super.tearDown()
    }

    /// Authentication belongs only in the live request; persisted batches contain payload bytes alone.
    func testQueueFileExcludesTokenAndDeletesAfterAcknowledgement() async throws {
        let token = "never-persist-this-token"
        let payload = Data(#"{"data":{"metrics":[]}}"#.utf8)
        var observedHeader: String?
        URLProtocolStub.handler = { request in
            observedHeader = request.value(forHTTPHeaderField: "X-Health-Token")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"points":1}"#.utf8)
            )
        }
        let queue = UploadQueueService(directoryURL: directoryURL)
        let service = FreeRepsService(
            config: .default,
            session: URLProtocolStub.session(),
            tokenProvider: { token }
        )

        _ = try await queue.enqueue(payload)
        let files = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: files[0]), as: UTF8.self).contains(token))

        let deliveries = try await queue.drain(using: service)

        XCTAssertEqual(deliveries.map(\.acknowledgement.points), [1])
        XCTAssertEqual(observedHeader, token)
        let finalCount = try await queue.pendingCount()
        XCTAssertEqual(finalCount, 0)
    }

    /// A failed oldest batch blocks later batches and all files survive for a future retry.
    func testQueueRetainsFailureThenRetriesOldestFirst() async throws {
        let first = Data(#"{"batch":1}"#.utf8)
        let second = Data(#"{"batch":2}"#.utf8)
        var shouldFail = true
        var observedBodies: [Data] = []
        URLProtocolStub.handler = { request in
            observedBodies.append(URLProtocolStub.bodyData(from: request) ?? Data())
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: shouldFail ? 500 : 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                shouldFail ? Data() : Data(#"{"points":0}"#.utf8)
            )
        }
        let queue = UploadQueueService(directoryURL: directoryURL)
        let service = FreeRepsService(
            config: .default,
            session: URLProtocolStub.session(),
            tokenProvider: { "test-secret" }
        )
        _ = try await queue.enqueue(first)
        _ = try await queue.enqueue(second)

        do {
            _ = try await queue.drain(using: service)
            XCTFail("Expected first delivery to fail")
        } catch {
            XCTAssertEqual(error as? FreeRepsError, .httpError(statusCode: 500))
        }
        let retainedCount = try await queue.pendingCount()
        XCTAssertEqual(retainedCount, 2)

        shouldFail = false
        observedBodies.removeAll()
        let deliveries = try await queue.drain(using: service)

        XCTAssertEqual(observedBodies, [first, second])
        XCTAssertEqual(deliveries.count, 2)
        let finalCount = try await queue.pendingCount()
        XCTAssertEqual(finalCount, 0)
    }

    /// Even HTTP 200 must retain the batch when the SyncHealth acknowledgement is malformed.
    func testQueueRetainsMalformed200Response() async throws {
        URLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"unexpected":true}"#.utf8)
            )
        }
        let queue = UploadQueueService(directoryURL: directoryURL)
        let service = FreeRepsService(
            config: .default,
            session: URLProtocolStub.session(),
            tokenProvider: { "test-secret" }
        )
        _ = try await queue.enqueue(Data(#"{"batch":1}"#.utf8))

        do {
            _ = try await queue.drain(using: service)
            XCTFail("Expected malformed acknowledgement to fail")
        } catch let error as FreeRepsError {
            guard case .decodingError = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let retainedCount = try await queue.pendingCount()
        XCTAssertEqual(retainedCount, 1)
    }

    /// Queue discovery is filesystem-backed, so pending batches survive process/service recreation.
    func testQueueSurvivesServiceRecreation() async throws {
        let first = Data(#"{"batch":"first"}"#.utf8)
        let second = Data(#"{"batch":"second"}"#.utf8)
        let writer = UploadQueueService(directoryURL: directoryURL)
        _ = try await writer.enqueue(first)
        _ = try await writer.enqueue(second)

        var observedBodies: [Data] = []
        URLProtocolStub.handler = { request in
            observedBodies.append(URLProtocolStub.bodyData(from: request) ?? Data())
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"points":0}"#.utf8)
            )
        }

        let recreatedQueue = UploadQueueService(directoryURL: directoryURL)
        let service = FreeRepsService(
            config: .default,
            session: URLProtocolStub.session(),
            tokenProvider: { "test-secret" }
        )

        let recreatedCount = try await recreatedQueue.pendingCount()
        XCTAssertEqual(recreatedCount, 2)
        _ = try await recreatedQueue.drain(using: service)

        XCTAssertEqual(observedBodies, [first, second])
        let finalCount = try await recreatedQueue.pendingCount()
        XCTAssertEqual(finalCount, 0)
    }

    /// A malformed filesystem layout must be repaired without discarding the stranded batch.
    func testQueueRepairsFileAtDirectoryPath() async throws {
        let strandedPayload = Data(#"{"data":{"metrics":[]}}"#.utf8)
        try strandedPayload.write(to: directoryURL, options: .atomic)

        let queue = UploadQueueService(directoryURL: directoryURL)

        let pendingCount = try await queue.pendingCount()
        XCTAssertEqual(pendingCount, 1)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directoryURL.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
        let files = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: files[0]), strandedPayload)
    }
}
