/// Test doubles for the end-to-end tunnel harness.
///
/// They live outside `tool/e2e_tunnel.dart` so that diagnostics
/// (`tool/socks5_probe.dart`) can exercise exactly the same node the harness
/// uses instead of a copy that could drift.
library;

export 'src/mock_api.dart';
export 'src/socks5_node.dart';
