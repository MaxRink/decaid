import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

const maxPluginDiscoveryResults = 32;
const defaultPluginDiscoveryTimeout = Duration(seconds: 3);
const minPluginDiscoveryTimeout = Duration(milliseconds: 250);
const maxPluginDiscoveryTimeout = Duration(seconds: 10);

final _serviceTypePattern = RegExp(
  r'^_[A-Za-z0-9][A-Za-z0-9-]{0,62}\._(tcp|udp)$',
);

class PluginMdnsDeclaration {
  const PluginMdnsDeclaration({
    required this.serviceType,
    required this.namePrefix,
  });

  final String serviceType;
  final String namePrefix;

  Map<String, dynamic> toJson() => {
    'type': serviceType,
    'namePrefix': namePrefix,
  };
}

List<PluginMdnsDeclaration> parsePluginDiscovery(dynamic json) {
  if (json == null) return const [];
  if (json is! Map) {
    throw const FormatException('Plugin discovery must be an object');
  }
  final mdns = json['mdns'];
  if (mdns == null) return const [];
  if (mdns is! List || mdns.isEmpty || mdns.length > 8) {
    throw const FormatException('Plugin mdns discovery must be 1-8 entries');
  }
  return List.unmodifiable(
    mdns.map((entry) {
      if (entry is! Map ||
          entry.length != 2 ||
          entry['type'] is! String ||
          !_serviceTypePattern.hasMatch(entry['type'] as String) ||
          entry['namePrefix'] is! String ||
          (entry['namePrefix'] as String).trim().isEmpty ||
          (entry['namePrefix'] as String).length > 63) {
        throw const FormatException('Invalid plugin mdns discovery entry');
      }
      return PluginMdnsDeclaration(
        serviceType: entry['type'] as String,
        namePrefix: entry['namePrefix'] as String,
      );
    }),
  );
}

typedef PluginDiscoveryRequest = ({
  String serviceType,
  List<String> namePrefixes,
  Duration timeout,
});

PluginDiscoveryRequest resolvePluginDiscoveryRequest(
  List<PluginMdnsDeclaration> declared,
  Object? options,
) {
  if (options is! Map) {
    throw const FormatException('discovery.browse needs an options object');
  }
  final serviceType = options['serviceType'];
  final prefixes = declared
      .where((entry) => entry.serviceType == serviceType)
      .map((entry) => entry.namePrefix);
  if (serviceType is! String || prefixes.isEmpty) {
    throw const FormatException(
      'serviceType is not declared in the manifest discovery.mdns',
    );
  }
  final requested = options['namePrefix'];
  if (requested != null && requested is! String) {
    throw const FormatException('namePrefix must be a string');
  }
  if (requested is String &&
      !prefixes.any((prefix) => _startsWithIgnoreCase(requested, prefix))) {
    throw const FormatException(
      'namePrefix must start with a declared namePrefix for this serviceType',
    );
  }
  final timeoutMs = options['timeoutMs'];
  if (timeoutMs != null && timeoutMs is! num) {
    throw const FormatException('timeoutMs must be a number');
  }
  final timeout = timeoutMs == null
      ? defaultPluginDiscoveryTimeout
      : Duration(
          milliseconds: (timeoutMs as num).round().clamp(
            minPluginDiscoveryTimeout.inMilliseconds,
            maxPluginDiscoveryTimeout.inMilliseconds,
          ),
        );
  return (
    serviceType: serviceType,
    namePrefixes: requested is String ? [requested] : prefixes.toList(),
    timeout: timeout,
  );
}

bool pluginDiscoveryNameMatches(String name, List<String> namePrefixes) =>
    namePrefixes.any((prefix) => _startsWithIgnoreCase(name, prefix));

bool _startsWithIgnoreCase(String value, String prefix) =>
    value.toLowerCase().startsWith(prefix.toLowerCase());

class PluginMdnsService {
  const PluginMdnsService({
    required this.name,
    required this.host,
    required this.port,
    this.addresses = const [],
    this.txt = const {},
  });

  factory PluginMdnsService.fromBonsoir(BonsoirService service) {
    final ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
    final addresses = [
      ...service.hostAddresses.where(ipv4.hasMatch),
      ...service.hostAddresses.where((address) => !ipv4.hasMatch(address)),
    ];
    final hostname = service.hostname;
    return PluginMdnsService(
      name: service.name,
      host: hostname != null && hostname.isNotEmpty
          ? (hostname.endsWith('.')
                ? hostname.substring(0, hostname.length - 1)
                : hostname)
          : (addresses.isEmpty ? service.name : addresses.first),
      port: service.port,
      addresses: addresses,
      txt: Map.of(service.attributes),
    );
  }

  final String name;
  final String host;
  final int port;
  final List<String> addresses;
  final Map<String, String> txt;

  Map<String, dynamic> toJson() => {
    'name': name,
    'host': host,
    'port': port,
    'addresses': addresses,
    'txt': txt,
  };
}

typedef PluginMdnsBrowser = Future<List<PluginMdnsService>> Function(
  String serviceType,
  Duration timeout,
  bool Function(String name) accepts,
);

Future<List<PluginMdnsService>> browseMdnsWithBonsoir(
  String serviceType,
  Duration timeout,
  bool Function(String name) accepts,
) async {
  final discovery = BonsoirDiscovery(type: serviceType);
  final resolved = <String, BonsoirService>{};
  await discovery.initialize();
  final subscription = discovery.eventStream!.listen((event) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent():
        if (accepts(event.service.name)) {
          event.service.resolve(discovery.serviceResolver);
        }
      case BonsoirDiscoveryServiceResolvedEvent():
        if (accepts(event.service.name)) {
          resolved[event.service.name] = event.service;
        }
      case BonsoirDiscoveryServiceLostEvent():
        resolved.remove(event.service.name);
      default:
    }
  });
  try {
    await discovery.start();
    await Future<void>.delayed(timeout);
  } finally {
    await subscription.cancel();
    try {
      await discovery.stop();
    } catch (_) {}
  }
  return resolved.values.map(PluginMdnsService.fromBonsoir).toList();
}
