// Plugin extension-management bypass: api/network permissions, the manage.extensions grant and self-escalation.
import 'plugin_extension_management_bypass_suite.dart';

void main() =>
    definePluginExtensionManagementBypassTests(BypassPart.permissions);
