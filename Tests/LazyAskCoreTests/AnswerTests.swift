import Foundation
import Testing
@testable import LazyAskCore

@Suite("Answer generation")
struct AnswerTests {
    let request = AnswerRequest(triggerText: "Lazy Ask", question: "What is a cache?", context: [])

    @Test func streamsMockedAnswer() async throws {
        let service = OpenAIAnswerService(apiKey: "test-key", transport: MockTransport(status: 200, lines: [
            "event: response.output_text.delta", #"data: {"type":"response.output_text.delta","delta":"A cache "}"#, "",
            #"data: {"type":"response.output_text.delta","delta":"stores data."}"#, "",
            #"data: {"type":"response.completed"}"#, ""
        ]))
        let collector = DeltaCollector()
        let result = try await service.answer(request) { await collector.append($0) }
        #expect(result == "A cache stores data.")
        #expect(await collector.text == result)
    }

    @Test func requestDoesNotStoreResponses() throws {
        let service = OpenAIAnswerService(apiKey: "test-key")
        let http = try service.makeRequest(request)
        let data = try #require(http.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["model"] as? String == "gpt-4.1-mini")
        #expect(http.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let input = try #require(body["input"] as? String)
        #expect(try JSONDecoder().decode(AnswerRequest.self, from: Data(input.utf8)) == request)
    }

    @Test func authenticationFailureIsShown() async {
        let service = OpenAIAnswerService(apiKey: "test-key", transport: MockTransport(status: 401,
            lines: [#"{"error":{"message":"Invalid API key","code":"invalid_api_key"}}"#]))
        do {
            _ = try await service.answer(request) { _ in }
            Issue.record("Expected authentication failure")
        } catch { #expect(error.localizedDescription == "Invalid API key") }
    }

    @Test func partialStreamIsNotReportedAsFinished() async {
        let service = OpenAIAnswerService(apiKey: "test-key", transport: MockTransport(status: 200,
            lines: [#"data: {"type":"response.output_text.delta","delta":"Half an answer"}"#, ""]))
        await #expect(throws: LazyAskError.self) { try await service.answer(request) { _ in } }
    }

    @Test func failedEventIsShown() async {
        let service = OpenAIAnswerService(apiKey: "test-key", transport: MockTransport(status: 200,
            lines: [#"data: {"type":"response.failed","response":{"error":{"message":"Rate limit reached"}}}"#, ""]))
        do {
            _ = try await service.answer(request) { _ in }
            Issue.record("Expected failure")
        } catch { #expect(error.localizedDescription == "Rate limit reached") }
    }

    @Test func sseMultilineAndComments() {
        var parser = ServerSentEventParser()
        #expect(parser.consume(": keepalive") == nil)
        #expect(parser.consume("event: response.completed") == nil)
        #expect(parser.consume("data: {\"type\":") == nil)
        #expect(parser.consume("data: \"response.completed\"}") == nil)
        #expect(parser.consume("") == "{\"type\":\n\"response.completed\"}")
    }

    @Test func byteStreamKeepsBlankBoundariesAndUnicode() throws {
        var decoder = HTTPLineDecoder()
        var lines: [String] = []
        for byte in "data: caf\u{00e9}\r\n\r\ndata: done\n\n".utf8 {
            if let line = try decoder.consume(byte) { lines.append(line) }
        }
        #expect(lines == ["data: caf\u{00e9}", "", "data: done", ""])
    }
}

private struct MockTransport: HTTPLineTransport {
    let status: Int
    let lines: [String]

    func send(_ request: URLRequest) async throws -> HTTPLineResponse {
        HTTPLineResponse(statusCode: status, lines: AsyncThrowingStream { continuation in
            lines.forEach { continuation.yield($0) }
            continuation.finish()
        })
    }
}

private actor DeltaCollector {
    var text = ""
    func append(_ value: String) { text += value }
}
