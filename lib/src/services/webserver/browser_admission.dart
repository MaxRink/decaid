part of '../webserver_service.dart';

const crossOriginRequestError =
    'This API does not accept requests from this browser origin';

const untrustedBrowserHostError =
    'This API only answers browsers on the device address';

const _admittedBrowserOriginKey = 'decaid.admittedBrowserOrigin';

const _corsAllowedMethods = 'DELETE, GET, OPTIONS, PATCH, POST, PUT';

const _corsAllowedRequestHeaders =
    'Accept, Accept-Encoding, Authorization, Content-Type, DNT, Origin, '
    'User-Agent, If-None-Match';

const _corsPreflightMaxAgeSeconds = '86400';

const _corsExposedResponseHeaders = [
  'ETag',
  'Location',
  'Content-Disposition',
  'Retry-After',
  'X-Request-Id',
];

Middleware browserAdmissionMiddleware(
  ExtensionManagementBrowserOrigins origins,
) {
  return (Handler inner) {
    return (Request request) async {
      final origin = request.headers['origin'];
      if (origin == null && !request.headers.containsKey('sec-fetch-site')) {
        return inner(request);
      }
      final action = '${request.method} /${request.url.path}';
      if (!await origins.isDeviceHost(request.requestedUri.host)) {
        log.warning('$action refused (403) for a browser on a foreign host');
        return _browserRefusal(untrustedBrowserHostError);
      }
      if (origin == null) return inner(request);
      final verdict = await origins.classify(
        origin,
        connectionInfo: request.context[_shelfConnectionInfoKey],
      );
      if (verdict != BrowserOriginVerdict.trusted) {
        log.warning('$action refused (403) for an untrusted browser origin');
        return _browserRefusal(crossOriginRequestError);
      }
      return inner(
        request.change(context: {_admittedBrowserOriginKey: origin}),
      );
    };
  };
}

bool isAdmittedBrowserRequest(Request request) {
  final origin = request.headers['origin'];
  return origin == null || _admittedBrowserOrigin(request) == origin;
}

String? _admittedBrowserOrigin(Request request) {
  final origin = request.context[_admittedBrowserOriginKey];
  return origin is String ? origin : null;
}

Middleware browserCorsMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      final origin = _admittedBrowserOrigin(request);
      if (origin == null) return inner(request);
      final cors = {
        'Access-Control-Allow-Origin': origin,
        'Access-Control-Allow-Credentials': 'true',
        'Access-Control-Allow-Methods': _corsAllowedMethods,
        'Access-Control-Allow-Headers': _corsAllowedRequestHeaders,
        'Access-Control-Expose-Headers': _corsExposedResponseHeaders.join(', '),
        'Access-Control-Max-Age': _corsPreflightMaxAgeSeconds,
      };
      if (request.method == 'OPTIONS') {
        return Response.ok(null, headers: {...cors, 'Vary': 'Origin'});
      }
      final response = await inner(request);
      return response.change(
        headers: {
          for (final MapEntry(:key, :value) in cors.entries)
            if (!response.headers.containsKey(key)) key: value,
          'Vary': _appendVary(response.headers['vary'], 'Origin'),
        },
      );
    };
  };
}

Response _browserRefusal(String error) => Response(
  403,
  body: jsonEncode({'error': error}),
  headers: const {
    'content-type': 'application/json',
    'cache-control': 'no-store',
    'vary': 'Origin',
  },
);
