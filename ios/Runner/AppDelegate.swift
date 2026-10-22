import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // ScaleGuard's own bridge to the packet-tunnel extension. It is registered
    // explicitly because it is application code, not a pub.dev plugin.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ScaleGuardCorePlugin") {
      ScaleGuardCorePlugin.register(with: registrar)
    }
  }
}
