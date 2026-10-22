import Flutter
import NetworkExtension
import UIKit

/// The iOS/macOS half of ScaleGuard's cross-platform VPN engine.
///
/// Dart (`lib/core/engines/apple_vpn_engine.dart`) treats Apple platforms the
/// same way it treats Windows and Android: it generates one mihomo profile, hands
/// it to a core, and then drives that core over its RESTful controller. On Apple
/// platforms the core cannot live in the app process — Apple requires traffic to
/// be handled by a **Network Extension** — so this class is a thin controller for
/// a `NEPacketTunnelProvider` that hosts the core:
///
///  * `startCore` stores the generated profile in the shared App Group container,
///    starts the tunnel, and waits for the extension to report its loopback
///    controller address;
///  * `stopCore` tears the tunnel down;
///  * `stats` is answered by the extension over the same App Group channel.
///
/// Build steps, including how to add the extension target, are documented in
/// `docs/apple.md`.
public class ScaleGuardCorePlugin: NSObject, FlutterPlugin {

    /// Must match `apple_vpn_engine.dart`, `CorePlugin.kt` and the Windows
    /// engine's channel name so the Dart contract is identical everywhere.
    private static let channelName = "com.scaleguard.app/core"

    /// Must match the extension target's bundle identifier prefix and the
    /// `com.apple.security.application-groups` entitlement in both targets.
    private static let appGroupIdentifier = "group.com.scaleguard.app"

    /// File inside the App Group where Dart publishes the generated profile.
    private static let configFileName = "config.yaml"

    /// Handshake file the extension writes once its controller is listening.
    private static let readyFileName = "core-ready.json"

    private let tunnelManager = TunnelManager(
        appGroupIdentifier: appGroupIdentifier,
        configFileName: configFileName,
        readyFileName: readyFileName
    )

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(ScaleGuardCorePlugin(), channel: channel)
    }

    public func handle(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        switch call.method {
        case "isSupported":
            // The extension ships with the app; if it is missing, the build
            // steps in docs/apple.md were not completed.
            result(tunnelManager.isExtensionBundled)
        case "requestPermission", "prepareTunnel":
            tunnelManager.prepare { outcome in
                switch outcome {
                case .success(let ready):
                    result(ready)
                case .failure(let error):
                    // A failed profile installation is reported as `false`
                    // rather than an exception: the Dart engine raises a
                    // user-facing message either way, and `false` keeps the
                    // consent flow simple to reason about.
                    NSLog("ScaleGuard: tunnel preparation failed: \(error.localizedDescription)")
                    result(false)
                }
            }
        case "startCore":
            guard
                let arguments = call.arguments as? [String: Any],
                let config = arguments["config"] as? String,
                let controllerUrl = arguments["controllerUrl"] as? String,
                let controllerPort = arguments["controllerPort"] as? Int
            else {
                result(
                    FlutterError(
                        code: "bad_arguments",
                        message: "startCore requires config, controllerUrl and controllerPort",
                        details: nil
                    )
                )
                return
            }
            tunnelManager.start(
                config: config,
                controllerUrl: controllerUrl,
                controllerPort: controllerPort
            ) { outcome in
                switch outcome {
                case .success(let url):
                    result(["controllerUrl": url])
                case .failure(let error):
                    result(
                        FlutterError(
                            code: "core_start_failed",
                            message: error.localizedDescription,
                            details: nil
                        )
                    )
                }
            }
        case "stopCore":
            tunnelManager.stop { result(nil) }
        case "stats":
            result(tunnelManager.readStats())
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

/// Owns the `NETunnelProviderManager` lifecycle.
///
/// Keeping this separate from the Flutter plugin makes the tunnel logic testable
/// on macOS without a Flutter engine, and keeps the plugin itself a pure adapter.
final class TunnelManager {

    struct Stats {
        let downloadBytes: Int
        let uploadBytes: Int
        let connections: Int
        let uptimeSeconds: Int
    }

    private let appGroupIdentifier: String
    private let configFileName: String
    private let readyFileName: String
    private var manager: NETunnelProviderManager?

    init(appGroupIdentifier: String, configFileName: String, readyFileName: String) {
        self.appGroupIdentifier = appGroupIdentifier
        self.configFileName = configFileName
        self.readyFileName = readyFileName
    }

    /// True when the packet-tunnel extension is embedded in the bundle.
    var isExtensionBundled: Bool {
        guard let pluginsUrl = Bundle.main.builtInPlugInsURL else { return false }
        let extensionUrl = pluginsUrl.appendingPathComponent("ScaleGuardPacketTunnel.appex")
        return FileManager.default.fileExists(atPath: extensionUrl.path)
    }

    /// Installs (or repairs) the VPN profile so the system can show its consent
    /// prompt.
    func prepare(completion: @escaping (Result<Bool, Error>) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            let manager = managers?.first ?? NETunnelProviderManager()
            let configuration = NETunnelProviderProtocol()
            // `providerBundleIdentifier` must be the extension's bundle id.
            configuration.providerBundleIdentifier = "com.scaleguard.app.packet-tunnel"
            configuration.serverAddress = "ScaleGuard"
            // The extension reads the profile from the shared container, so the
            // VPN profile itself carries no secrets.
            configuration.providerConfiguration = [
                "appGroupIdentifier": self.appGroupIdentifier,
                "configFileName": self.configFileName,
            ]
            manager.protocolConfiguration = configuration
            manager.localizedDescription = "ScaleGuard"
            manager.isEnabled = true
            manager.saveToPreferences { saveError in
                if let saveError = saveError {
                    completion(.failure(saveError))
                    return
                }
                // Reloading is required before the profile can be started: the
                // manager returned by `saveToPreferences` is a stale copy.
                manager.loadFromPreferences { loadError in
                    if let loadError = loadError {
                        completion(.failure(loadError))
                        return
                    }
                    self.manager = manager
                    completion(.success(true))
                }
            }
        }
    }

    /// Writes the profile into the App Group and brings the tunnel up.
    func start(
        config: String,
        controllerUrl: String,
        controllerPort: Int,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        do {
            try writeSharedFile(name: configFileName, contents: config)
            // A stale readiness marker would make Dart believe a dead controller
            // is reachable, so it is cleared before every start.
            try? removeSharedFile(name: readyFileName)
        } catch {
            completion(.failure(error))
            return
        }

        prepare { preparation in
            switch preparation {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                guard let manager = self.manager,
                      let session = manager.connection as? NETunnelProviderSession else {
                    completion(.failure(TunnelError.notPrepared))
                    return
                }
                let options: [String: NSObject] = [
                    "controllerPort": NSNumber(value: controllerPort),
                    "controllerUrl": controllerUrl as NSObject,
                ]
                do {
                    try session.startTunnel(options: options)
                } catch {
                    completion(.failure(error))
                    return
                }
                // The extension publishes its controller address once the core
                // is listening; block the Dart call until then so the engine's
                // `waitUntilReady` sees a live endpoint.
                self.waitForReady(controllerUrl: controllerUrl, completion: completion)
            }
        }
    }

    func stop(completion: @escaping () -> Void) {
        guard let manager = manager else {
            completion()
            return
        }
        manager.connection.stopVPNTunnel()
        completion()
    }

    /// Counters published by the extension, or zeroes when it is not running.
    func readStats() -> [String: Any] {
        guard
            let data = try? readSharedFile(name: "core-stats.json"),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [
                "downloadBytes": 0,
                "uploadBytes": 0,
                "connections": 0,
                "uptimeSeconds": 0,
            ]
        }
        return object
    }

    // MARK: - App Group helpers

    private var containerUrl: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    private func writeSharedFile(name: String, contents: String) throws {
        guard let containerUrl = containerUrl else { throw TunnelError.missingAppGroup }
        try contents.write(
            to: containerUrl.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    private func readSharedFile(name: String) throws -> Data {
        guard let containerUrl = containerUrl else { throw TunnelError.missingAppGroup }
        return try Data(contentsOf: containerUrl.appendingPathComponent(name))
    }

    private func removeSharedFile(name: String) throws {
        guard let containerUrl = containerUrl else { throw TunnelError.missingAppGroup }
        try FileManager.default.removeItem(
            at: containerUrl.appendingPathComponent(name)
        )
    }

    /// Polls the readiness marker the extension writes after the core starts.
    private func waitForReady(
        controllerUrl: String,
        completion: @escaping (Result<String, Error>) -> Void,
        attempt: Int = 0
    ) {
        if let data = try? readSharedFile(name: readyFileName),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["ready"] as? Bool == true {
            completion(.success(object["controllerUrl"] as? String ?? controllerUrl))
            return
        }
        // 20 seconds mirrors the other platforms' controller timeout.
        if attempt >= 40 {
            completion(.failure(TunnelError.coreDidNotStart))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.waitForReady(
                controllerUrl: controllerUrl,
                completion: completion,
                attempt: attempt + 1
            )
        }
    }
}

enum TunnelError: LocalizedError {
    case missingAppGroup
    case notPrepared
    case coreDidNotStart

    var errorDescription: String? {
        switch self {
        case .missingAppGroup:
            return "Общий контейнер App Group недоступен. Проверьте entitlement "
                + "com.apple.security.application-groups в обоих таргетах."
        case .notPrepared:
            return "VPN-профиль не установлен. Разрешите добавление конфигурации VPN."
        case .coreDidNotStart:
            return "Ядро mihomo не запустилось в расширении за 20 секунд — "
                + "см. docs/apple.md, раздел «Диагностика»."
        }
    }
}
