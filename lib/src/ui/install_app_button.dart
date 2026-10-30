import 'package:flutter/material.dart';

import '../platform/pwa.dart';
import 'strings.dart';

/// "Install app" for the web POS: opens the browser prompt (Chrome, Edge, Android) or shows the
/// Add to Home Screen steps (iPhone/iPad). Hidden when installed, unsupported or native.
class InstallAppButton extends StatefulWidget {
  const InstallAppButton({super.key, this.labeled = false});

  /// Text button with the label (sign-in screen) instead of an icon (app bar).
  final bool labeled;

  @override
  State<InstallAppButton> createState() => _InstallAppButtonState();
}

class _InstallAppButtonState extends State<InstallAppButton> {
  PwaInstallState _state = pwaInstallState();

  @override
  void initState() {
    super.initState();
    pwaOnInstallChange(() {
      if (mounted) setState(() => _state = pwaInstallState());
    });
  }

  Future<void> _install() async {
    if (_state == PwaInstallState.ios) {
      final s = S.of(context);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.ios_share),
          title: Text(s.t('installApp')),
          content: Text(s.t('installIosSteps')),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(s.t('close')))],
        ),
      );
      return;
    }
    await pwaPromptInstall();
    if (mounted) setState(() => _state = pwaInstallState());
  }

  @override
  Widget build(BuildContext context) {
    if (_state != PwaInstallState.available && _state != PwaInstallState.ios) {
      return const SizedBox.shrink();
    }
    final label = S.of(context).t('installApp');
    if (widget.labeled) {
      return OutlinedButton.icon(
        key: const Key('installApp'),
        icon: const Icon(Icons.install_desktop),
        label: Text(label),
        onPressed: _install,
      );
    }
    return IconButton(
      key: const Key('installApp'),
      tooltip: label,
      icon: const Icon(Icons.install_desktop),
      onPressed: _install,
    );
  }
}
