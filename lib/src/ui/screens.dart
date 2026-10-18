import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/models.dart';
import '../core/money.dart';
import '../platform/session.dart';
import '../state/pos_controller.dart';
import 'strings.dart';

String fmt(Decimal value) => value.format();

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
          return Scaffold(
            appBar: controller.stage == PosStage.signIn ? null : PosStatusBar(controller: controller),
            body: SafeArea(
              child: Column(children: [
                if (controller.error != null) ErrorBanner(controller: controller),
                Expanded(child: body),
              ]),
            ),
          );
        },
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
    final session = controller.session;
    return AppBar(
      titleSpacing: 16,
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          [s.t('app'), if (terminal != null) terminal.name].join(' · '),
          style: Theme.of(context).textTheme.titleMedium,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          [
            if (terminal != null) terminal.companyName,
            if (controller.tenant != null) controller.tenant!.name,
            if (controller.user != null) controller.user!.name.isNotEmpty ? controller.user!.name : controller.user!.email,
            if (session != null && session.isOpen) '${s.t('sales')}: ${session.saleCount}',
          ].join(' · '),
          style: Theme.of(context).textTheme.bodySmall,
          overflow: TextOverflow.ellipsis,
        ),
      ]),
      actions: [
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
      ],
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.controller});
  final PosController controller;

  @override
  Widget build(BuildContext context) => MaterialBanner(
        content: Text(controller.error ?? ''),
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

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() => widget.controller.signIn(_email.text.trim(), _password.text);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return _CenteredCard(
      child: AutofillGroup(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('MNSCloud ${s.t('app')}', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          if (isWebPlatform) Text(s.t('webOnline'), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          TextField(
            controller: _email,
            decoration: InputDecoration(labelText: s.t('email')),
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            decoration: InputDecoration(labelText: s.t('password')),
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: widget.controller.busy ? null : _submit,
            child: widget.controller.busy
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(s.t('signIn')),
          ),
        ]),
      ),
    );
  }
}

class TenantView extends StatelessWidget {
  const TenantView({super.key, required this.controller});
  final PosController controller;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return _CenteredCard(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(s.t('chooseTenant'), style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        for (final t in controller.tenants)
          ListTile(
            leading: const Icon(Icons.apartment),
            title: Text(t.name.isEmpty ? t.uuid : t.name),
            subtitle: t.code == null ? null : Text(t.code!),
            onTap: () => controller.selectTenant(t),
          ),
      ]),
    );
  }
}

class TerminalView extends StatelessWidget {
  const TerminalView({super.key, required this.controller});
  final PosController controller;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return _CenteredCard(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(s.t('chooseTerminal'), style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (controller.terminals.isEmpty) Text(s.t('noTerminals')),
        for (final t in controller.terminals)
          ListTile(
            leading: Icon(t.openSessionUuid != null ? Icons.lock_open : Icons.point_of_sale),
            title: Text(t.name),
            subtitle: Text('${t.companyName} · ${t.locationName}'),
            onTap: () => controller.selectTerminal(t),
          ),
      ]),
    );
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

  @override
  void dispose() {
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
        MoneyField(controller: _amount, label: s.t('openingAmount')),
        const SizedBox(height: 20),
        FilledButton.icon(
          icon: const Icon(Icons.lock_open),
          onPressed: widget.controller.busy
              ? null
              : () => widget.controller.openSession(Decimal.tryParse(_amount.text) ?? Decimal.zero()),
          label: Text(s.t('openSession')),
        ),
        TextButton(onPressed: widget.controller.backToTerminals, child: Text(s.t('switchTerminal'))),
      ]),
    );
  }
}

class MoneyField extends StatelessWidget {
  const MoneyField({super.key, required this.controller, required this.label, this.onSubmitted, this.autofocus = false});
  final TextEditingController controller;
  final String label;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        autofocus: autofocus,
        decoration: InputDecoration(labelText: label),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
        onSubmitted: onSubmitted,
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
  });
  final TextEditingController search;
  final FocusNode focus;
  final List<CatalogItem> results;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<CatalogItem> onPick;

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
          decoration: InputDecoration(prefixIcon: const Icon(Icons.qr_code_scanner), labelText: s.t('search')),
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
                  if (item.available != null) '${s.t('quantity')}: ${item.available!.format(places: 0)}',
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
        Expanded(
          child: controller.cart.isEmpty
              ? Center(child: Text(s.t('emptyCart')))
              : ListView.separated(
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
                ),
        ),
        const Divider(),
        _TotalRow(label: s.t('subtotal'), value: controller.subtotal),
        if (!controller.discount.isZero) _TotalRow(label: s.t('discount'), value: -controller.discount),
        _TotalRow(label: s.t('total'), value: controller.total, strong: true),
        const SizedBox(height: 8),
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
        if (controller.saleInDoubt) ...[
          const SizedBox(height: 8),
          Text(s.t('inDoubt'), style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 12),
        Row(children: [
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
              onPressed: controller.busy || !controller.canFinish
                  ? null
                  : () async {
                      final sale = await controller.finish();
                      if (sale != null && context.mounted) {
                        await showDialog(context: context, builder: (_) => SaleDoneDialog(controller: controller, sale: sale));
                      }
                    },
              label: Text(controller.saleInDoubt ? s.t('retry') : s.t('finish')),
            ),
          ),
        ]),
        if (controller.saleInDoubt)
          TextButton(onPressed: controller.discardSaleInDoubt, child: Text(s.t('checkSale')))
        else if (controller.cart.isNotEmpty)
          TextButton(onPressed: controller.clearSale, child: Text(s.t('clear'))),
      ]),
    );
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
  String? _error;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return AlertDialog(
      title: Text(widget.line.item.name),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        MoneyField(controller: _qty, label: s.t('quantity'), autofocus: true),
        const SizedBox(height: 12),
        MoneyField(controller: _discount, label: s.t('discount')),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
        FilledButton(
          onPressed: () {
            final qty = Decimal.tryParse(_qty.text, 6);
            final discount = Decimal.tryParse(_discount.text) ?? Decimal.zero();
            if (qty == null) return;
            widget.controller.setQuantity(widget.line, qty);
            if (qty.isPositive) {
              final problem = widget.controller.setDiscount(widget.line, discount);
              if (problem != null) {
                setState(() => _error = problem);
                return;
              }
            }
            Navigator.pop(context);
          },
          child: Text(s.t('confirm')),
        ),
      ],
    );
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

  @override
  void initState() {
    super.initState();
    final accepted = widget.controller.terminal?.paymentMethods ?? const ['cash'];
    _method = PaymentMethodCode.fromCode(accepted.first);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final accepted = widget.controller.terminal?.paymentMethods ?? const ['cash'];
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
          const SizedBox(height: 12),
          MoneyField(controller: _amount, label: s.t('amount'), autofocus: true),
          if (card) ...[
            const SizedBox(height: 12),
            TextField(controller: _nsu, decoration: InputDecoration(labelText: s.t('nsu'))),
            const SizedBox(height: 8),
            TextField(controller: _auth, decoration: InputDecoration(labelText: s.t('authCode'))),
            const SizedBox(height: 8),
            Text(s.t('cardHint'), style: Theme.of(context).textTheme.bodySmall),
          ],
          if (_method == PaymentMethod.pix) ...[
            const SizedBox(height: 8),
            Text(s.t('pixHint'), style: Theme.of(context).textTheme.bodySmall),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
        FilledButton(
          onPressed: () {
            final amount = Decimal.tryParse(_amount.text);
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
          },
          child: Text(s.t('add')),
        ),
      ],
    );
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

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Iterable<Map<String, dynamic>> get _pending =>
      _sale.payments.where((p) => p['PspState'] == 'pending' || p['PspState'] == 'unknown');

  Future<void> _generatePix(String paymentUuid) async {
    final charge = await widget.controller.pixCharge(paymentUuid);
    final code = charge?['pixCopyPaste']?.toString();
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
    return AlertDialog(
      title: Text('${s.t('saleSaved')} · ${s.t('saleNumber')} ${_sale.number}'),
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
            if (p['PspMethod'] == 'pix') ...[
              const SizedBox(height: 8),
              if (_pixCodes[p['PspUUID'].toString()] case final code?) ...[
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
            ],
          const SizedBox(height: 12),
          Text(s.t('noFiscal'), style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(s.t('close')))],
    );
  }
}

/// Register operations: cash in/out, summary and closing.
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

  @override
  void initState() {
    super.initState();
    widget.controller.refreshSession();
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
                if (session != null) ...[
                  _TotalRow(label: s.t('openingAmount'), value: session.openingAmount),
                  _TotalRow(label: s.t('sales'), value: session.saleTotal),
                  for (final entry in session.totalsByMethod.entries) _TotalRow(label: s.t(entry.key), value: entry.value),
                  _TotalRow(label: s.t('expectedCash'), value: session.expectedCash, strong: true),
                  if (session.pendingPayments > 0) Text('${s.t('pendingPayments')}: ${session.pendingPayments}'),
                  const Divider(),
                ],
                MoneyField(controller: _amount, label: s.t('amount')),
                TextField(controller: _notes, decoration: InputDecoration(labelText: s.t('notes'))),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton(
                    onPressed: () => _movement('supply'),
                    child: Text(s.t('supply')),
                  ),
                  OutlinedButton(
                    onPressed: () => _movement('withdrawal'),
                    child: Text(s.t('withdrawal')),
                  ),
                  FilledButton.tonal(
                    onPressed: () async {
                      final counted = Decimal.tryParse(_amount.text);
                      if (counted == null) return;
                      final ok = await widget.controller.closeSession(counted, _notes.text.trim().isEmpty ? null : _notes.text.trim());
                      if (ok && context.mounted) Navigator.pop(context);
                    },
                    child: Text('${s.t('closeSession')} (${s.t('countedCash')})'),
                  ),
                ]),
                if (widget.controller.lastSale != null &&
                    widget.controller.lastSale!.commercialState == 'confirmed') ...[
                  const Divider(),
                  TextField(controller: _reason, decoration: InputDecoration(labelText: s.t('reason'))),
                  TextButton(
                    onPressed: () async {
                      if (_reason.text.trim().isEmpty) return;
                      await widget.controller.cancelSale(widget.controller.lastSale!.uuid, _reason.text.trim());
                    },
                    child: Text('${s.t('cancelSale')} · ${widget.controller.lastSale!.number}'),
                  ),
                ],
              ]),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('close')))],
        );
      },
    );
  }

  Future<void> _movement(String kind) async {
    final amount = Decimal.tryParse(_amount.text);
    if (amount == null || !amount.isPositive) return;
    await widget.controller.cashMovement(kind, amount, _notes.text.trim().isEmpty ? null : _notes.text.trim());
    _amount.clear();
    _notes.clear();
  }
}

