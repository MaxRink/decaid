import 'package:clock/clock.dart';

const _mask = '***';

final _authorizationValue = RegExp(
  r'''(authorization["']?\s*[:=]\s*["']?(?:basic|bearer)\s+)[A-Za-z0-9._~+/=-]+''',
  caseSensitive: false,
);
final _visualizerToken = RegExp(r'\bvzu_[A-Za-z0-9_-]+');
final _passwordPair = RegExp(
  r'("password"\s*:\s*)"(?:[^"\\]|\\.)*"',
  caseSensitive: false,
);
final _lineBreak = RegExp(r'\r\n|\r|\n');

String redactPluginLog(String message, Iterable<String> secrets) {
  var redacted = message;
  final sorted = secrets.where((secret) => secret.length >= 4).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final secret in sorted) {
    redacted = redacted.replaceAll(secret, _mask);
  }
  return redacted
      .replaceAllMapped(_authorizationValue, (m) => '${m[1]}$_mask')
      .replaceAll(_visualizerToken, _mask)
      .replaceAllMapped(_passwordPair, (m) => '${m[1]}"$_mask"')
      .replaceAll(_lineBreak, r'\n');
}

class PluginLogLimiter {
  PluginLogLimiter({this.limit = 60, this.window = const Duration(minutes: 1)});

  final int limit;
  final Duration window;
  DateTime? _windowStart;
  int _written = 0;
  int _suppressed = 0;

  ({bool write, int suppressed}) admit() {
    final now = clock.now();
    var rolledSuppressed = 0;
    final start = _windowStart;
    if (start == null || now.difference(start) >= window) {
      rolledSuppressed = drain();
      _windowStart = now;
      _written = 0;
    }
    if (_written < limit) {
      _written++;
      return (write: true, suppressed: rolledSuppressed);
    }
    _suppressed++;
    return (write: false, suppressed: rolledSuppressed);
  }

  int drain() {
    final suppressed = _suppressed;
    _suppressed = 0;
    return suppressed;
  }
}
