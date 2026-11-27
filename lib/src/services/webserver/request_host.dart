import 'dart:io';

import 'package:shelf/shelf.dart';

final class RequestHost {
  const RequestHost(this.host, this.port);

  final String host;
  final int? port;
}

RequestHost? parseHostHeader(String? hostHeader) {
  if (hostHeader == null) return null;
  final value = hostHeader.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('[')) {
    final end = value.indexOf(']');
    if (end < 0) return null;
    final literal = value.substring(1, end);
    if (!_isIpv6Literal(literal)) return null;
    final port = _hostPort(value.substring(end + 1));
    return port == null ? null : RequestHost(literal, port.value);
  }
  final colon = value.indexOf(':');
  if (colon < 0) {
    return _regName.hasMatch(value) ? RequestHost(value, null) : null;
  }
  final port = _hostPort(value.substring(colon));
  final host = value.substring(0, colon);
  return port != null && _regName.hasMatch(host)
      ? RequestHost(host, port.value)
      : null;
}

bool carriesForwardingHeaders(Request request) =>
    request.headers.keys.any((name) {
      final lower = name.toLowerCase();
      return lower == 'forwarded' || lower.startsWith('x-forwarded-');
    });

RequestHost? directRequestHost(Request request) {
  if (carriesForwardingHeaders(request)) return null;
  final hostHeader = request.headers['host'];
  if (hostHeader != null) return parseHostHeader(hostHeader);
  final uri = request.requestedUri;
  return uri.host.isEmpty
      ? null
      : RequestHost(uri.host, uri.hasPort ? uri.port : null);
}

String? canonicalPageHost({
  required InternetAddress peer,
  required Set<String> addresses,
  String? boundAddress,
}) {
  final normalizedPeer = _normalizedAddress(peer);
  if (normalizedPeer == null) return null;
  if (normalizedPeer.isLoopback) {
    return normalizedPeer.type == InternetAddressType.IPv6
        ? '::1'
        : '127.0.0.1';
  }
  final bound = boundAddress == null ? null : _parsedAddress(boundAddress);
  if (bound != null && _isCandidate(bound, normalizedPeer)) {
    return bound.address;
  }
  final candidates = <String>{};
  final seen = <String>{};
  for (final address in addresses) {
    final parsed = _parsedAddress(address);
    if (parsed == null || !_isCandidate(parsed, normalizedPeer)) continue;
    if (!seen.add(_addressKey(parsed))) continue;
    candidates.add(parsed.address);
  }
  return candidates.length == 1 ? candidates.single : null;
}

final _portSuffix = RegExp(r'^:(\d{1,5})$');
const _hostLabel = '[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?';
final _regName = RegExp('^$_hostLabel(?:\\.$_hostLabel)*\\.?\$');

bool _isIpv6Literal(String literal) {
  if (literal.contains('%')) return false;
  return InternetAddress.tryParse(literal)?.type == InternetAddressType.IPv6;
}

({int? value})? _hostPort(String suffix) {
  if (suffix.isEmpty) return (value: null);
  final match = _portSuffix.firstMatch(suffix);
  if (match == null) return null;
  final port = int.parse(match.group(1)!);
  return port >= 1 && port <= 65535 ? (value: port) : null;
}

bool _isCandidate(InternetAddress address, InternetAddress peer) =>
    address.type == peer.type && !address.isLoopback && _isDestination(address);

String _addressKey(InternetAddress address) =>
    '${address.type.name}:${address.rawAddress.join('.')}';

InternetAddress? _parsedAddress(String text) {
  final parsed = InternetAddress.tryParse(text);
  return parsed == null ? null : _normalizedAddress(parsed);
}

InternetAddress? _normalizedAddress(InternetAddress address) {
  if (address.address.contains('%')) return null;
  final raw = address.rawAddress;
  if (raw.length != 16) return InternetAddress.fromRawAddress(raw);
  var mapped = raw[10] == 0xff && raw[11] == 0xff;
  for (var index = 0; index < 10 && mapped; index++) {
    if (raw[index] != 0) mapped = false;
  }
  if (mapped) return InternetAddress.fromRawAddress(raw.sublist(12));
  return InternetAddress.fromRawAddress(raw, type: InternetAddressType.IPv6);
}

bool _isDestination(InternetAddress address) {
  final raw = address.rawAddress;
  if (raw.every((byte) => byte == 0)) return false;
  if (raw.length == 4) {
    if ((raw[0] & 0xf0) == 0xe0) return false;
    return !raw.every((byte) => byte == 0xff);
  }
  if (raw[0] == 0xff) return false;
  return !(raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80);
}
