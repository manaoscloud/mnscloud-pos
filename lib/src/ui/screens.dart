import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/models.dart';
import '../core/money.dart';
import '../platform/scanner_support.dart';
import '../platform/session.dart';
import '../state/pos_controller.dart';
import 'access_shell.dart';
import 'install_app_button.dart';
import 'strings.dart';

String fmt(Decimal value) => value.format();

/// Amount typed by the operator: `1234,56`, `1.234,56` (pt-BR grouping) or `1234.56`. Null when it
/// is not a number, so a typo is shown as an error instead of becoming zero.
Decimal? parseAmount(String text, [int scale = 4]) {
  var value = text.trim().replaceAll(' ', '');
  if (value.isEmpty) return null;
  if (value.contains(',')) value = value.replaceAll('.', '').replaceAll(',', '.');
  return Decimal.tryParse(value, scale);
}

/// Root screen: follows the controller stage.
class PosHome extends StatelessWidget {
  const PosHome({super.key, required this.controller});
  final PosController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final body = switch (controller.stage) {
            PosStage.signIn => SignInView(controller: controller),
            PosStage.tenant => TenantView(controller: controller),
            PosStage.terminal => TerminalView(controller: controller),
            PosStage.openSession => OpenSessionView(controller: controller),
            PosStage.selling => SellingView(controller: controller),
          };
          // Sign-in, company and register follow Settings › Themes › Login do POS.
          if (const {PosStage.signIn, PosStage.tenant, PosStage.terminal}.contains(controller.stage)) {
            return _accessScaffold(context, body);
          }
          return _workScaffold(context, body);
        },
      );

  Widget _accessScaffold(BuildContext context, Widget body) => Scaffold(
        body: SafeArea(
          child: AccessShell(
            controller: controller,
            onSignOut: controller.stage == PosStage.signIn || controller.busy ? null : () => confirmSignOut(context, controller),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (controller.error != null)
                Padding(padding: const EdgeInsets.only(bottom: 20), child: ErrorBanner(controller: controller)),
              body,
            ]),
          ),
        ),
      );

  Widget _workScaffold(BuildContext context, Widget body) => Scaffold(
        appBar: controller.stage == PosStage.signIn ? null : PosStatusBar(controller: controller),
        body: SafeArea(
          child: Column(children: [
            if (controller.error != null) ErrorBanner(controller: controller),
            if (controller.syncMessage != null)
              MaterialBanner(
                leading: const Icon(Icons.sync_problem),
                content: Text(controller.syncMessage!),
                actions: [TextButton(onPressed: controller.syncNow, child: Text(S.of(context).t('syncNow')))],
              ),
            Expanded(child: body),
          ]),
        ),
      );
}

/// Company, register, operator, connection and session, always visible.
class PosStatusBar extends StatelessWidget implements PreferredSizeWidget {
  const PosStatusBar({super.key, required this.controller});
  final PosController controller;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    final online = controller.connection != ConnectionStatus.unreachable;
    final terminal = controller.terminal;
    return AppBar(
      titleSpacing: 16,
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          [s.t('app'), if (terminal != null) terminal.name].join(' · '),
          style: Theme.of(context).textTheme.titleMedium,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          _context(s),
          style: Theme.of(context).textTheme.bodySmall,
          overflow: TextOverflow.ellipsis,
        ),
      ]),
      actions: [
        if (controller.deviceMode) ..._deviceActions(s, scheme),
        Tooltip(
          message: online ? s.t('online') : s.t('unreachable'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Chip(
              avatar: Icon(online ? Icons.cloud_done : Icons.cloud_off, size: 18, color: online ? scheme.primary : scheme.error),
              label: Text(online ? s.t('online') : s.t('unreachable')),
            ),
          ),
        ),
        if (controller.stage == PosStage.selling)
          IconButton(
            tooltip: s.t('register'),
            icon: const Icon(Icons.point_of_sale),
            onPressed: () => showDialog(context: context, builder: (_) => RegisterDialog(controller: controller)),
          ),
        const InstallAppButton(),
        IconButton(
          key: const Key('signOut'),
          tooltip: s.t('signOut'),
          icon: const Icon(Icons.logout),
          onPressed: controller.busy ? null : () => confirmSignOut(context, controller),
        ),
      ],
    );
  }

  /// Company, tenant, operator and the open session's sale count.
  String _context(S s) {
    final terminal = controller.terminal;
    final session = controller.session;
    final user = controller.user;
    return [
      if (terminal != null) terminal.companyName,
      if (controller.tenant != null) controller.tenant!.name,
      if (user != null) user.name.isNotEmpty ? user.name : user.email,
      if (session != null && session.isOpen) '${s.t('sales')}: ${session.saleCount}',
    ].join(' · ');
  }

  /// Installed-app (device) state: pending operations, problems and a manual sync.
  List<Widget> _deviceActions(S s, ColorScheme scheme) {
    final device = controller.device!;
    return [
      Tooltip(
        message: s.t('deviceModeHint'),
        child: Chip(
          avatar: Icon(Icons.phone_android, size: 18, color: scheme.primary),
          label: Text(device.pendingOperations == 0 ? s.t('deviceSynced') : '${device.pendingOperations} ${s.t('devicePending')}'),
        ),
      ),
      if (device.problemCount > 0)
        Tooltip(
          message: s.t('deviceProblemsHint'),
          child: Chip(
            avatar: Icon(Icons.report_problem, size: 18, color: scheme.error),
            label: Text('${device.problemCount}'),
          ),
        ),
      IconButton(tooltip: s.t('syncNow'), icon: const Icon(Icons.sync), onPressed: controller.syncNow),
    ];
  }
}

/// Asks before signing out and says what happens to the sale in progress and the open register.
Future<void> confirmSignOut(BuildContext context, PosController controller) async {
  final s = S.of(context);
  if (controller.saleInDoubt) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.t('signOut')),
        content: Text(s.t('signOutInDoubt')),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('close')))],
      ),
    );
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s.t('signOutQuestion')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.t('signOutHint')),
        if (controller.cart.isNotEmpty) ...[const SizedBox(height: 12), Text(s.t('signOutCart'))],
        if (controller.session?.isOpen == true) ...[const SizedBox(height: 12), Text(s.t('signOutCashOpen'))],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('cancel'))),
        FilledButton(
          key: const Key('confirmSignOut'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(s.t('signOut')),
        ),
      ],
    ),
  );
  if (ok == true) await controller.signOut();
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.controller});
  final PosController controller;

  @override
  Widget build(BuildContext context) => MaterialBanner(
        content: Text(S.of(context).message(controller.error ?? '')),
        leading: const Icon(Icons.error_outline),
        actions: [TextButton(onPressed: controller.dismissError, child: Text(S.of(context).t('close')))],
      );
}

class _CenteredCard extends StatelessWidget {
  const _CenteredCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(child: Padding(padding: const EdgeInsets.all(24), child: child)),
          ),
        ),
      );
}

class SignInView extends StatefulWidget {
  const SignInView({super.key, required this.controller});
  final PosController controller;

  @override
  State<SignInView> createState() => _SignInViewState();
}

class _SignInViewState extends State<SignInView> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _showPassword = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() => widget.controller.signIn(_email.text.trim(), _password.text);

  /// The POS uses the App account: recovery is the App page of the same domain (web only).
  String get _recoveryUrl => Uri.base.resolve('/auth/forgot-password').toString();

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final brand = widget.controller.brand.value;
    return AutofillGroup(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AccessHeading(
          eyebrow: accessText(context, brand, 'eyebrow'),
          title: accessText(context, brand, 'title'),
          subtitle: accessText(context, brand, 'subtitle'),
        ),
        TextField(
          key: const Key('signInEmail'),
          controller: _email,
          decoration: InputDecoration(labelText: s.t('email')),
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.next,
          autocorrect: false,
        ),
        const SizedBox(height: 20),
        TextField(
          key: const Key('signInPassword'),
          controller: _password,
          decoration: InputDecoration(
            labelText: s.t('password'),
            suffixIcon: IconButton(
              key: const Key('togglePassword'),
              tooltip: _showPassword ? s.t('hidePassword') : s.t('showPassword'),
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
            ),
          ),
          obscureText: !_showPassword,
          enableSuggestions: false,
          autocorrect: false,
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) => _submit(),
        ),
        if (isWebPlatform)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('forgotPassword'),
              onPressed: () => openAccessLink(context, _recoveryUrl),
              child: Text(s.t('forgotPassword')),
            ),
          )
        else
          const SizedBox(height: 20),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: widget.controller.busy ? null : _submit,
          child: widget.controller.busy
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(s.t('signIn')),
        ),
        if (isWebPlatform) ...[
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.wifi, size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(s.t('webOnline'), style: Theme.of(context).textTheme.bodySmall)),
            ]),
          ),
        ],
      ]),
    );
  }
}

/// Signed-in operator, shown above the company and register choices.
class _SignedInAs extends StatelessWidget {
  const _SignedInAs({required this.controller});
  final PosController controller;

  @override
  Widget build(BuildContext context) {
    final user = controller.user;
    if (user == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        '${S.of(context).t('signedInAs')} ${user.email}',
        style: Theme.of(context).textTheme.bodySmall,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// One company or register choice of the access screens.
class _AccessChoice extends StatelessWidget {
  const _AccessChoice({required this.icon, required this.title, this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: ListTile(
          shape: RoundedRectangleBorder(
            side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          minVerticalPadding: 14,
          leading: Icon(icon),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle!),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      );
}

class TenantView extends StatelessWidget {
  const TenantView({super.key, required this.controller});
  final PosController controller;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _SignedInAs(controller: controller),
      AccessHeading(
        eyebrow: accessText(context, controller.brand.value, 'eyebrow'),
        title: s.t('chooseTenant'),
        subtitle: s.t('chooseTenantHint'),
      ),
      for (final t in controller.tenants)
        _AccessChoice(
          icon: Icons.apartment,
          title: t.name.isEmpty ? t.uuid : t.name,
          subtitle: t.code,
          onTap: () => controller.selectTenant(t),
        ),
    ]);
  }
}

class TerminalView extends StatelessWidget {
  const TerminalView({super.key, required this.controller});
  final PosController controller;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _SignedInAs(controller: controller),
      AccessHeading(
        eyebrow: controller.tenant?.name ?? accessText(context, controller.brand.value, 'eyebrow'),
        title: s.t('chooseTerminal'),
        subtitle: s.t('chooseTerminalHint'),
      ),
      if (controller.terminals.isEmpty) Text(s.t('noTerminals')),
      for (final t in controller.terminals)
        _AccessChoice(
          icon: t.openSessionUuid != null ? Icons.lock_open : Icons.point_of_sale,
          title: t.name,
          subtitle: '${t.companyName} · ${t.locationName}',
          onTap: () => controller.selectTerminal(t),
        ),
    ]);
  }
}

class OpenSessionView extends StatefulWidget {
  const OpenSessionView({super.key, required this.controller});
  final PosController controller;

  @override
  State<OpenSessionView> createState() => _OpenSessionViewState();
}

class _OpenSessionViewState extends State<OpenSessionView> {
  final _amount = TextEditingController(text: '0,00');
  final _deviceName = TextEditingController();
  String? _amountError;

  @override
  void initState() {
    super.initState();
    _deviceName.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _deviceName.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return _CenteredCard(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(s.t('openSession'), style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        MoneyField(controller: _amount, label: s.t('openingAmount'), errorText: _amountError, autofocus: true),
        const SizedBox(height: 20),
        FilledButton.icon(
          icon: const Icon(Icons.lock_open),
          onPressed: widget.controller.busy ? null : () => _open(s),
          label: Text(s.t('openSession')),
        ),
        TextButton(onPressed: widget.controller.backToTerminals, child: Text(s.t('switchTerminal'))),
        if (widget.controller.canProvisionDevice) ..._provisionSection(s),
        if (widget.controller.deviceMode) ...[
          const SizedBox(height: 8),
          Text(s.t('deviceModeHint'), style: Theme.of(context).textTheme.bodySmall),
        ],
      ]),
    );
  }

  void _open(S s) {
    final amount = _amount.text.trim().isEmpty ? Decimal.zero() : parseAmount(_amount.text);
    setState(() => _amountError = amount == null || amount.isNegative ? s.t('invalidAmount') : null);
    if (_amountError == null) widget.controller.openSession(amount!);
  }

  /// Turns this installed app into an offline-capable device of the register.
  List<Widget> _provisionSection(S s) {
    final text = Theme.of(context).textTheme;
    return [
      const Divider(height: 32),
      Text(s.t('provisionTitle'), style: text.titleMedium),
      const SizedBox(height: 4),
      Text(s.t('provisionHint'), style: text.bodySmall),
      const SizedBox(height: 8),
      TextField(controller: _deviceName, decoration: InputDecoration(labelText: s.t('deviceName'))),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        icon: const Icon(Icons.offline_bolt),
        onPressed: widget.controller.busy || _deviceName.text.trim().isEmpty
            ? null
            : () => widget.controller.provisionDevice(_deviceName.text.trim()),
        label: Text(s.t('provision')),
      ),
    ];
  }
}

/// Decimal field: selects its text on focus, so typing replaces a prefilled `0,00`.
class MoneyField extends StatefulWidget {
  const MoneyField({
    super.key,
    required this.controller,
    required this.label,
    this.onSubmitted,
    this.autofocus = false,
    this.errorText,
    this.helperText,
  });
  final TextEditingController controller;
  final String label;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final String? errorText;
  final String? helperText;

  @override
  State<MoneyField> createState() => _MoneyFieldState();
}

class _MoneyFieldState extends State<MoneyField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) {
        widget.controller.selection = TextSelection(baseOffset: 0, extentOffset: widget.controller.text.length);
      }
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: widget.controller,
        focusNode: _focus,
        autofocus: widget.autofocus,
        // Messages wrap: a phone must show the whole reason (e.g. the discount maximum).
        decoration: InputDecoration(
          labelText: widget.label,
          errorText: widget.errorText,
          helperText: widget.helperText,
          errorMaxLines: 4,
          helperMaxLines: 3,
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
        onSubmitted: widget.onSubmitted,
      );
}

/// Main selling surface: search/scan, cart, totals and payment. Two panes on wide screens, one
/// column on phones.
class SellingView extends StatefulWidget {
  const SellingView({super.key, required this.controller});
  final PosController controller;

  @override
  State<SellingView> createState() => _SellingViewState();
}

class _SellingViewState extends State<SellingView> {
  final _search = TextEditingController();
  final _focus = FocusNode();
  List<CatalogItem> _results = const [];
  Timer? _debounce;
  bool _cameraScan = false;

  @override
  void initState() {
    super.initState();
    cameraScanSupported().then((ok) {
      if (mounted && ok) setState(() => _cameraScan = true);
    });
  }

  /// Reads one barcode with the camera and handles it like a code typed by a reader.
  Future<void> _scanWithCamera() async {
    final code = await showDialog<String>(context: context, builder: (_) => const CameraScanDialog());
    if (code != null && code.isNotEmpty) await _onSubmitted(code);
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final found = await widget.controller.search(value);
      if (mounted) setState(() => _results = found);
    });
  }

  Future<void> _onSubmitted(String value) async {
    // Keyboard-wedge scanners type the code and Enter: try the code first, then the search.
    final code = value.trim();
    if (code.isEmpty) return;
    if (RegExp(r'^[0-9A-Za-z]{6,64}$').hasMatch(code) && await widget.controller.scan(code)) {
      _search.clear();
      setState(() => _results = const []);
    } else if (_results.length == 1) {
      widget.controller.addItem(_results.first);
      _search.clear();
      setState(() => _results = const []);
    }
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final catalog = _CatalogPane(
      search: _search,
      focus: _focus,
      results: _results,
      onChanged: _onChanged,
      onSubmitted: _onSubmitted,
      onScan: _cameraScan ? _scanWithCamera : null,
      onPick: (item) {
        widget.controller.addItem(item);
        _search.clear();
        setState(() => _results = const []);
        _focus.requestFocus();
      },
    );
    final cart = _CartPane(controller: widget.controller);
    if (wide) {
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(flex: 5, child: catalog),
        const VerticalDivider(width: 1),
        Expanded(flex: 4, child: cart),
      ]);
    }
    return Column(children: [
      SizedBox(height: 260, child: catalog),
      const Divider(height: 1),
      Expanded(child: cart),
    ]);
  }
}

class _CatalogPane extends StatelessWidget {
  const _CatalogPane({
    required this.search,
    required this.focus,
    required this.results,
    required this.onChanged,
    required this.onSubmitted,
    required this.onPick,
    this.onScan,
  });
  final TextEditingController search;
  final FocusNode focus;
  final List<CatalogItem> results;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<CatalogItem> onPick;

  /// Camera scanning, when this device supports it (null: keyboard-wedge reader only).
  final VoidCallback? onScan;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: search,
          focusNode: focus,
          autofocus: true,
          decoration: InputDecoration(
            prefixIcon: onScan == null
                ? const Icon(Icons.qr_code_scanner)
                : IconButton(
                    key: const Key('cameraScan'),
                    tooltip: s.t('scanWithCamera'),
                    icon: const Icon(Icons.photo_camera),
                    onPressed: onScan,
                  ),
            labelText: s.t('search'),
          ),
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.separated(
            itemCount: results.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final item = results[index];
              return ListTile(
                title: Text(item.name),
                subtitle: Text([
                  if (item.code != null) item.code!,
                  if (item.available != null) '${s.t('stock')}: ${item.available!.format(places: 0)}',
                ].join(' · ')),
                trailing: Text(fmt(item.price), style: Theme.of(context).textTheme.titleMedium),
                onTap: () => onPick(item),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class _CartPane extends StatelessWidget {
  const _CartPane({required this.controller});
  final PosController controller;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(s.t('cart'), style: text.titleLarge),
        const SizedBox(height: 8),
        Expanded(child: controller.cart.isEmpty ? Center(child: Text(s.t('emptyCart'))) : _lines(s, text)),
        const Divider(),
        _TotalRow(label: s.t('subtotal'), value: controller.subtotal),
        if (!controller.discount.isZero) _TotalRow(label: s.t('discount'), value: -controller.discount),
        _TotalRow(label: s.t('total'), value: controller.total, strong: true),
        const SizedBox(height: 8),
        ..._payments(s),
        if (controller.saleInDoubt) ...[
          const SizedBox(height: 8),
          Text(s.t('inDoubt'), style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 12),
        _actions(context, s),
        if (controller.saleInDoubt)
          TextButton(onPressed: controller.discardSaleInDoubt, child: Text(s.t('checkSale')))
        else if (controller.cart.isNotEmpty)
          TextButton(onPressed: controller.clearSale, child: Text(s.t('clear'))),
      ]),
    );
  }

  Widget _lines(S s, TextTheme text) => ListView.separated(
        itemCount: controller.cart.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final line = controller.cart[index];
          return ListTile(
            title: Text(line.item.name),
            subtitle: Text('${line.quantity.format(places: 3)} × ${fmt(line.item.price)}'
                '${line.discount.isZero ? '' : ' − ${fmt(line.discount)}'}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(fmt(line.total), style: text.titleMedium),
              IconButton(
                tooltip: s.t('quantity'),
                icon: const Icon(Icons.edit),
                onPressed: controller.saleInDoubt
                    ? null
                    : () => showDialog(context: context, builder: (_) => _LineDialog(controller: controller, line: line)),
              ),
            ]),
          );
        },
      );

  /// Registered payments, paid amount, what is still due and the change.
  List<Widget> _payments(S s) => [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in controller.payments)
            InputChip(
              label: Text('${s.t(p.method.code)} ${fmt(p.amount)}'),
              onDeleted: controller.saleInDoubt ? null : () => controller.removePayment(p),
            ),
        ]),
        if (controller.payments.isNotEmpty) ...[
          _TotalRow(label: s.t('paid'), value: controller.paid),
          if (controller.remaining.isPositive) _TotalRow(label: s.t('remaining'), value: controller.remaining),
          if (controller.change.isPositive) _TotalRow(label: s.t('change'), value: controller.change, strong: true),
        ],
      ];

  Widget _actions(BuildContext context, S s) => Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.payments),
            onPressed: controller.cart.isEmpty || controller.saleInDoubt || !controller.remaining.isPositive
                ? null
                : () => showDialog(context: context, builder: (_) => PaymentDialog(controller: controller)),
            label: Text(s.t('pay')),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
            icon: controller.busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check),
            onPressed: controller.busy || !controller.canFinish ? null : () => _finish(context),
            label: Text(controller.saleInDoubt ? s.t('retry') : s.t('finish')),
          ),
        ),
      ]);

  Future<void> _finish(BuildContext context) async {
    final sale = await controller.finish();
    if (sale != null && context.mounted) {
      await showDialog(context: context, builder: (_) => SaleDoneDialog(controller: controller, sale: sale));
    }
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow({required this.label, required this.value, this.strong = false});
  final String label;
  final Decimal value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final style = strong ? Theme.of(context).textTheme.titleLarge : Theme.of(context).textTheme.bodyLarge;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [Expanded(child: Text(label, style: style)), Text(fmt(value), style: style)]),
    );
  }
}

class _LineDialog extends StatefulWidget {
  const _LineDialog({required this.controller, required this.line});
  final PosController controller;
  final CartLine line;

  @override
  State<_LineDialog> createState() => _LineDialogState();
}

class _LineDialogState extends State<_LineDialog> {
  late final _qty = TextEditingController(text: widget.line.quantity.format(places: 3, groupSeparator: ''));
  late final _discount = TextEditingController(text: widget.line.discount.format(groupSeparator: ''));
  String? _qtyError;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final max = widget.controller.discountLimit(widget.line);
    return AlertDialog(
      title: Text(widget.line.item.name),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        MoneyField(controller: _qty, label: s.t('quantity'), autofocus: true, errorText: _qtyError),
        const SizedBox(height: 12),
        MoneyField(
          controller: _discount,
          label: s.t('discount'),
          errorText: _error,
          helperText: '${s.t('discountMax')}: ${fmt(max)}',
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
        FilledButton(
          onPressed: () => _confirm(s),
          child: Text(s.t('confirm')),
        ),
      ],
    );
  }

  void _confirm(S s) {
    final qty = parseAmount(_qty.text, 6);
    final discount = _discount.text.trim().isEmpty ? Decimal.zero() : parseAmount(_discount.text);
    setState(() {
      _qtyError = qty == null || qty.isNegative ? s.t('invalidAmount') : null;
      _error = discount == null ? s.t('invalidAmount') : null;
    });
    if (qty == null || qty.isNegative || discount == null) return;
    if (qty.isPositive && !_applyWithDiscount(s, qty, discount)) return;
    if (!qty.isPositive) widget.controller.setQuantity(widget.line, qty);
    Navigator.pop(context);
  }

  /// Checks the discount against the new quantity before changing the line; false keeps the dialog.
  bool _applyWithDiscount(S s, Decimal qty, Decimal discount) {
    final previous = widget.line.quantity;
    widget.controller.setQuantity(widget.line, qty);
    final problem = widget.controller.setDiscount(widget.line, discount);
    if (problem == null) return true;
    widget.controller.setQuantity(widget.line, previous);
    setState(() => _error = '${s.message(problem)} ${s.t('discountMax')}: '
        '${fmt(widget.controller.discountLimit(CartLine(item: widget.line.item, quantity: qty)))}');
    return false;
  }
}

class PaymentDialog extends StatefulWidget {
  const PaymentDialog({super.key, required this.controller});
  final PosController controller;

  @override
  State<PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<PaymentDialog> {
  late PaymentMethod _method;
  late final _amount = TextEditingController(text: widget.controller.remaining.format(groupSeparator: ''));
  final _nsu = TextEditingController();
  final _auth = TextEditingController();

  /// Pix needs the tenant gateway online, so installed devices (local-first) take cash and cards.
  List<String> get _accepted {
    final all = widget.controller.terminal?.paymentMethods ?? const ['cash'];
    final usable = widget.controller.deviceMode || !_pixReady ? all.where((m) => m != 'pix').toList() : all;
    return usable.isEmpty ? const ['cash'] : usable;
  }

  /// Pix is charged on the tenant payment gateway; without one the option is hidden.
  bool get _pixReady => widget.controller.terminal?.pixAvailable ?? true;
  bool get _pixHidden =>
      !widget.controller.deviceMode && !_pixReady && (widget.controller.terminal?.paymentMethods.contains('pix') ?? false);
  String? _amountError;

  @override
  void initState() {
    super.initState();
    final accepted = _accepted;
    _method = PaymentMethodCode.fromCode(accepted.first);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final accepted = _accepted;
    final card = _method == PaymentMethod.cardCredit || _method == PaymentMethod.cardDebit;
    return AlertDialog(
      title: Text(s.t('pay')),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final code in accepted)
              ChoiceChip(
                label: Text(s.t(code)),
                selected: _method.code == code,
                onSelected: (_) => setState(() => _method = PaymentMethodCode.fromCode(code)),
              ),
          ]),
          if (_pixHidden) ...[
            const SizedBox(height: 8),
            Text(s.t('pixUnavailable'), style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
          MoneyField(controller: _amount, label: s.t('amount'), autofocus: true, errorText: _amountError),
          ..._methodDetails(s, card),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
        FilledButton(
          onPressed: () => _add(s, card),
          child: Text(s.t('add')),
        ),
      ],
    );
  }

  /// Card terminal references (NSU, authorization) or the Pix hint for the chosen method.
  List<Widget> _methodDetails(S s, bool card) {
    final small = Theme.of(context).textTheme.bodySmall;
    return [
      if (card) ...[
        const SizedBox(height: 12),
        TextField(controller: _nsu, decoration: InputDecoration(labelText: s.t('nsu'))),
        const SizedBox(height: 8),
        TextField(controller: _auth, decoration: InputDecoration(labelText: s.t('authCode'))),
        const SizedBox(height: 8),
        Text(s.t('cardHint'), style: small),
      ],
      if (_method == PaymentMethod.pix) ...[
        const SizedBox(height: 8),
        Text(s.t('pixHint'), style: small),
      ],
    ];
  }

  void _add(S s, bool card) {
    final amount = parseAmount(_amount.text);
    setState(() => _amountError = amount == null || !amount.isPositive ? s.t('invalidAmount') : null);
    if (amount == null || !amount.isPositive) return;
    // Only cash may exceed the remaining amount (change).
    final value = _method == PaymentMethod.cash ? amount : amount.min(widget.controller.remaining);
    widget.controller.addPayment(PaymentEntry(
      method: _method,
      amount: value,
      providerReference: card && _nsu.text.trim().isNotEmpty ? _nsu.text.trim() : null,
      authorizationCode: card && _auth.text.trim().isNotEmpty ? _auth.text.trim() : null,
    ));
    Navigator.pop(context);
  }
}

/// Result of a stored sale: change, payment state and the Pix flow for pending payments.
class SaleDoneDialog extends StatefulWidget {
  const SaleDoneDialog({super.key, required this.controller, required this.sale});
  final PosController controller;
  final PosSaleResult sale;

  @override
  State<SaleDoneDialog> createState() => _SaleDoneDialogState();
}

class _SaleDoneDialogState extends State<SaleDoneDialog> {
  late PosSaleResult _sale = widget.sale;
  final Map<String, String> _pixCodes = {};
  Timer? _poll;
  String? _pixError;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Iterable<Map<String, dynamic>> get _pending =>
      _sale.payments.where((p) => p['PspState'] == 'pending' || p['PspState'] == 'unknown');

  Future<void> _generatePix(String paymentUuid) async {
    final charge = await widget.controller.pixCharge(paymentUuid);
    if (!mounted) return;
    if (charge == null) {
      // Shown here: the banner of the main screen is hidden behind this dialog.
      setState(() => _pixError = widget.controller.error);
      widget.controller.dismissError();
      return;
    }
    final code = charge['pixCopyPaste']?.toString();
    if (code != null && code.isNotEmpty) setState(() => _pixCodes[paymentUuid] = code);
    _poll ??= Timer.periodic(const Duration(seconds: 5), (_) => _check());
  }

  Future<void> _check() async {
    for (final p in _pending.toList()) {
      final uuid = p['PspUUID'].toString();
      final status = await widget.controller.paymentStatus(uuid);
      if (status != null && status['PspState'] == 'confirmed') {
        final fresh = await widget.controller.api.sale(_sale.uuid);
        if (fresh != null && mounted) setState(() => _sale = fresh);
      }
    }
    if (_pending.isEmpty) _poll?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final confirmed = _sale.paymentState == 'confirmed';
    final onDevice = _sale.syncState == 'pending';
    return AlertDialog(
      title: Text(onDevice ? s.t('saleSavedOnDevice') : '${s.t('saleSaved')} · ${s.t('saleNumber')} ${_sale.number}'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _TotalRow(label: s.t('total'), value: _sale.total, strong: true),
          if (_sale.change.isPositive) _TotalRow(label: s.t('change'), value: _sale.change, strong: true),
          const SizedBox(height: 8),
          Chip(
            avatar: Icon(confirmed ? Icons.verified : Icons.hourglass_top, size: 18),
            label: Text(confirmed ? s.t('paymentConfirmed') : s.t('paymentPending')),
          ),
          for (final p in _pending)
            if (p['PspMethod'] == 'pix') ..._pixPayment(s, p),
          if (_pixError != null) ...[
            const SizedBox(height: 8),
            Text(s.message(_pixError!), style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (onDevice)
            Chip(avatar: const Icon(Icons.sync, size: 18), label: Text(s.t('waitingSync'))),
          if (onDevice) _contingencyDocument(s),
          const SizedBox(height: 12),
          Text(s.t('noFiscal'), style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(s.t('close')))],
    );
  }

  /// Pending Pix payment: its QR code once generated, otherwise the button that charges it.
  List<Widget> _pixPayment(S s, Map<String, dynamic> p) {
    final code = _pixCodes[p['PspUUID'].toString()];
    return [
      const SizedBox(height: 8),
      if (code != null) ...[
        Center(child: QrImageView(data: code, size: 220, backgroundColor: Colors.white)),
        TextButton.icon(
          icon: const Icon(Icons.copy),
          onPressed: () => Clipboard.setData(ClipboardData(text: code)),
          label: Text(s.t('copyPix')),
        ),
        OutlinedButton(onPressed: _check, child: Text(s.t('checkPix'))),
      ] else
        FilledButton.icon(
          icon: const Icon(Icons.qr_code_2),
          onPressed: () => _generatePix(p['PspUUID'].toString()),
          label: Text('${s.t('generatePix')} · ${fmt(money(p['PspAmount']))}'),
        ),
      Text(s.t('pixHint'), style: Theme.of(context).textTheme.bodySmall),
    ];
  }

  /// Offline (contingency) NFC-e of a sale kept on the device, as it becomes available.
  Widget _contingencyDocument(S s) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final doc = widget.controller.lastFiscalDocument;
          final message = widget.controller.fiscalMessage;
          final text = Theme.of(context).textTheme;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (doc != null) ...[
              const SizedBox(height: 8),
              Text('${s.t('nfceContingency')} · ${s.t('saleNumber')} ${doc['number']} · ${s.t('series')} ${doc['series']}',
                  style: text.titleSmall),
              Center(child: QrImageView(data: '${doc['qrCode']}', size: 200, backgroundColor: Colors.white)),
              SelectableText('${doc['accessKey']}', textAlign: TextAlign.center, style: text.bodySmall),
            ],
            if (message != null) Text(message, style: text.bodySmall),
          ]);
        },
      );
}

/// Register operations: cash in/out, drawer summary, sales of the session (cancel) and closing.
class RegisterDialog extends StatefulWidget {
  const RegisterDialog({super.key, required this.controller});
  final PosController controller;

  @override
  State<RegisterDialog> createState() => _RegisterDialogState();
}

class _RegisterDialogState extends State<RegisterDialog> {
  final _amount = TextEditingController();
  final _notes = TextEditingController();
  final _reason = TextEditingController();
  String? _amountError;
  String? _reasonError;
  String? _saved;
  List<PosSaleResult> _sales = const [];

  @override
  void initState() {
    super.initState();
    // After the first frame: these notify the controller listeners, which must not happen while
    // the screen under the dialog is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.dismissError();
      widget.controller.refreshSession();
      _loadSales();
    });
  }

  Future<void> _loadSales() async {
    final sales = await widget.controller.sessionSales();
    if (mounted) setState(() => _sales = sales);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final session = widget.controller.session;
        return AlertDialog(
          title: Text(s.t('register')),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (session != null) ..._summary(s, session),
                ..._messages(s),
                MoneyField(controller: _amount, label: s.t('amount'), errorText: _amountError),
                TextField(controller: _notes, decoration: InputDecoration(labelText: s.t('notes'))),
                const SizedBox(height: 12),
                _movements(s),
                if (!widget.controller.deviceMode)
                  ..._sessionSales(s)
                else if (widget.controller.lastSale != null && widget.controller.lastSale!.commercialState == 'confirmed')
                  ..._cancelLastSale(s),
              ]),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('close')))],
        );
      },
    );
  }

  /// Drawer summary of the open session.
  List<Widget> _summary(S s, CashSession session) => [
        _TotalRow(label: s.t('openingAmount'), value: session.openingAmount),
        _TotalRow(label: s.t('sales'), value: session.saleTotal),
        for (final entry in session.totalsByMethod.entries)
          if (entry.key != 'cash') _TotalRow(label: s.t(entry.key), value: entry.value),
        if (session.cashSalesNet != null)
          _TotalRow(label: s.t('cashSalesNet'), value: session.cashSalesNet!)
        else if (session.totalsByMethod['cash'] case final cash?)
          _TotalRow(label: s.t('cash'), value: cash),
        if (session.supplyTotal != null && !session.supplyTotal!.isZero)
          _TotalRow(label: s.t('supplies'), value: session.supplyTotal!),
        if (session.withdrawalTotal != null && !session.withdrawalTotal!.isZero)
          _TotalRow(label: s.t('withdrawals'), value: -session.withdrawalTotal!),
        _TotalRow(label: s.t('expectedCash'), value: session.expectedCash, strong: true),
        if (session.pendingPayments > 0) Text('${s.t('pendingPayments')}: ${session.pendingPayments}'),
        const Divider(),
      ];

  /// Errors show here: the banner of the main screen is hidden behind this dialog.
  List<Widget> _messages(S s) {
    final error = widget.controller.error;
    final scheme = Theme.of(context).colorScheme;
    return [
      if (error != null) ...[
        Text(s.message(error), style: TextStyle(color: scheme.error)),
        const SizedBox(height: 8),
      ],
      if (_saved != null) ...[
        Text(_saved!, style: TextStyle(color: scheme.primary)),
        const SizedBox(height: 8),
      ],
    ];
  }

  Widget _movements(S s) {
    final busy = widget.controller.busy;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      OutlinedButton(onPressed: busy ? null : () => _movement('supply'), child: Text(s.t('supply'))),
      OutlinedButton(onPressed: busy ? null : () => _movement('withdrawal'), child: Text(s.t('withdrawal'))),
      FilledButton.tonal(
        onPressed: busy ? null : _close,
        child: Text('${s.t('closeSession')} (${s.t('countedCash')})'),
      ),
    ]);
  }

  /// Sales of the session, each cancellable while confirmed (online register).
  List<Widget> _sessionSales(S s) => [
        const Divider(height: 32),
        Text(s.t('sessionSales'), style: Theme.of(context).textTheme.titleMedium),
        if (_sales.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(s.t('noSessionSales')))
        else ...[
          TextField(
            controller: _reason,
            decoration: InputDecoration(labelText: s.t('reason'), errorText: _reasonError, errorMaxLines: 3),
          ),
          for (final sale in _sales) _saleTile(s, sale),
        ],
      ];

  Widget _saleTile(S s, PosSaleResult sale) {
    final String state;
    if (sale.commercialState == 'canceled') {
      state = s.t('canceled');
    } else {
      state = sale.paymentState == 'confirmed' ? s.t('paymentConfirmed') : s.t('paymentPending');
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${s.t('saleNumber')} ${sale.number} · ${fmt(sale.total)}'),
      subtitle: Text(state),
      trailing: sale.commercialState == 'confirmed'
          ? TextButton(
              onPressed: widget.controller.busy ? null : () => _cancel(sale),
              child: Text(s.t('cancelThisSale')),
            )
          : null,
    );
  }

  /// Installed device: only the last confirmed sale can be cancelled from here.
  List<Widget> _cancelLastSale(S s) {
    final last = widget.controller.lastSale!;
    return [
      const Divider(),
      TextField(controller: _reason, decoration: InputDecoration(labelText: s.t('reason'), errorText: _reasonError)),
      TextButton(
        onPressed: () => _cancel(last),
        child: Text('${s.t('cancelSale')} · ${last.number}'),
      ),
    ];
  }

  Decimal? _validAmount() {
    final amount = parseAmount(_amount.text);
    setState(() {
      _amountError = amount == null || amount.isNegative ? S.of(context).t('invalidAmount') : null;
      _saved = null;
    });
    return _amountError == null ? amount : null;
  }

  Future<void> _movement(String kind) async {
    final amount = _validAmount();
    if (amount == null) return;
    if (!amount.isPositive) {
      setState(() => _amountError = S.of(context).t('invalidAmount'));
      return;
    }
    final ok = await widget.controller.cashMovement(kind, amount, _notes.text.trim().isEmpty ? null : _notes.text.trim());
    if (!mounted) return;
    // The typed amount stays when the movement is refused, so the operator can correct it.
    if (ok) {
      _amount.clear();
      _notes.clear();
      setState(() => _saved = S.of(context).t('movementSaved'));
    }
  }

  Future<void> _close() async {
    final counted = _validAmount();
    if (counted == null) return;
    final ok = await widget.controller.closeSession(counted, _notes.text.trim().isEmpty ? null : _notes.text.trim());
    if (!ok || !mounted) return;
    final closed = widget.controller.lastClosedSession;
    Navigator.pop(context);
    if (closed != null) {
      await showDialog<void>(context: context, builder: (_) => SessionClosedDialog(session: closed));
    }
  }

  Future<void> _cancel(PosSaleResult sale) async {
    final reason = _reason.text.trim();
    setState(() => _reasonError = reason.isEmpty ? S.of(context).t('cancelReasonRequired') : null);
    if (reason.isEmpty) return;
    final result = await widget.controller.cancelSale(sale.uuid, reason);
    if (result != null && mounted) {
      _reason.clear();
      await _loadSales();
    }
  }
}

/// Closing summary: what the drawer should hold, what was counted and the difference.
class SessionClosedDialog extends StatelessWidget {
  const SessionClosedDialog({super.key, required this.session});
  final CashSession session;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final counted = session.countedCash ?? Decimal.zero();
    final difference = counted - session.expectedCash;
    return AlertDialog(
      title: Text(s.t('sessionClosed')),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _TotalRow(label: s.t('sales'), value: session.saleTotal),
          _TotalRow(label: s.t('expectedCash'), value: session.expectedCash),
          _TotalRow(label: s.t('countedCash'), value: counted),
          _TotalRow(label: s.t('difference'), value: difference, strong: true),
        ]),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(s.t('close')))],
    );
  }
}

/// Camera barcode reader (rear camera): returns the first product code it sees.
class CameraScanDialog extends StatefulWidget {
  const CameraScanDialog({super.key});

  @override
  State<CameraScanDialog> createState() => _CameraScanDialogState();
}

class _CameraScanDialogState extends State<CameraScanDialog> {
  late final MobileScannerController _scanner;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    prepareCameraScanner();
    _scanner = MobileScannerController(
      facing: CameraFacing.back,
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [
        BarcodeFormat.ean13,
        BarcodeFormat.ean8,
        BarcodeFormat.upcA,
        BarcodeFormat.upcE,
        BarcodeFormat.code128,
        BarcodeFormat.code39,
        BarcodeFormat.itf2of5,
      ],
    );
  }

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final code = capture.barcodes.map((b) => b.rawValue?.trim() ?? '').firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (code.isEmpty) return;
    _done = true;
    Navigator.pop(context, code);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return AlertDialog(
      title: Text(s.t('scanWithCamera')),
      content: SizedBox(
        width: 360,
        height: 300,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: MobileScanner(
            controller: _scanner,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(s.t('cameraUnavailable'), textAlign: TextAlign.center),
              ),
            ),
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel')))],
    );
  }
}
