/// Short, human-readable names for subscription nodes.
///
/// A remark carries three things at once — the flag, the city and the
/// subscription-side index ("🇸🇪 Стокгольм | #2"). The interface needs each of
/// them in a different place: the list shows the flag, the notification has room
/// for the city only.
library;

/// Leading pictographs of a remark: flags, regional indicators and the
/// variation selectors that follow them.
final RegExp _leadingPictographs = RegExp(
  r'^[\s\u{1F30D}-\u{1F77F}\u{1F780}-\u{1F7FF}\u{1F800}-\u{1F8FF}\u{1F900}-\u{1F9FF}\u{1FA00}-\u{1FA6F}\u{1FA70}-\u{1FAFF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}\u{1F1E6}-\u{1F1FF}\u{E0061}-\u{E007F}\u{FEFF}\u{200D}\u{FE0F}]+',
  unicode: true,
  caseSensitive: false,
  dotAll: true,
);

/// Strips the flag from the front of [value], keeping the rest untouched.
String stripLeadingPictographs(String value) {
  final raw = String.fromCharCodes(value.runes.toList());
  return raw.replaceFirst(_leadingPictographs, '').trim();
}

/// The location a node belongs to, without flag, index or subscription noise.
///
/// "🇸🇪 Стокгольм | #2" becomes "Стокгольм": the notification is the place where
/// a long remark is simply cut off, so it gets the part that identifies the
/// server and nothing else.
String locationLabel(String remark) {
  final withoutFlag = stripLeadingPictographs(remark);
  final head = withoutFlag.split(RegExp(r'[|·•]')).first.trim();
  final cleaned = head
      .replaceAll(RegExp(r'#\s*\d+'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s\-_.#]+'), '')
      .replaceAll(RegExp(r'[\s\-_.#]+$'), '')
      .trim();
  if (cleaned.isNotEmpty) return cleaned;
  final fallback = withoutFlag.trim();
  return fallback.isEmpty ? remark.trim() : fallback;
}
