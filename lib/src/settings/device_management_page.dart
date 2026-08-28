import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DeviceManagementPage extends StatefulWidget {
  const DeviceManagementPage({
    super.key,
    required this.settingsController,
    required this.deviceController,
  });

  static const routeName = '/devices';

  final SettingsController settingsController;
  final DeviceController deviceController;

  @override
  State<DeviceManagementPage> createState() => _DeviceManagementPageState();
}

class _DeviceManagementPageState extends State<DeviceManagementPage> {
  late StreamSubscription<List<Device>> _deviceSubscription;
  final Map<String, StreamSubscription<DeviceInformation?>>
  _deviceInformationSubscriptions = {};
  List<Device> _devices = [];

  @override
  void initState() {
    super.initState();
    _devices = widget.deviceController.devices;
    _syncDeviceInformationSubscriptions();
    _deviceSubscription = widget.deviceController.deviceStream.listen((
      devices,
    ) {
      if (mounted) {
        setState(() => _devices = devices);
        _syncDeviceInformationSubscriptions();
      }
    });
  }

  @override
  void dispose() {
    _deviceSubscription.cancel();
    for (final subscription in _deviceInformationSubscriptions.values) {
      subscription.cancel();
    }
    super.dispose();
  }

  List<Device> get _machines =>
      _devices.where((d) => d.type == DeviceType.machine).toList();

  List<Device> get _scales =>
      _devices.where((d) => d.type == DeviceType.scale).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: ListenableBuilder(
        listenable: widget.settingsController,
        builder: (context, _) {
          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  _buildSection(
                    title: 'Auto-connect Machine',
                    icon: Icons.coffee_outlined,
                    devices: _machines,
                    selectedId: widget.settingsController.preferredMachineId,
                    emptyLabel: 'machines',
                    onSelected: (id) async {
                      await widget.settingsController.setPreferredMachineId(id);
                      if (mounted) _showSavedSnackbar();
                    },
                  ),
                  _buildSection(
                    title: 'Auto-connect Scale',
                    icon: Icons.scale_outlined,
                    devices: _scales,
                    selectedId: widget.settingsController.preferredScaleId,
                    emptyLabel: 'scales',
                    onSelected: (id) async {
                      await widget.settingsController.setPreferredScaleId(id);
                      if (mounted) _showSavedSnackbar();
                    },
                  ),
                  _buildSkaleSettings(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required IconData icon,
    required List<Device> devices,
    required String? selectedId,
    required String emptyLabel,
    required Future<void> Function(String?) onSelected,
  }) {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildDeviceRadio(
            name: 'None',
            subtitle: 'No auto-connect',
            isSelected: selectedId == null,
            onTap: () => onSelected(null),
          ),
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No $emptyLabel currently known. Connect to devices first, then return here to set a preference.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
              ),
            )
          else
            ...devices.map(
              (device) => _buildDeviceRadio(
                name: device.name,
                subtitle: _deviceSubtitle(device),
                isSelected: selectedId == device.deviceId,
                onTap: () => onSelected(device.deviceId),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSkaleSettings() {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Text(
            'Skale',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          ShadSwitch(
            value: widget.settingsController.skaleUsbPowered,
            onChanged: widget.settingsController.setSkaleUsbPowered,
            label: const Text('Powered by USB'),
          ),
          Text(
            'Suppress battery polling and report USB as the power source.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          ShadSwitch(
            value: widget.settingsController.scaleButtonStartsEspresso,
            onChanged: widget.settingsController.setScaleButtonStartsEspresso,
            label: const Text('Square button starts espresso'),
          ),
          Text(
            'Allow the square button to start or stop espresso. The circle button always tares.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  void _syncDeviceInformationSubscriptions() {
    final capable = {
      for (final device in _devices.whereType<DeviceInformationCapable>())
        (device as Device).deviceId: device,
    };
    final stale = _deviceInformationSubscriptions.keys
        .where((id) => !capable.containsKey(id))
        .toList();
    for (final id in stale) {
      _deviceInformationSubscriptions.remove(id)?.cancel();
    }
    for (final entry in capable.entries) {
      if (_deviceInformationSubscriptions.containsKey(entry.key)) continue;
      _deviceInformationSubscriptions[entry.key] = entry.value.deviceInformation
          .listen((_) {
            if (mounted) setState(() {});
          });
    }
  }

  String _deviceSubtitle(Device device) {
    final lines = <String>[_truncatedId(device.deviceId)];
    if (device case DeviceInformationCapable capable) {
      final information = capable.currentDeviceInformation;
      if (information?.firmwareVersion != null) {
        lines.add('Firmware: ${information!.firmwareVersion}');
      }
      if (information?.powerSource == DevicePowerSource.usb) {
        lines.add('Power: USB');
      } else if (information?.batteryLevel != null) {
        lines.add('Battery: ${information!.batteryLevel}% (device-reported)');
      }
    }
    return lines.join(' · ');
  }

  Widget _buildDeviceRadio({
    required String name,
    required String subtitle,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  Text(subtitle, style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _truncatedId(String id) {
    if (id.length > 8) {
      return 'ID: ...${id.substring(id.length - 8)}';
    }
    return 'ID: $id';
  }

  void _showSavedSnackbar() {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text('Preference saved. Takes effect on next app start.'),
          duration: Duration(seconds: 3),
        ),
      );
  }
}
