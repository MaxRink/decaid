import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

const pluginSurfaceOrigin = 'http://localhost:8080';
const pluginSurfaceHandlerName = 'pluginSurface';

typedef PluginSurfaceLauncher = Future<bool> Function(Uri uri);

Uri themedPluginSurfaceUri(
  Uri uri, {
  required Brightness brightness,
  String? lang,
  bool embed = true,
}) => uri.replace(
  queryParameters: {
    ...uri.queryParameters,
    if (embed) 'embed': '1',
    'theme': brightness == Brightness.dark ? 'dark' : 'light',
    'lang': ?lang,
  },
);

bool get pluginSurfaceSheetSupported => !Platform.isLinux;

Future<bool> showPluginSurface(
  BuildContext context,
  Uri uri, {
  String? title,
  bool? useSheet,
  Widget? webView,
}) async {
  final brightness = Theme.of(context).brightness;
  final lang = Localizations.maybeLocaleOf(context)?.toLanguageTag();
  if (!(useSheet ?? pluginSurfaceSheetSupported)) {
    return launchUrl(
      themedPluginSurfaceUri(
        uri,
        brightness: brightness,
        lang: lang,
        embed: false,
      ),
      mode: LaunchMode.inAppBrowserView,
    );
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.92,
      child: PluginSurfaceSheet(
        uri: themedPluginSurfaceUri(uri, brightness: brightness, lang: lang),
        title: title,
        webView: webView,
      ),
    ),
  );
  return true;
}

class PluginSurfaceSheet extends StatelessWidget {
  const PluginSurfaceSheet({
    super.key,
    required this.uri,
    this.title,
    this.webView,
  });

  final Uri uri;
  final String? title;
  final Widget? webView;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title ?? '',
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Open in browser',
                icon: const Icon(Icons.open_in_browser),
                onPressed: () => launchUrl(
                  uri.replace(
                    queryParameters: {...uri.queryParameters}..remove('embed'),
                  ),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: webView ?? _buildWebView(context)),
      ],
    );
  }

  Widget _buildWebView(BuildContext context) {
    final navigator = Navigator.of(context);
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(uri.toString())),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        javaScriptCanOpenWindowsAutomatically: false,
        allowFileAccessFromFileURLs: false,
        allowUniversalAccessFromFileURLs: false,
        useShouldOverrideUrlLoading: true,
        transparentBackground: true,
        cacheEnabled: false,
      ),
      onWebViewCreated: (controller) => controller.addJavaScriptHandler(
        handlerName: pluginSurfaceHandlerName,
        callback: (arguments) {
          if (isPluginSurfaceCloseMessage(arguments) && navigator.canPop()) {
            navigator.pop();
          }
          return null;
        },
      ),
      shouldOverrideUrlLoading: (controller, action) async {
        final target = action.request.url;
        if (target == null ||
            !action.isForMainFrame ||
            isSameSurfaceOrigin(uri, target)) {
          return NavigationActionPolicy.ALLOW;
        }
        if (target.scheme == 'https' || target.scheme == 'http') {
          await launchUrl(target, mode: LaunchMode.externalApplication);
        }
        return NavigationActionPolicy.CANCEL;
      },
    );
  }
}

bool isPluginSurfaceCloseMessage(List<dynamic> arguments) =>
    arguments.isNotEmpty &&
    arguments.first is Map &&
    (arguments.first as Map)['type'] == 'close';

bool isSameSurfaceOrigin(Uri surface, Uri target) =>
    target.scheme == surface.scheme &&
    target.host == surface.host &&
    target.port == surface.port;
