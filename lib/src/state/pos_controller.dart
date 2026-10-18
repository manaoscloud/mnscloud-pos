import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/pos_api.dart';
import '../core/ids.dart';
import '../core/models.dart';
import '../core/money.dart';

enum ConnectionStatus { online, unreachable, unknown }

enum PosStage { signIn, tenant, terminal, openSession, selling }

/// Single source of truth of the POS screen state. On the web nothing is persisted locally: the
/// cart lives in memory and only a server confirmation shows a sale as saved.
class PosController extends ChangeNotifier {
  PosController(this.api);

  final PosApi api;

  PosStage stage = PosStage.signIn;
  ConnectionStatus connection = ConnectionStatus.unknown;
  SignedInUser? user;
  List<TenantOption> tenants = const [];
  TenantOption? tenant;
  List<PosTerminal> terminals = const [];
  PosTerminal? terminal;
  CashSession? session;
  final List<CartLine> cart = [];
  final List<PaymentEntry> payments = [];

  /// Sale being submitted: same UUID and payload until the server confirms it.
  Map<String, dynamic>? pendingSale;
  PosSaleResult? lastSale;
  String? error;
  bool busy = false;

  Decimal get subtotal => cart.fold(Decimal.zero(), (sum, line) => sum + line.gross);
  Decimal get discount => cart.fold(Decimal.zero(), (sum, line) => sum + line.discount);
  Decimal get total => subtotal - discount;
  Decimal get paid => payments.fold(Decimal.zero(), (sum, p) => sum + p.amount);
  Decimal get cashPaid => payments
      .where((p) => p.method == PaymentMethod.cash)
      .fold(Decimal.zero(), (sum, p) => sum + p.amount);
  Decimal get remaining => (total - paid).max(Decimal.zero());
  Decimal get change => (paid - total).max(Decimal.zero()).min(cashPaid);

  Future<T?> _run<T>(Future<T> Function() work) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final result = await work();
      connection = ConnectionStatus.online;
      return result;
    } on ApiException catch (e) {
      connection = e.kind == ApiFailureKind.unreachable ? ConnectionStatus.unreachable : ConnectionStatus.online;
      error = e.message;
      if (e.kind == ApiFailureKind.unauthorized && stage != PosStage.signIn) {
        stage = PosStage.signIn;
      }
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> restore() async {
    final current = await _run(api.currentUser);
    if (current == null) {
      stage = PosStage.signIn;
      notifyListeners();
      return;
    }
    user = current;
    await _afterSignIn();
  }

  Future<void> signIn(String email, String password) async {
    final signed = await _run(() => api.signIn(email, password));
    if (signed == null) return;
    user = signed;
    if (signed.jwt != null && !kIsWeb) api.client.bearerToken = signed.jwt;
    await _afterSignIn();
  }

  Future<void> _afterSignIn() async {
    final list = await _run(api.tenants);
    if (list == null) return;
    tenants = list;
    if (list.length == 1) {
      await selectTenant(list.first);
    } else {
      stage = PosStage.tenant;
      notifyListeners();
    }
  }

  Future<void> selectTenant(TenantOption option) async {
    tenant = option;
    api.client.environmentUuid = option.uuid;
    final list = await _run(api.terminals);
    if (list == null) return;
    terminals = list;
    stage = PosStage.terminal;
    notifyListeners();
  }

  Future<void> selectTerminal(PosTerminal value) async {
    final fresh = await _run(() => api.terminal(value.uuid));
    if (fresh == null) return;
    terminal = fresh;
    if (fresh.openSessionUuid != null) {
      session = await _run(() => api.session(fresh.openSessionUuid!));
      stage = session?.isOpen == true ? PosStage.selling : PosStage.openSession;
    } else {
      stage = PosStage.openSession;
    }
    notifyListeners();
  }

  void backToTerminals() {
    if (saleInDoubt) return;
    terminal = null;
    session = null;
    stage = PosStage.terminal;
    notifyListeners();
  }

  Future<void> openSession(Decimal openingAmount) async {
    final t = terminal;
    if (t == null) return;
    final key = 'open:${uuidV4()}';
    final opened = await _run(() => api.openSession(t.uuid, openingAmount.toString(), key));
    if (opened == null) return;
    session = opened;
    stage = PosStage.selling;
    notifyListeners();
  }

  Future<void> refreshSession() async {
    final s = session;
    if (s == null) return;
    final fresh = await _run(() => api.session(s.uuid));
    if (fresh != null) session = fresh;
    notifyListeners();
  }

  Future<void> cashMovement(String kind, Decimal amount, String? notes) async {
    final s = session;
    if (s == null) return;
    final key = '$kind:${uuidV4()}';
    final fresh = await _run(() => api.cashMovement(s.uuid, kind, amount.toString(), notes, key));
    if (fresh != null) session = fresh;
    notifyListeners();
  }

  Future<bool> closeSession(Decimal counted, String? notes) async {
    final s = session;
    if (s == null) return false;
    final closed = await _run(() => api.closeSession(s.uuid, counted.toString(), notes));
    if (closed == null) return false;
    session = closed;
    stage = PosStage.openSession;
    clearSale();
    notifyListeners();
    return true;
  }

  Future<List<CatalogItem>> search(String text) async {
    final t = terminal;
    if (t == null || text.trim().isEmpty) return const [];
    return await _run(() => api.catalog(t.uuid, search: text.trim())) ?? const [];
  }

  /// Scanner input: adds the item of the code; packaging codes add their quantity.
  Future<bool> scan(String code) async {
    final t = terminal;
    if (t == null || code.trim().isEmpty) return false;
    final found = await _run(() => api.catalog(t.uuid, barcode: code.trim(), limit: 1));
    if (found == null || found.isEmpty) {
      error ??= 'No item uses this code.';
      notifyListeners();
      return false;
    }
    addItem(found.first);
    return true;
  }

  void addItem(CatalogItem item, [Decimal? qty]) {
    if (saleInDoubt) return;
    final amount = qty ?? Decimal.fromInt(1, 6);
    final existing = cart.where((l) => l.item.uuid == item.uuid && l.discount.isZero);
    if (existing.isNotEmpty) {
      existing.first.quantity = existing.first.quantity + amount;
    } else {
      cart.add(CartLine(item: item, quantity: amount));
    }
    payments.clear();
    notifyListeners();
  }

  void setQuantity(CartLine line, Decimal value) {
    if (saleInDoubt) return;
    if (value <= Decimal.zero(6)) {
      cart.remove(line);
    } else {
      line.quantity = value;
    }
    payments.clear();
    notifyListeners();
  }

  /// Applies a line discount within the terminal limit (the server checks it again).
  String? setDiscount(CartLine line, Decimal value) {
    if (saleInDoubt) return 'A sale is waiting for the server confirmation.';
    final limit = line.gross.percent(terminal?.maxDiscountPercent ?? Decimal.zero());
    if (value.isNegative || value > limit) return 'Discount above the terminal limit.';
    line.discount = value;
    payments.clear();
    notifyListeners();
    return null;
  }

  void removeLine(CartLine line) {
    if (saleInDoubt) return;
    cart.remove(line);
    payments.clear();
    notifyListeners();
  }

  void addPayment(PaymentEntry entry) {
    if (saleInDoubt) return;
    payments.add(entry);
    notifyListeners();
  }

  void removePayment(PaymentEntry entry) {
    if (saleInDoubt) return;
    payments.remove(entry);
    notifyListeners();
  }

  /// A submitted sale whose answer was lost: the cart is frozen until the server tells whether it
  /// was stored, so the retry can never become a second, different sale.
  bool get saleInDoubt => pendingSale != null;

  bool get canFinish => cart.isNotEmpty && total.isPositive && paid >= total && change <= cashPaid;

  Map<String, dynamic> _buildPayload() => {
        'saleUUID': uuidV4(),
        'terminalUUID': terminal!.uuid,
        'sessionUUID': session!.uuid,
        'origin': 'web',
        'contractVersion': 1,
        'occurredAt': DateTime.now().toUtc().toIso8601String(),
        'items': [
          for (final line in cart)
            {
              'productUUID': line.item.uuid,
              'quantity': line.quantity.toString(),
              'unitPrice': line.item.price.toString(),
              'discount': line.discount.toString(),
            }
        ],
        'payments': [for (final p in payments) p.toJson()],
        'change': change.toString(),
      };

  /// Finishes the sale. Shows success only after the server stored it; on an unknown outcome the
  /// cart is kept with the same sale identity so a retry can never create a second sale.
  Future<PosSaleResult?> finish() async {
    if (!canFinish || terminal == null || session == null) return null;
    pendingSale ??= _buildPayload();
    final outcome = await _run(() => api.submitSale(pendingSale!));
    if (outcome == null) {
      // Business rejection: nothing was saved; a corrected sale gets a new identity.
      if (connection != ConnectionStatus.unreachable) pendingSale = null;
      return null;
    }
    if (outcome.pending) {
      connection = ConnectionStatus.unreachable;
      error = 'The sale was not confirmed by the server. Check the connection and try again: '
          'it will not be duplicated.';
      notifyListeners();
      return null;
    }
    lastSale = outcome.sale;
    clearSale();
    await refreshSession();
    return lastSale;
  }

  /// Gives up a sale whose outcome stayed unknown only after the server confirmed it does not exist.
  Future<bool> discardSaleInDoubt() async {
    final pending = pendingSale;
    if (pending == null) return true;
    final existing = await _run(() => api.sale(pending['saleUUID'] as String));
    if (connection == ConnectionStatus.unreachable) return false;
    if (existing != null) {
      lastSale = existing;
      clearSale();
      await refreshSession();
      return true;
    }
    pendingSale = null;
    notifyListeners();
    return true;
  }

  void clearSale() {
    cart.clear();
    payments.clear();
    pendingSale = null;
    notifyListeners();
  }

  Future<PosSaleResult?> cancelSale(String saleUuid, String reason) async {
    final result = await _run(() => api.cancelSale(saleUuid, reason));
    if (result != null) {
      lastSale = result;
      await refreshSession();
    }
    return result;
  }

  Future<Map<String, dynamic>?> pixCharge(String paymentUuid) => _run(() => api.pixCharge(paymentUuid));

  Future<Map<String, dynamic>?> paymentStatus(String paymentUuid) => _run(() => api.payment(paymentUuid));

  Future<PosSaleResult?> confirmCard(String paymentUuid, String nsu, String? code) async {
    final result = await _run(() => api.confirmCard(paymentUuid, nsu, code));
    if (result != null) lastSale = result;
    return result;
  }

  void dismissError() {
    error = null;
    notifyListeners();
  }
}
