import XCTest
@testable import Backlit

final class ParserAdversarialTests: XCTestCase {
    private let token = "isolated-adversarial-fixture"
    private func frame(_ body: Data = Data(), headers: [String] = []) -> Data {
        var value = Data(("POST /v1/light HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.count)\r\n" + headers.joined(separator: "\r\n") + (headers.isEmpty ? "" : "\r\n") + "\r\n").utf8)
        value.append(body)
        return value
    }

    func testEveryFragmentBoundaryWaitsForCompleteBody() throws {
        let body = Data(#"{"enabled":false,"brightness":127,"effect":"Breathe"}"#.utf8)
        let request = frame(body)
        for length in 0..<request.count {
            XCTAssertNil(try BridgeRequest.parse(Data(request.prefix(length))), "prefix \(length)")
        }
        let parsed = try XCTUnwrap(BridgeRequest.parse(request))
        XCTAssertEqual(parsed.body, body)
        XCTAssertTrue(parsed.authorized(token))
        let command = try LightCommand(data: parsed.body)
        XCTAssertEqual(command.enabled, false)
        XCTAssertEqual(command.mode, .breathe)
    }

    func testAmbiguousFramingIsRejected() {
        let invalid = [
            "POST /v1/light HTTP/1.1\r\nContent-Length: +2\r\n\r\n{}",
            "POST /v1/light HTTP/1.1\r\nContent-Length: -0\r\n\r\n",
            "POST /v1/light HTTP/1.1\r\nContent-Length: 2,2\r\n\r\n{}",
            "POST /v1/light HTTP/1.1\r\nContent-Length: ٢\r\n\r\n{}",
            "POST /v1/light HTTP/1.1\r\nContent-Length: 0\r\ncontent-length: 0\r\n\r\n",
            "POST /v1/light HTTP/1.1\r\nTransfer-Encoding: identity\r\nContent-Length: 2\r\n\r\n{}",
            "GET /v1/state HTTP/1.1\r\n\r\nGET /v1/state HTTP/1.1\r\n\r\n",
        ]
        for request in invalid { XCTAssertThrowsError(try BridgeRequest.parse(Data(request.utf8))) }
    }

    func testMalformedNamesControlValuesAndRequestLineAreRejected() {
        let invalid = [
            "GET /v1/state HTTP/1.1\r\n: empty\r\n\r\n",
            "GET /v1/state HTTP/1.1\r\nOrigin : https://example.invalid\r\n\r\n",
            "GET /v1/state HTTP/1.1\r\nX Name: value\r\n\r\n",
            "GET /v1/state HTTP/1.1\r\nX-Name: value\u{0}\r\n\r\n",
            "GET /v1/state HTTP/1.1\r\nX-Name: value\u{7f}\r\n\r\n",
            "GET /v1/state HTTP/1.1\r\nX-Name: one\r\n two\r\n\r\n",
            "GE\tT /v1/state HTTP/1.1\r\n\r\n",
            "GET /v1/sta\u{0}te HTTP/1.1\r\n\r\n",
            "GET /v1/state HTTP/2.0\r\n\r\n",
        ]
        for request in invalid { XCTAssertThrowsError(try BridgeRequest.parse(Data(request.utf8))) }
    }

    func testValidOWSCaseInsensitiveNamesAndLengthBoundariesRemainAccepted() throws {
        let body = Data(repeating: 32, count: 8192)
        var request = Data("POST /v1/light HTTP/1.0\r\nAUTHORIZATION:\tBearer \(token) \t\r\nContent-Length: 0008192\r\nX-Name: one\t two\r\n\r\n".utf8)
        request.append(body)
        let parsed = try XCTUnwrap(BridgeRequest.parse(request))
        XCTAssertTrue(parsed.authorized(token))
        XCTAssertEqual(parsed.body.count, 8192)
        XCTAssertEqual(parsed.headers["x-name"], "one\t two")
        XCTAssertThrowsError(try BridgeRequest.parse(Data("POST /v1/light HTTP/1.1\r\nContent-Length: 8193\r\n\r\n".utf8)))
        XCTAssertThrowsError(try BridgeRequest.parse(Data(repeating: 65, count: 8192)))
        XCTAssertThrowsError(try BridgeRequest.parse(Data(repeating: 65, count: 16385)))
    }

    func testHeaderLimitIsIndependentOfTerminatorFragmentation() throws {
        let base = Data("GET /v1/state HTTP/1.1\r\nX-Pad: ".utf8)
        let terminator = Data("\r\n\r\n".utf8)
        for headerLength in 8189...8191 {
            var header = base
            header.append(Data(repeating: 65, count: headerLength - base.count))
            for suffixLength in 0..<terminator.count {
                var incomplete = header
                incomplete.append(terminator.prefix(suffixLength))
                XCTAssertNil(try BridgeRequest.parse(incomplete), "header \(headerLength), terminator prefix \(suffixLength)")
            }
            header.append(terminator)
            XCTAssertNotNil(try BridgeRequest.parse(header))
        }
        var overlong = base
        overlong.append(Data(repeating: 65, count: 8192 - base.count))
        XCTAssertThrowsError(try BridgeRequest.parse(overlong))
        overlong.append(terminator)
        XCTAssertThrowsError(try BridgeRequest.parse(overlong))
    }

    func testOriginAndAuthorizationCannotBeConfusedByHeaderCaseOrTokenPrefixes() throws {
        XCTAssertFalse(try XCTUnwrap(BridgeRequest.parse(frame(headers: ["oRiGiN: null"]))).authorized(token))
        XCTAssertFalse(try XCTUnwrap(BridgeRequest.parse(frame())).authorized(token + "x"))
        XCTAssertFalse(try XCTUnwrap(BridgeRequest.parse(frame())).authorized(String(token.dropLast())))
        XCTAssertThrowsError(try BridgeRequest.parse(frame(headers: ["AUTHORIZATION: Bearer duplicate"])))
    }

    func testDeterministicMalformedByteCorpusNeverEscapesParserBounds() {
        var state: UInt64 = 0x77c83b9419d246e1
        for length in 0..<400 {
            var bytes = [UInt8]()
            for _ in 0..<length {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                bytes.append(UInt8(truncatingIfNeeded: state >> 24))
            }
            do {
                if let request = try BridgeRequest.parse(Data(bytes)) {
                    XCTAssertLessThanOrEqual(request.body.count, 8192)
                    XCTAssertFalse(request.authorized(token))
                }
            } catch { /* Malformed bytes should be rejected, not trap. */ }
        }
    }
}
