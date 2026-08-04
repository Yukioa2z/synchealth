import XCTest
@testable import FreeReps

final class FreeRepsServiceTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    /// SyncHealth accepts only the exact configured URL and requires its private authentication header.
    func testIngestUsesExactEndpointAndInjectsToken() async throws {
        let body = Data(#"{"data":{"metrics":[]}}"#.utf8)
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://your-host.example/health")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Health-Token"), "test-secret")
            XCTAssertEqual(URLProtocolStub.bodyData(from: request), body)
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"points":3,"ignored":"ok"}"#.utf8)
            )
        }
        let service = FreeRepsService(
            config: .default,
            session: URLProtocolStub.session(),
            tokenProvider: { "test-secret" }
        )

        let acknowledgement = try await service.ingest(encodedPayload: body)

        XCTAssertEqual(acknowledgement, IngestAcknowledgement(points: 3))
    }

    func testStatusUsesExactEndpointAndDecodesMetadata() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://your-host.example/health")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Health-Token"),
                "test-secret"
            )
            XCTAssertNil(URLProtocolStub.bodyData(from: request))
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    #"""
                    {
                      "indexed_items": 7162114,
                      "metric_count": 25,
                      "database_bytes": 12582912,
                      "raw_payloads": 34,
                      "last_received_at": 1785859200
                    }
                    """#.utf8
                )
            )
        }
        let service = FreeRepsService(
            config: .default,
            session: URLProtocolStub.session(),
            tokenProvider: { "test-secret" }
        )

        let status = try await service.fetchStatus()

        XCTAssertEqual(status.indexedItems, 7_162_114)
        XCTAssertEqual(status.metricCount, 25)
        XCTAssertEqual(status.databaseBytes, 12_582_912)
        XCTAssertEqual(status.rawPayloads, 34)
        XCTAssertEqual(status.lastReceivedAt, 1_785_859_200)
    }

    /// A non-200 response is not an acknowledgement and must remain retryable by the queue.
    func testIngestRejectsNon200() async {
        let token = "do-not-leak-this-test-token"
        URLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        let service = FreeRepsService(
            config: .default,
            session: URLProtocolStub.session(),
            tokenProvider: { token }
        )

        do {
            _ = try await service.ingest(encodedPayload: Data("{}".utf8))
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertEqual(error as? FreeRepsError, .httpError(statusCode: 503))
            XCTAssertFalse(error.localizedDescription.contains(token))
        }
    }

    /// HTTP 200 without a decodable points value is still a failed delivery.
    func testIngestRejectsMalformedAcknowledgement() async {
        URLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"status":"ok"}"#.utf8)
            )
        }
        let service = FreeRepsService(
            config: .default,
            session: URLProtocolStub.session(),
            tokenProvider: { "test-secret" }
        )

        do {
            _ = try await service.ingest(encodedPayload: Data("{}".utf8))
            XCTFail("Expected decoding failure")
        } catch let error as FreeRepsError {
            guard case .decodingError = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// Missing Keychain material must fail before any unauthenticated network request is made.
    func testIngestRequiresToken() async {
        URLProtocolStub.handler = { _ in
            XCTFail("No request should be made without a token")
            throw URLProtocolStub.StubError.missingHandler
        }
        let service = FreeRepsService(
            config: .default,
            session: URLProtocolStub.session(),
            tokenProvider: { nil }
        )

        do {
            _ = try await service.ingest(encodedPayload: Data("{}".utf8))
            XCTFail("Expected missing-token failure")
        } catch {
            XCTAssertEqual(error as? FreeRepsError, .missingToken)
        }
    }
}
