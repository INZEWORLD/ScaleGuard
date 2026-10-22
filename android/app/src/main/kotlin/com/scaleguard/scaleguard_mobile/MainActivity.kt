package com.scaleguard.scaleguard_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.follow.clashx.plugins.ServicePlugin

class MainActivity : FlutterActivity() {
	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		// The Xray/VLESS widget bridge kept for compatibility with older builds.
		flutterEngine.plugins.add(ServicePlugin())
		// The cross-platform core bridge: the Dart side talks to this one on every
		// platform (Android here, mihomo.exe on Windows, the Network Extension on
		// Apple), which is what keeps a single UI and a single engine contract.
		flutterEngine.plugins.add(CorePlugin())
		// Self-updater: receives the downloaded APK and opens the system package
		// installer through a FileProvider.
		flutterEngine.plugins.add(UpdatePlugin())
	}
}
