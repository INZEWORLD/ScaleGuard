/// Reading and writing the payload of a QR sign-in code.
///
/// The code carries nothing but a session identifier: it is created on the
/// server, shown by a device, scanned by another, and approved by whichever of
/// the two is signed in. Keeping the payload this bare is what makes a
/// photographed code worthless — it expires in minutes and on its own grants
/// nothing.
library;

/// Recognises a session identifier pasted by hand.
final RegExp _sessionPattern = RegExp(r'^[A-Za-z0-9_-]{20,128}$');

/// Extracts the session identifier from a scanned code.
///
/// Accepts the link the application itself would receive
/// (`scaleguard://qr?session=…`), any other URL that carries a `session`
/// parameter, and a bare identifier typed instead of scanned. Anything else is
/// `null`, which is what keeps a random barcode from being sent to the server.
String? qrSessionIdFromLink(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;

  final uri = Uri.tryParse(value);
  final parameter = uri?.queryParameters['session']?.trim();
  if (parameter != null && parameter.isNotEmpty) {
    return _sessionPattern.hasMatch(parameter) ? parameter : null;
  }

  return _sessionPattern.hasMatch(value) ? value : null;
}
