import 'package:flutter/material.dart';

import '../security/operator_pin.dart';
import '../state/pos_controller.dart';
import 'access_shell.dart';
import 'strings.dart';

/// First sign-in of an operator on an installed app: the PIN that opens the register later.
class PinSetupView extends StatefulWidget {
  const PinSetupView({super.key, required this.controller});
  final PosController controller;

  @override
  State<PinSetupView> createState() => _PinSetupViewState();
}

class _PinSetupViewState extends State<PinSetupView> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _save() {
    final s = S.of(context);
    if (!OperatorPin.valid(_pin.text)) {
      setState(() => _error = s.t('pinInvalid'));
    } else if (_pin.text != _confirm.text) {
      setState(() => _error = s.t('pinMismatch'));
    } else {
      widget.controller.createPin(_pin.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AccessHeading(eyebrow: s.t('app'), title: s.t('pinCreateTitle'), subtitle: s.t('pinCreateHelp')),
      _PinField(key: const Key('pinNew'), controller: _pin, label: s.t('pinNew'), next: true),
      const SizedBox(height: 16),
      _PinField(key: const Key('pinConfirm'), controller: _confirm, label: s.t('pinConfirm'), onSubmitted: _save, error: _error),
      const SizedBox(height: 24),
      FilledButton(key: const Key('pinSave'), onPressed: _save, child: Text(s.t('pinSave'))),
    ]);
  }
}

/// Reopened or idle app: the operator PIN before anything (online or offline).
class LockView extends StatefulWidget {
  const LockView({super.key, required this.controller});
  final PosController controller;

  @override
  State<LockView> createState() => _LockViewState();
}

class _LockViewState extends State<LockView> {
  final _pin = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final s = S.of(context);
    final code = _pin.text;
    _pin.clear();
    final left = await widget.controller.unlock(code);
    if (!mounted) return;
    setState(() => _error = left == null ? null : '${s.t('pinWrong')} $left');
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final user = widget.controller.vault?.user;
    final name = (user?['name'] ?? user?['email'] ?? '').toString();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AccessHeading(
        eyebrow: name.isEmpty ? s.t('app') : name,
        title: s.t('pinUnlockTitle'),
        subtitle: s.t('pinUnlockHelp'),
      ),
      _PinField(key: const Key('pinUnlock'), controller: _pin, label: s.t('pin'), onSubmitted: _unlock, error: _error),
      const SizedBox(height: 24),
      FilledButton(
        key: const Key('pinUnlockButton'),
        onPressed: widget.controller.busy ? null : _unlock,
        child: widget.controller.busy
            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(s.t('pinUnlock')),
      ),
    ]);
  }
}

class _PinField extends StatelessWidget {
  const _PinField({super.key, required this.controller, required this.label, this.onSubmitted, this.error, this.next = false});
  final TextEditingController controller;
  final String label;
  final VoidCallback? onSubmitted;
  final String? error;
  final bool next;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        decoration: InputDecoration(labelText: label, errorText: error),
        keyboardType: TextInputType.number,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        maxLength: OperatorPin.maxLength,
        textInputAction: next ? TextInputAction.next : TextInputAction.done,
        onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      );
}
