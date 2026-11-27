import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

const allowedHostNamesSetting = 'allowedHostNames';

const maxAllowedHostNames = 32;

const unadmittedHostError =
    'This device only answers its IP address, localhost, .local names and '
    'the host names in the allowedHostNames setting';

final _log = Logger('RequestHost');

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

RequestHost? directRequestHost(Request request) =>
    carriesForwardingHeaders(request) ? null : rawRequestHost(request);

RequestHost? rawRequestHost(Request request) {
  final hostHeader = request.headers['host'];
  if (hostHeader != null) return parseHostHeader(hostHeader);
  if (carriesForwardingHeaders(request)) return null;
  final uri = request.requestedUri;
  return uri.host.isEmpty
      ? null
      : RequestHost(uri.host, uri.hasPort ? uri.port : null);
}

/// Whether [host] (a parsed `Host` value) is a name a DNS-rebinding page
/// cannot own: a numeric address, a loopback name, an mDNS `.local` name or
/// one of [allowedNames] (normalized with [normalizeHostName]).
bool isAdmittedHost(String host, Set<String> allowedNames) {
  final address = InternetAddress.tryParse(host);
  if (address != null) {
    final normalized = _normalizedAddress(address);
    return normalized != null &&
        !normalized.rawAddress.every((byte) => byte == 0);
  }
  final name = normalizeHostName(host);
  if (name == null) return false;
  return name == 'localhost' ||
      name.endsWith('.localhost') ||
      name.endsWith('.local') ||
      allowedNames.contains(name);
}

/// Lower-cases a DNS name and drops one trailing dot; null for anything that
/// is not dot-separated DNS labels or that is a numeric address.
String? normalizeHostName(String name) {
  final trimmed = name.trim().toLowerCase();
  if (InternetAddress.tryParse(trimmed) != null) return null;
  if (trimmed.length > 253 || !_regName.hasMatch(trimmed)) return null;
  return trimmed.endsWith('.')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

/// The configured names plus this device's own host name, normalized.
Set<String> hostNameAllowlist(Iterable<String> configured) => {
  for (final name in [...configured, ?_localHostname()])
    ?normalizeHostName(name),
};

String? _localHostname() {
  try {
    return Platform.localHostname;
  } catch (_) {
    return null;
  }
}

/// Refuses every request whose raw `Host` (forwarding headers ignored) is not
/// [isAdmittedHost]. A request without a `Host` header is judged by the
/// address the listener reports, which is the unspecified address on a
/// wildcard bind and therefore refused.
Middleware admittedHostMiddleware(Set<String> Function() allowedNames) {
  return (Handler inner) {
    return (Request request) {
      final host = rawRequestHost(request);
      if (host != null && isAdmittedHost(host.host, allowedNames())) {
        return inner(request);
      }
      _log.warning(
        '${request.method} /${request.url.path} refused (403): the Host is '
        'not an address, a local name or an allowed host name',
      );
      return Response(
        403,
        body: jsonEncode({'error': unadmittedHostError}),
        headers: const {
          'content-type': 'application/json',
          'cache-control': 'no-store',
        },
      );
    };
  };
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

/// Picks the device address that shares the longest prefix with [peer], as a
/// stand-in for "the address on the peer's subnet".
// ponytail: dart:io exposes no netmasks or local socket address, so the subnet
// is approximated by a shared prefix of at least /16 (IPv4) or /64 (IPv6).
String? onLinkPageHost({
  required InternetAddress peer,
  required Iterable<String> addresses,
}) {
  final normalizedPeer = _normalizedAddress(peer);
  if (normalizedPeer == null || normalizedPeer.isLoopback) return null;
  final minimum = normalizedPeer.type == InternetAddressType.IPv4 ? 16 : 64;
  String? best;
  var bestBits = minimum - 1;
  for (final address in addresses) {
    final parsed = _parsedAddress(address);
    if (parsed == null || !_isCandidate(parsed, normalizedPeer)) continue;
    final bits = _sharedPrefixBits(
      parsed.rawAddress,
      normalizedPeer.rawAddress,
    );
    if (bits > bestBits) {
      best = parsed.address;
      bestBits = bits;
    }
  }
  return best;
}

int _sharedPrefixBits(List<int> a, List<int> b) {
  var bits = 0;
  for (var index = 0; index < a.length; index++) {
    final diff = a[index] ^ b[index];
    if (diff == 0) {
      bits += 8;
      continue;
    }
    var mask = 0x80;
    while (diff & mask == 0) {
      bits++;
      mask >>= 1;
    }
    break;
  }
  return bits;
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
