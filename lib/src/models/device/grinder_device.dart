import 'grinder_capabilities.dart';
import 'grinder_operation.dart';
import 'grinder_snapshot.dart';

/// Native host boundary for any grinder implementation.
///
/// Implementations own credentials and transport.  Plugin code should see a
/// normalized service built on this interface, not a socket or bearer token.
abstract interface class GrinderDevice {
  String get deviceId;
  String get name;
  GrinderCapabilities get capabilities;
  Stream<GrinderSnapshot> get snapshots;

  Future<GrinderSnapshot> readSnapshot();

  Future<GrinderOperationResult> execute(GrinderCommand command);
}
