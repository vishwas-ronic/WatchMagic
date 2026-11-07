import Foundation
import WatchMagicKit

/// Watch diagnostic log: JSON lines in
/// `Application Support/WatchMagic/diag.log` (rotated at ~1 MB, one `.1`
/// backup). `Diag.event` only buffers; the file is written every ~2 s on a
/// utility queue (`DiagLog`), so it is safe on the motion queue.
/// Never pass the HA token (DiagLog also drops token-like keys).
enum Diag {
    static let directory: URL = {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return support.appendingPathComponent("WatchMagic", isDirectory: true)
    }()

    static let shared: DiagLog = {
        let log = DiagLog(url: directory.appendingPathComponent("diag.log"))
        log.startAutoFlush(interval: 2)
        return log
    }()

    /// Persistent folder for traces waiting to be transferred to the phone
    /// (the temporary directory may be purged while a transfer is pending).
    static let outbox: URL = directory.appendingPathComponent("Outbox", isDirectory: true)

    static func event(_ ev: String, _ fields: [String: Any?] = [:]) {
        shared.log(ev, fields)
    }

    /// error / URLError code / description, for HA failures.
    static func errorFields(_ error: Error) -> [String: Any?] {
        let ns = error as NSError
        var f: [String: Any?] = [
            "error": HAError.from(error).errorDescription,
            "errDomain": ns.domain,
            "errCode": ns.code,
            "errDesc": ns.localizedDescription,
        ]
        if case .unreachable(let detail) = error as? HAError { f["errDetail"] = detail }
        if let u = error as? URLError, let failing = u.failingURL { f["failingURL"] = failing.absoluteString }
        return f
    }

    /// Resolves `host` with getaddrinfo (numeric addresses, e.g. fe80::… for
    /// a link-local mDNS answer). Blocking: call off the main thread.
    static func resolve(host: String) -> (addresses: [String], error: String?) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &res)
        guard rc == 0 else { return ([], "getaddrinfo \(rc): \(String(cString: gai_strerror(rc)))") }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var p = res
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: buf)
                if !out.contains(s) { out.append(s) }
            }
            p = ai.pointee.ai_next
        }
        return (out, nil)
    }
}
