import NetworkExtension

/// The Network Extension that hosts the mihomo core on iOS and macOS.
///
/// Apple does not let an application create a tunnel itself, so the core runs
/// here, in a separate process with its own memory budget, while the Flutter UI
/// talks to the core's RESTful controller on loopback. Everything the Dart engine
/// needs — the generated profile, the controller port, the readiness handshake —
/// travels through the shared App Group container.
///
/// **Memory is the binding constraint on iOS**: the system kills a packet-tunnel
/// provider that exceeds its budget (community reports put the ceiling in the
/// 15–50 MB range). This provider therefore hands the profile to the core
/// without copying it through Swift structures, keeps no geo databases, and
/// publishes only small JSON counters. See `docs/apple.md`.
class PacketTunnelProvider: NEPacketTunnelProvider {

    /// Must match `ScaleGuardCorePlugin.appGroupIdentifier`.
    private let appGroupIdentifier = "group.com.scaleguard.app"

    private var core: CoreHost?
    private var statsTimer: DispatchSourceTimer?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let containerUrl = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            completionHandler(TunnelStartError.missingAppGroup)
            return
        }

        let configUrl = containerUrl.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: configUrl.path) else {
            completionHandler(TunnelStartError.missingProfile)
            return
        }

        let controllerPort = (options?["controllerPort"] as? NSNumber)?.intValue ?? 9090
        let controllerUrl = options?["controllerUrl"] as? String
            ?? "http://127.0.0.1:\(controllerPort)"

        // The tunnel interface itself is configured before the core starts so the
        // core's TUN listener can attach to the file descriptor the system gives
        // us here.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1500

        let ipv4 = NEIPv4Settings(addresses: ["198.19.0.1"], subnetMasks: ["255.255.255.0"])
        // Everything is routed into the tunnel; the core's own rules decide what
        // goes direct (the profile lists the private ranges).
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["198.19.0.2"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                completionHandler(error)
                return
            }
            self.startCore(
                containerUrl: containerUrl,
                configUrl: configUrl,
                controllerUrl: controllerUrl,
                controllerPort: controllerPort,
                completionHandler: completionHandler
            )
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        statsTimer?.cancel()
        statsTimer = nil
        core?.stop()
        core = nil
        // Remove the readiness marker so a later start cannot mistake a dead
        // controller for a live one.
        if let containerUrl = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            try? FileManager.default.removeItem(
                at: containerUrl.appendingPathComponent("core-ready.json")
            )
        }
        completionHandler()
    }

    // MARK: - Core lifecycle

    private func startCore(
        containerUrl: URL,
        configUrl: URL,
        controllerUrl: String,
        controllerPort: Int,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let host = CoreHost(
            configPath: configUrl.path,
            controllerPort: controllerPort,
            // The profile carries the secret; the core is only reachable on
            // loopback, and the extension is the only process that may read it.
            secret: readSecret(from: configUrl)
        )
        core = host

        host.start { result in
            switch result {
            case .failure(let error):
                completionHandler(error)
            case .success:
                // Publish the handshake the app process waits for, then hand the
                // tunnel's file descriptor to the core so it can carry traffic.
                self.publishReady(containerUrl: containerUrl, controllerUrl: controllerUrl)
                self.attachTunnelFileDescriptor(to: host)
                self.startStatsPublishing(containerUrl: containerUrl, host: host)
                completionHandler(nil)
            }
        }
    }

    /// Gives the core the tunnel's file descriptor.
    ///
    /// `sing-tun` (the TUN implementation mihomo uses) accepts a pre-existing
    /// descriptor through its `file-descriptor` option, which is exactly the
    /// mechanism a Network Extension needs: the system owns the interface and the
    /// provider passes its descriptor on.
    private func attachTunnelFileDescriptor(to host: CoreHost) {
        // `packetFlow` exposes the utun descriptor through its file handle on
        // current iOS versions.
        let selector = NSSelectorFromString("socket")
        guard packetFlow.responds(to: selector) else {
            NSLog("ScaleGuard: packetFlow does not expose a socket; the core will use its own TUN")
            return
        }
        // Deliberately reflective: the accessor is private API surface and its
        // availability differs between iOS releases, so a missing selector must
        // not crash the extension.
        if let unmanaged = packetFlow.perform(selector) {
            let fd = unmanaged.toOpaque()
            host.attachTunnelFileDescriptor(Int(bitPattern: fd))
        }
    }

    private func publishReady(containerUrl: URL, controllerUrl: String) {
        let payload: [String: Any] = ["ready": true, "controllerUrl": controllerUrl]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: containerUrl.appendingPathComponent("core-ready.json"))
    }

    /// Publishes counters for the UI once per second.
    ///
    /// The Dart side polls the core's controller directly when it can reach it;
    /// this file is the fallback for when the extension and the app are in
    /// different processes and the controller is not reachable from the app.
    private func startStatsPublishing(containerUrl: URL, host: CoreHost) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self = self, let host = self.core else { return }
            let stats = host.readStats()
            guard let data = try? JSONSerialization.data(withJSONObject: stats) else { return }
            try? data.write(to: containerUrl.appendingPathComponent("core-stats.json"))
        }
        timer.resume()
        statsTimer = timer
    }

    private func readSecret(from configUrl: URL) -> String {
        guard
            let contents = try? String(contentsOf: configUrl, encoding: .utf8),
            let range = contents.range(of: #"secret:\s*"([^"]+)""#, options: .regularExpression)
        else {
            return ""
        }
        let match = String(contents[range])
        return match
            .replacingOccurrences(of: "secret:", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
    }
}

enum TunnelStartError: LocalizedError {
    case missingAppGroup
    case missingProfile
    case coreUnavailable

    var errorDescription: String? {
        switch self {
        case .missingAppGroup:
            return "App Group group.com.scaleguard.app недоступен в расширении."
        case .missingProfile:
            return "Профиль mihomo не найден в общем контейнере."
        case .coreUnavailable:
            return "Ядро mihomo не собрано для iOS. См. docs/apple.md."
        }
    }
}
