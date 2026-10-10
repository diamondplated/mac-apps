import Darwin
import Foundation
import Network

public enum NetworkDiagnosticState: String, Sendable {
    case passed, attention, unavailable
}

public struct NetworkDiagnosticStage: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let state: NetworkDiagnosticState
    public let detail: String
    public init(id: String, title: String, state: NetworkDiagnosticState, detail: String) {
        self.id = id; self.title = title; self.state = state; self.detail = detail
    }
}

public enum NetworkDiagnostics {
    public static let referenceURL = URL(string: "https://www.apple.com/library/test/success.html")!

    public enum InputError: LocalizedError {
        case invalidURL
        public var errorDescription: String? {
            "Enter a complete http:// or https:// website address without a username, password, or control characters."
        }
    }

    public static func validatedURL(_ input: String) throws -> URL {
        guard !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !(input.removingPercentEncoding ?? input).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: input.trimmingCharacters(in: .whitespaces)),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url else { throw InputError.invalidURL }
        return url
    }

    public static func run(url: URL, includeReference: Bool,
                           update: @escaping @Sendable (NetworkDiagnosticStage) async -> Void) async throws {
        _ = try validatedURL(url.absoluteString)
        try Task.checkCancellation()
        await update(localInterfaces())
        let path = await currentPath()
        try Task.checkCancellation()
        await update(path)
        do {
            var route = try await SystemCommand.run("/sbin/route", arguments: ["-n", "get", "default"], timeout: 3, maximumOutputBytes: 8_192)
            if route.status != 0 {
                route = try await SystemCommand.run("/sbin/route", arguments: ["-n", "get", "-inet6", "default"], timeout: 3, maximumOutputBytes: 8_192)
            }
            let lines = route.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let summary = lines.filter { $0.hasPrefix("gateway:") || $0.hasPrefix("interface:") }.joined(separator: " · ")
            await update(.init(id: "route", title: "Default route", state: route.status == 0 ? .passed : .unavailable,
                               detail: route.status == 0 ? (summary.isEmpty ? "A default route is available." : summary) : "No default route was reported. Specific destinations may still be reachable."))
        } catch is CancellationError { throw CancellationError() }
        catch { await update(.init(id: "route", title: "Default route", state: .unavailable, detail: "The route check could not finish: \(error.localizedDescription)")) }
        try Task.checkCancellation()
        let host = (url.host(percentEncoded: false) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let dns = await DNSLookup.resolve(host: host, timeout: 5)
        try Task.checkCancellation()
        await update(.init(id: "dns", title: "Website DNS", state: dns.state, detail: dns.detail))
        await update(await probe(url: url, reference: false))
        try Task.checkCancellation()
        if includeReference { await update(await probe(url: referenceURL, reference: true)) }
        try Task.checkCancellation()
    }

    public static func responseStage(status: Int, reference: Bool, redirected: Bool) -> NetworkDiagnosticStage {
        let id = reference ? "internet" : "website"
        let title = reference ? "Apple connection reference" : "Website response"
        if reference && (redirected || status == 511) {
            return .init(id: id, title: title, state: .attention, detail: "The reference returned HTTP \(status). A sign-in page or network interception is possible; this alone does not prove a captive portal. Redirects were not followed.")
        }
        let success = (200...399).contains(status)
        return .init(id: id, title: title, state: success ? .passed : .attention,
                     detail: "The server responded with HTTP \(status). " + (success ? (redirected ? "The site redirects requests; the redirect was not followed." : "The connection reached this server.") : "The server is reachable, but it rejected or could not complete this request. Some sites reject HEAD checks."))
    }

    public static func transportStage(code: URLError.Code, reference: Bool) -> NetworkDiagnosticStage {
        let detail: String
        switch code {
        case .cannotFindHost, .dnsLookupFailed: detail = "The system could not resolve the server name. Check the address and DNS availability."
        case .notConnectedToInternet, .networkConnectionLost: detail = "The connection is unavailable or was interrupted. This does not identify whether Wi-Fi, a VPN, or the upstream network caused it."
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
            detail = "TLS verification failed. The server certificate, device clock, or network interception may be involved. Certificate checks remain enabled."
        case .timedOut: detail = "The server did not respond within the diagnostic deadline. A timeout alone does not identify the cause."
        case .cancelled: detail = "The request was cancelled."
        default: detail = "The connection failed (URL error \(code.rawValue)). The available evidence does not identify the cause."
        }
        return .init(id: reference ? "internet" : "website", title: reference ? "Apple connection reference" : "Website response", state: .attention, detail: detail)
    }

    private static func localInterfaces() -> NetworkDiagnosticStage {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return .init(id: "local", title: "Local interfaces", state: .unavailable, detail: "macOS did not return interface information.") }
        defer { freeifaddrs(head) }
        var names = Set<String>()
        var cursor = head
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let flags = item.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = item.pointee.ifa_addr,
                  [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            names.insert(String(cString: item.pointee.ifa_name))
        }
        return .init(id: "local", title: "Local interfaces", state: names.isEmpty ? .attention : .passed,
                     detail: names.isEmpty ? "No active non-loopback interface has an IP address." : "Interfaces with an IP address: \(names.sorted().joined(separator: ", ")). An address alone does not prove internet access.")
    }

    private static func currentPath() async -> NetworkDiagnosticStage {
        let gate = OneShot<NetworkDiagnosticStage>()
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.andrew.mactools.network.path")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                monitor.pathUpdateHandler = { path in
                    let available = path.status == .satisfied
                    gate.finish(.init(id: "path", title: "System connectivity", state: available ? .passed : .attention,
                                      detail: available ? "macOS reports an available network path. Website and DNS checks below verify more." : "macOS does not currently report a usable network path."))
                    monitor.cancel()
                }
                monitor.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 2) {
                    gate.finish(.init(id: "path", title: "System connectivity", state: .unavailable, detail: "The system path check did not report in time."))
                    monitor.cancel()
                }
            }
        } onCancel: {
            monitor.cancel()
            gate.finish(.init(id: "path", title: "System connectivity", state: .unavailable, detail: "Check cancelled."))
        }
    }

    private static func probe(url: URL, reference: Bool) async -> NetworkDiagnosticStage {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        do {
            // Read headers only. Invalidate immediately, even if a server ignores HEAD and sends a body.
            let (_, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                return .init(id: reference ? "internet" : "website", title: "Server response", state: .unavailable, detail: "The server did not return an HTTP response.")
            }
            return responseStage(status: response.statusCode, reference: reference,
                                 redirected: [300, 301, 302, 303, 305, 307, 308].contains(response.statusCode))
        } catch {
            return transportStage(code: (error as? URLError)?.code ?? .unknown, reference: reference)
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// A timeout/cancellation can win before continuation installation or a resolver result.
private final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var result: Value?
    private var completed = false
    func install(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if completed, let result { lock.unlock(); continuation.resume(returning: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ value: Value) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true; result = value
        let pending = continuation; continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

private enum DNSLookup {
    struct Result: Sendable { let state: NetworkDiagnosticState; let detail: String }
    private final class Worker: @unchecked Sendable {
        let lock = NSLock()
        var busy = false
        func reserve() -> Bool { lock.lock(); defer { lock.unlock() }; guard !busy else { return false }; busy = true; return true }
        func release() { lock.lock(); busy = false; lock.unlock() }
    }
    private static let worker = Worker()

    static func resolve(host: String, timeout: TimeInterval) async -> Result {
        // getaddrinfo has no safe cancellation API on macOS. Bound the caller's wait and
        // permit only one outstanding native lookup, even if a system resolver stalls.
        guard worker.reserve() else { return .init(state: .unavailable, detail: "An earlier system DNS lookup is still finishing. Try again shortly.") }
        let gate = OneShot<Result>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                DispatchQueue.global(qos: .utility).async {
                    defer { worker.release() }
                    var addresses: UnsafeMutablePointer<addrinfo>?
                    var hints = addrinfo()
                    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
                    let status = getaddrinfo(host, nil, &hints, &addresses)
                    if let addresses { freeaddrinfo(addresses) }
                    gate.finish(.init(state: status == 0 ? .passed : .attention, detail: status == 0 ? "The system resolver found an address for \(host)." : "The system resolver could not resolve \(host): \(String(cString: gai_strerror(status)))."))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    gate.finish(.init(state: .unavailable, detail: "DNS did not finish within \(Int(timeout)) seconds. The system lookup may still be finishing in the background."))
                }
            }
        } onCancel: { gate.finish(.init(state: .unavailable, detail: "DNS check cancelled.")) }
    }
}
