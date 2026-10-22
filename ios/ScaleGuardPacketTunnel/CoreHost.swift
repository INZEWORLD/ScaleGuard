import Foundation

/// Bridges the packet-tunnel extension to the mihomo core.
///
/// Swift cannot call into Go directly, so the core is built as a static library
/// (`.xcframework`) and reached through a small C shim that the Go side exports —
/// the same shape Hiddify uses for its sing-box core, and the standard way to
/// embed a Go VPN engine on Apple platforms.
///
/// When the shim is not linked (i.e. `docs/apple.md` has not been followed yet),
/// every entry point reports [TunnelStartError.coreUnavailable] instead of
/// failing silently, so the UI can explain exactly what is missing.
final class CoreHost {

    private let configPath: String
    private let controllerPort: Int
    private let secret: String
    private var running = false

    init(configPath: String, controllerPort: Int, secret: String) {
        self.configPath = configPath
        self.controllerPort = controllerPort
        self.secret = secret
    }

    /// Starts the core with the profile on disk.
    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        #if SCALEGUARD_CORE_AVAILABLE
        // `ScaleGuardCoreStart` is exported by the Go shim
        // (ios/ScaleGuardCore/ScaleGuardCore.h). It blocks until the core's
        // RESTful controller accepts connections, which is what makes the Dart
        // side's readiness handshake reliable.
        let outcome = configPath.withCString { path in
            ScaleGuardCoreStart(path, Int32(controllerPort), secret)
        }
        if outcome == 0 {
            running = true
            completion(.success(()))
        } else {
            completion(.failure(TunnelStartError.coreUnavailable))
        }
        #else
        completion(.failure(TunnelStartError.coreUnavailable))
        #endif
    }

    /// Passes the tunnel's file descriptor to the core so it can carry traffic.
    ///
    /// mihomo's `sing-tun` listener accepts an existing descriptor through its
    /// `file-descriptor` option; before that call the core has no way to see the
    /// packets the system routes into the extension.
    func attachTunnelFileDescriptor(_ descriptor: Int32) {
        guard running else { return }
        #if SCALEGUARD_CORE_AVAILABLE
        ScaleGuardCoreAttachTun(descriptor)
        #endif
    }

    func stop() {
        guard running else { return }
        #if SCALEGUARD_CORE_AVAILABLE
        ScaleGuardCoreStop()
        #endif
        running = false
    }

    /// Counters read from the core's own RESTful controller.
    ///
    /// The controller is bound to loopback, so a plain `URLSession` request from
    /// the extension is enough — no shared memory or IPC is involved.
    func readStats() -> [String: Any] {
        guard running else {
            return ["downloadBytes": 0, "uploadBytes": 0, "connections": 0, "uptimeSeconds": 0]
        }
        var result: [String: Any] = [
            "downloadBytes": 0,
            "uploadBytes": 0,
            "connections": 0,
            "uptimeSeconds": 0,
        ]
        // Synchronous within the extension: the timer that calls this runs on a
        // utility queue, so blocking briefly cannot stall the tunnel.
        let semaphore = DispatchSemaphore(value: 0)
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(controllerPort)/connections")!
        )
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard
                let data = data,
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            result["downloadBytes"] = object["downloadTotal"] as? Int ?? 0
            result["uploadBytes"] = object["uploadTotal"] as? Int ?? 0
            result["connections"] = (object["connections"] as? [Any])?.count ?? 0
            result["uptimeSeconds"] = Int(Date().timeIntervalSince1970)
        }.resume()
        _ = semaphore.wait(timeout: .now() + 3)
        return result
    }
}
