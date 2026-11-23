import 'dart:io';

import 'package:crypto/crypto.dart';

const tlsPinOption = 'tlsPinSha256';

final _pinPattern = RegExp(r'^[0-9a-f]{64}$');

String? parseTlsPinSha256(Object? raw) {
  if (raw == null) return null;
  final normalized = raw is String ? raw.replaceAll(':', '').toLowerCase() : '';
  if (!_pinPattern.hasMatch(normalized)) {
    throw const FormatException(
      '$tlsPinOption must be the SHA-256 of the certificate as 64 hex digits',
    );
  }
  return normalized;
}

void requireTlsScheme(String? pin, bool isTls, String expected) {
  if (pin != null && !isTls) {
    throw FormatException('$tlsPinOption requires $expected');
  }
}

bool certificateMatchesPin(X509Certificate certificate, String pin) =>
    sha256.convert(certificate.der).toString() == pin;

HttpClient pinnedHttpClient(String pin) =>
    HttpClient(context: SecurityContext(withTrustedRoots: true))
      ..badCertificateCallback = (certificate, _, _) =>
          certificateMatchesPin(certificate, pin);
