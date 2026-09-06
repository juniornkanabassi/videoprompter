import Foundation
import XCTest
@preconcurrency import Network

@testable import JuniorPrompter

@MainActor
final class OBSServerTests: XCTestCase {
  private func connect(to url: URL) async throws -> NWConnection {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWConnection, Error>) in
      let connection = NWConnection(
        host: NWEndpoint.Host(url.host()!),
        port: NWEndpoint.Port(rawValue: UInt16(url.port!))!,
        using: .tcp)
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          connection.stateUpdateHandler = nil
          continuation.resume(returning: connection)
        case .failed(let error):
          connection.stateUpdateHandler = nil
          continuation.resume(throwing: error)
        default:
          break
        }
      }
      connection.start(queue: .main)
    }
  }

  private func exchange(_ request: Data, with url: URL) async throws -> Data {
    let connection = try await connect(to: url)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(content: request, completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      })
    }
    return try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
        data, _, _, error in
        connection.cancel()
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: data ?? Data()) }
      }
    }
  }

  private func waitForClose(_ connection: NWConnection, timeout: TimeInterval = 6) async {
    let expectation = expectation(description: "connection closed")
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
      if complete || error != nil { expectation.fulfill() }
    }
    await fulfillment(of: [expectation], timeout: timeout)
  }

  func testCancelledStartCompletesWithoutLeavingAListener() async {
    let server = OBSServer()
    let start = Task { try await server.start() }
    start.cancel()

    do {
      _ = try await start.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected cancellation, got \(error)")
    }
    XCTAssertNil(server.url)
    XCTAssertEqual(server.status, "Stopped")
  }

  func testLoopbackServerStartsServesStateAndStops() async throws {
    let server = OBSServer()
    defer { server.stop() }
    let url = try await server.start()
    XCTAssertEqual(url.host(), "127.0.0.1")
    XCTAssertEqual(server.status, "Running")

    let (data, response) = try await URLSession.shared.data(from: url.appending(path: "state"))
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertNoThrow(try JSONDecoder().decode(OBSSnapshot.self, from: data))

    server.stop()
    XCTAssertNil(server.url)
    XCTAssertEqual(server.status, "Stopped")
  }

  func testRendererUsesSameOriginScriptRoute() async throws {
    let server = OBSServer()
    defer { server.stop() }
    let url = try await server.start()

    let (htmlData, htmlResponse) = try await URLSession.shared.data(from: url)
    let html = String(decoding: htmlData, as: UTF8.self)
    XCTAssertEqual((htmlResponse as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertTrue(html.contains("script-src 'self'"))
    XCTAssertTrue(html.contains("src=\"script.js\""))

    let (scriptData, scriptResponse) = try await URLSession.shared.data(
      from: url.appending(path: "script.js"))
    XCTAssertEqual((scriptResponse as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertTrue(String(decoding: scriptData, as: UTF8.self).contains("setInterval"))
  }

  func testOversizedHeaderWithLateTerminatorIsRejected() async throws {
    let server = OBSServer()
    defer { server.stop() }
    let url = try await server.start()
    let request = Data(
      "GET /\(url.pathComponents[1])/ HTTP/1.1\r\nHost: \(url.host()!):\(url.port!)\r\n\(String(repeating: "x", count: 8200))\r\n\r\n".utf8)
    let response = try await exchange(request, with: url)
    XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 413"))
  }

  func testForeignHostAndOriginAreRejected() async throws {
    let server = OBSServer()
    defer { server.stop() }
    let url = try await server.start()
    let path = url.pathComponents[1]
    let hostResponse = try await exchange(
      Data("GET /\(path)/state HTTP/1.1\r\nHost: example.test\r\n\r\n".utf8), with: url)
    XCTAssertTrue(String(decoding: hostResponse, as: UTF8.self).hasPrefix("HTTP/1.1 403"))
    let originResponse = try await exchange(
      Data("GET /\(path)/state HTTP/1.1\r\nHost: \(url.host()!):\(url.port!)\r\nOrigin: http://example.test\r\n\r\n".utf8), with: url)
    XCTAssertTrue(String(decoding: originResponse, as: UTF8.self).hasPrefix("HTTP/1.1 403"))
  }

  func testIncompleteClientIsCancelledAfterTimeout() async throws {
    let server = OBSServer()
    defer { server.stop() }
    let url = try await server.start()
    let connection = try await connect(to: url)
    connection.send(content: Data("GET /".utf8), completion: .contentProcessed { _ in })
    await waitForClose(connection)
  }

  func testStopCancelsLiveClient() async throws {
    let server = OBSServer()
    let url = try await server.start()
    let connection = try await connect(to: url)
    connection.send(content: Data("GET /".utf8), completion: .contentProcessed { _ in })
    let close = Task { await waitForClose(connection, timeout: 1) }
    server.stop()
    await close.value
  }
}
