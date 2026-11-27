// Plugin extension-management bypass: manual update checks, CORS policy and the browser origin boundary.
import 'plugin_extension_management_bypass_suite.dart';

void main() =>
    definePluginExtensionManagementBypassTests(BypassPart.updatesAndOrigins);
