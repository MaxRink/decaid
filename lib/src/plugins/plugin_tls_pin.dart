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

class TlsPinMismatchException implements Exception {
  const TlsPinMismatchException(this.peerSha256, this.cause);

  static const code = 'tls_pin_mismatch';

  final String peerSha256;
  final Object cause;

  @override
  String toString() =>
      '$cause ($code: presented certificate SHA-256 $peerSha256)';
}

class TlsPinCheck {
  TlsPinCheck(this.pin);

  final String pin;
  String? _presentedSha256;

  bool accepts(X509Certificate certificate) {
    final digest = sha256.convert(certificate.der).toString();
    _presentedSha256 = digest;
    return digest == pin;
  }

  Future<T> guard<T>(Future<T> Function() connect) async {
    try {
      return await connect();
    } on HandshakeException catch (error) {
      final presented = _presentedSha256;
      if (presented == null || presented == pin) rethrow;
      throw TlsPinMismatchException(presented, error);
    }
  }
}

HttpClient pinnedHttpClient(TlsPinCheck check) =>
    HttpClient(context: SecurityContext(withTrustedRoots: true))
      ..badCertificateCallback = (certificate, _, _) =>
          check.accepts(certificate);
