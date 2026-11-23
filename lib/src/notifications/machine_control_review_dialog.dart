import 'package:flutter/material.dart';

Future<bool> showMachineControlReview(
  BuildContext context, {
  required String pluginName,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Allow $pluginName to control the machine?'),
        content: const Text(
          'It will be able to start and stop shots and change machine '
          'settings and calibration. You can change this later in '
          'Settings > Plugins.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    ) ??
    false;
