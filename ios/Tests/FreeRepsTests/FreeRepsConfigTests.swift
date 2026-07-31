import XCTest
@testable import FreeReps

final class FreeRepsConfigTests: XCTestCase {
    /// The configured endpoint is the complete ingest contract, so transport must not append routes.
    func testValidatedEndpointPreservesAbsoluteHealthPath() throws {
        let config = FreeRepsConfig(endpointURL: "https://your-host.example/health")

        XCTAssertEqual(
            try config.validatedEndpointURL().absoluteString,
            "https://your-host.example/health"
        )
    }

    /// Health data and its token must never be sent to a plaintext endpoint.
    func testValidatedEndpointRejectsHTTP() {
        let config = FreeRepsConfig(endpointURL: "http://your-host.example/health")

        XCTAssertThrowsError(try config.validatedEndpointURL()) { error in
            XCTAssertEqual(error as? FreeRepsConfigError, .insecureEndpoint)
        }
    }
}
