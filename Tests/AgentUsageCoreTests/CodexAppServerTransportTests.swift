import Foundation
import Testing
@testable import AgentUsageCore

struct CodexAppServerTransportTests {
    @Test func fragmentedResponseAndNotification() async throws {
        let fixture = try FakeServer(body: #"""
            read -r line || exit 1
            printf '{"id":1,"result":{}}\n'
            read -r line || exit 1
            read -r line || exit 1
            printf 'diagnostic only\n' >&2
            printf '{"method":"account/updated","params":{"state":"ok"}}\n'
            printf '{"id":2,"res'
            sleep 0.05
            printf 'ult":{"value":42}}\n'
            read -r line || exit 0
            """#)
        defer { fixture.remove() }
        let transport = fixture.transport()
        try await transport.start()
        let result = try await transport.request(method: "account/read", params: Data("{}".utf8))
        let object = try #require(JSONSerialization.jsonObject(with: result) as? [String: Int])
        #expect(object["value"] == 42)

        var iterator = transport.notifications.makeAsyncIterator()
        let notice = await iterator.next()
        #expect(notice?.method == "account/updated")
        let params = try #require(notice?.params)
        let noticeObject = try #require(JSONSerialization.jsonObject(with: params) as? [String: String])
        #expect(noticeObject["state"] == "ok")
        await transport.stop()
    }

    @Test func matchesConcurrentResponsesByID() async throws {
        let fixture = try FakeServer(body: #"""
            read -r line || exit 1
            printf '{"id":1,"result":{}}\n'
            read -r line || exit 1
            read -r first || exit 1
            read -r second || exit 1
            first_id=$(printf '%s' "$first" | sed -E 's/.*"id":([0-9]+).*/\1/')
            second_id=$(printf '%s' "$second" | sed -E 's/.*"id":([0-9]+).*/\1/')
            first_method=$(printf '%s' "$first" | sed -E 's/.*"method":"([^"]+)".*/\1/')
            second_method=$(printf '%s' "$second" | sed -E 's/.*"method":"([^"]+)".*/\1/')
            printf '{"id":%s,"result":{"method":"%s"}}\n' "$second_id" "$second_method"
            printf '{"id":%s,"result":{"method":"%s"}}\n' "$first_id" "$first_method"
            read -r line || exit 0
            """#)
        defer { fixture.remove() }
        let transport = fixture.transport()
        try await transport.start()
        async let first = transport.request(method: "account/read")
        async let second = transport.request(method: "account/rateLimits/read")
        let firstData = try await first
        let secondData = try await second
        let firstObject = try #require(JSONSerialization.jsonObject(with: firstData) as? [String: String])
        let secondObject = try #require(JSONSerialization.jsonObject(with: secondData) as? [String: String])
        #expect(firstObject["method"] == "account/read")
        #expect(secondObject["method"] == "account/rateLimits/read")
        await transport.stop()
    }

    @Test func timeoutAndCancellation() async throws {
        let fixture = try FakeServer(body: #"""
            read -r line || exit 1
            printf '{"id":1,"result":{}}\n'
            read -r line || exit 1
            read -r line || exit 1
            sleep 3
            """#)
        defer { fixture.remove() }
        let transport = fixture.transport()
        try await transport.start()
        do {
            _ = try await transport.request(method: "slow", timeout: .milliseconds(50))
            Issue.record("Expected a request timeout")
        } catch {
            #expect(error as? AppServerTransportError == .timedOut)
        }

        let task = Task { try await transport.request(method: "cancelled", timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error as? AppServerTransportError == .cancelled)
        }

        let stoppedTask = Task { try await transport.request(method: "stopped", timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        await transport.stop()
        do {
            _ = try await stoppedTask.value
            Issue.record("Expected shutdown to fail the pending request")
        } catch {
            #expect(error as? AppServerTransportError == .stopped)
        }
    }

    @Test func processExitFailsPendingRequest() async throws {
        let fixture = try FakeServer(body: #"""
            read -r line || exit 1
            printf '{"id":1,"result":{}}\n'
            read -r line || exit 1
            read -r line || exit 1
            exit 7
            """#)
        defer { fixture.remove() }
        let transport = fixture.transport()
        try await transport.start()
        do {
            _ = try await transport.request(method: "account/read")
            Issue.record("Expected process exit")
        } catch {
            #expect(error as? AppServerTransportError == .processExited)
        }
    }

    @Test func serverErrorKeepsOnlyCode() async throws {
        let fixture = try FakeServer(body: #"""
            read -r line || exit 1
            printf '{"id":1,"result":{}}\n'
            read -r line || exit 1
            read -r line || exit 1
            printf '{"id":2,"error":{"code":-32601,"message":"Sensitive detail"}}\n'
            read -r line || exit 0
            """#)
        defer { fixture.remove() }
        let transport = fixture.transport()
        try await transport.start()
        do {
            _ = try await transport.request(method: "missing/method")
            Issue.record("Expected a server error")
        } catch {
            #expect(error as? AppServerTransportError == .serverError(code: -32601))
        }
        await transport.stop()
    }
}

private struct FakeServer {
    let directory: URL
    let executable: URL

    init(body: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        executable = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func transport() -> CodexAppServerTransport {
        CodexAppServerTransport(executableURL: executable, codexHomeURL: directory)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
