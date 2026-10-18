import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/pos_api.dart';
import '../core/ids.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../offline/device_host.dart';
import '../offline/device_runtime.dart';
import '../offline/device_sync_api.dart' as device_api;
import '../offline/p256.dart';
import '../offline/sync_engine.dart';
import '../fiscal/fiscal_device.dart';
import '../version/app_build_info.dart';

enum ConnectionStatus { online, unreachable, unknown }

enum PosStage { signIn, tenant, terminal, openSession, selling }

/// Single source of truth of the POS screen state. On the web nothing is persisted locally: the
/// cart lives in memory and only a server confirmation shows a sale as saved. An installed app
/// whose terminal is provisioned on this device works local-first ([DeviceRuntime]): sales and
/// cash events are stored on the device and synchronized, online or offline.
class PosController extends ChangeNotifier {
  PosController(this.api, {this.host});

  final PosApi api;

  /// Local store and secure storage of installed apps (null on the web).
  final DeviceHost? host;

  /// Local-first runtime of the provisioned terminal (null = online mode).
  DeviceRuntime? device;
  FiscalDevice? _fiscal;
  Timer? _syncTimer;
  String? syncMessage;

  /// NFC-e of the last sale on an installed device: 'online', 'contingency' (signed offline) or null.
  String? lastFiscalMode;
  Map<String, dynamic>? lastFiscalDocument;
  String? fiscalMessage;

  bool get deviceMode => device != null;

  /// The installed app may provision this terminal for offline operation.
  bool get canProvisionDevice => host != null && device == null && terminal?.offlineEnabled == true;

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
    if (await _attachDevice(fresh)) {
      session = device!.localSession();
      stage = session == null ? PosStage.openSession : PosStage.selling;
      notifyListeners();
      unawaited(syncNow());
      return;
    }
    if (fresh.openSessionUuid != null) {
      session = await _run(() => api.session(fresh.openSessionUuid!));
      stage = session?.isOpen == true ? PosStage.selling : PosStage.openSession;
    } else {
      stage = PosStage.openSession;
    }
    notifyListeners();
  }

  /// Ends the operator session on this screen: the server revokes the token (and the web cookie),
  /// and everything kept in memory (user, tenant, register, cart) is dropped. The cash session
  /// stays open on the server for the next operator. Refused while a sale submit is in doubt, so
  /// a sale is never lost. Local state is cleared even when the server cannot be reached.
  Future<bool> signOut() async {
    if (saleInDoubt) {
      error = 'A sale is still being confirmed. Wait for it before signing out.';
      notifyListeners();
      return false;
    }
    busy = true;
    notifyListeners();
    String? failure;
    try {
      await api.signOut();
    } on ApiException catch (e) {
      // An expired session is already signed out on the server.
      if (e.kind != ApiFailureKind.unauthorized) failure = e.message;
    }
    _detachDevice();
    api.client.bearerToken = null;
    api.client.environmentUuid = null;
    user = null;
    tenants = const [];
    tenant = null;
    terminals = const [];
    terminal = null;
    session = null;
    lastSale = null;
    cart.clear();
    payments.clear();
    pendingSale = null;
    busy = false;
    error = failure == null ? null : 'Signed out on this screen, but the server session could not be ended: $failure';
    stage = PosStage.signIn;
    notifyListeners();
    return true;
  }

  void backToTerminals() {
    if (saleInDoubt) return;
    _detachDevice();
    terminal = null;
    session = null;
    stage = PosStage.terminal;
    notifyListeners();
  }

  Future<void> openSession(Decimal openingAmount) async {
    final t = terminal;
    if (t == null) return;
    if (deviceMode) {
      _local(() {
        session = device!.openSession(user!.uuid, openingAmount);
        stage = PosStage.selling;
      });
      return;
    }
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
    if (deviceMode) {
      session = device!.localSession();
      notifyListeners();
      return;
    }
    final fresh = await _run(() => api.session(s.uuid));
    if (fresh != null) session = fresh;
    notifyListeners();
  }

  Future<void> cashMovement(String kind, Decimal amount, String? notes) async {
    final s = session;
    if (s == null) return;
    if (deviceMode) {
      _local(() => session = device!.cashMovement(user!.uuid, s.uuid, kind, amount, notes));
      return;
    }
    final key = '$kind:${uuidV4()}';
    final fresh = await _run(() => api.cashMovement(s.uuid, kind, amount.toString(), notes, key));
    if (fresh != null) session = fresh;
    notifyListeners();
  }

  Future<bool> closeSession(Decimal counted, String? notes) async {
    final s = session;
    if (s == null) return false;
    if (deviceMode) {
      final ok = _local(() => device!.closeSession(user!.uuid, s.uuid, counted, notes));
      if (!ok) return false;
      session = null;
      stage = PosStage.openSession;
      clearSale();
      notifyListeners();
      return true;
    }
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
    if (deviceMode) return device!.search(text);
    return await _run(() => api.catalog(t.uuid, search: text.trim())) ?? const [];
  }

  /// Scanner input: adds the item of the code; packaging codes add their quantity.
  Future<bool> scan(String code) async {
    final t = terminal;
    if (t == null || code.trim().isEmpty) return false;
    if (deviceMode) {
      final local = device!.scan(code);
      if (local == null) {
        error = 'No item uses this code.';
        notifyListeners();
        return false;
      }
      addItem(local.item, local.quantity);
      return true;
    }
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
    if (deviceMode) return _finishOnDevice();
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

  // ---------- Installed device (local-first)

  /// Runs a local write; a storage failure (disk full, I/O) shows an error and nothing as saved.
  bool _local(void Function() work) {
    error = null;
    try {
      work();
      notifyListeners();
      unawaited(syncNow());
      return true;
    } on OfflineLimitException catch (e) {
      error = e.message;
    } catch (e) {
      error = 'This device could not store the operation ($e). Nothing was saved.';
    }
    notifyListeners();
    return false;
  }

  PosSaleResult? _finishOnDevice() {
    final base = _buildPayload()..remove('origin');
    final totalNow = total;
    final changeNow = change;
    final cashNet = cashPaid - changeNow;
    final cartCopy = List<CartLine>.of(cart);
    final paymentsCopy = List<PaymentEntry>.of(payments);
    Map<String, dynamic>? stored;
    final ok = _local(() => stored = device!.recordSale(user!.uuid, base, totalNow, cashNet, cart));
    if (!ok || stored == null) return null;
    lastSale = PosSaleResult(
      uuid: stored!['saleUUID'] as String,
      number: '',
      total: totalNow,
      change: changeNow,
      commercialState: 'confirmed',
      paymentState: payments.every((p) => p.declaredState == 'confirmed' || p.declaredState == 'authorized')
          ? 'confirmed'
          : 'pending',
      fiscalState: 'none',
      syncState: 'pending',
      payments: [for (final p in payments) p.toJson()],
    );
    clearSale();
    session = device!.localSession();
    lastFiscalMode = null;
    lastFiscalDocument = null;
    fiscalMessage = null;
    notifyListeners();
    final operationUuid = device!.lastSaleOperationUuid;
    if (_fiscal?.enabled == true && operationUuid != null) {
      unawaited(_fiscalAfterSale(stored!, cartCopy, paymentsCopy, changeNow.toString(), operationUuid));
    }
    return lastSale;
  }

  /// NFC-e of a device sale: online when the server already has the sale, otherwise signed on the
  /// device in offline contingency (queued after the sale; the server transmits it later).
  Future<void> _fiscalAfterSale(
      Map<String, dynamic> sale, List<CartLine> cart, List<PaymentEntry> paid, String change, String saleOperation) async {
    final d = device;
    final f = _fiscal;
    if (d == null || f == null) return;
    await syncNow();
    final status = d.store.operationStatus(saleOperation);
    if (status == 'done' || status == 'conflict') {
      try {
        await api.client.post('fiscal/pos-sales/${sale['saleUUID']}/nfce', const {});
        lastFiscalMode = 'online';
        fiscalMessage = 'NFC-e sent to the tax authority.';
        notifyListeners();
        return;
      } on ApiException catch (e) {
        if (e.kind != ApiFailureKind.unreachable) {
          fiscalMessage = e.message;
          notifyListeners();
          return;
        }
      }
    }
    try {
      lastFiscalDocument = await f.emitContingency(
        sale: sale,
        cart: cart,
        payments: paid,
        change: change,
        operatorUuid: user!.uuid,
        saleOperationUuid: saleOperation,
        grantUuid: d.grant?.uuid,
      );
      lastFiscalMode = 'contingency';
      fiscalMessage = 'NFC-e issued in offline contingency; it is sent as soon as the connection returns.';
    } catch (error) {
      fiscalMessage = 'NFC-e not issued: $error';
    }
    notifyListeners();
    unawaited(syncNow());
  }

  /// Attaches the local runtime when this installation is provisioned for [t].
  Future<bool> _attachDevice(PosTerminal t) async {
    final h = host;
    if (h == null || !t.offlineEnabled) return false;
    final raw = h.store.meta('device');
    if (raw == null) return false;
    final row = (jsonDecode(raw) as Map).cast<String, dynamic>();
    if (normalizeUuid(row['PosTerminalPtmUUID'].toString()) != t.uuid) return false;
    final key = await h.loadKey();
    if (key == null) return false;
    _startDevice(h, key, normalizeUuid(row['SdvUUID'].toString()), t.uuid);
    return true;
  }

  void _startDevice(DeviceHost h, P256Key key, String deviceUuid, String terminalUuid) {
    final transport = device_api.DeviceSyncApi(api.client, h.store, key, deviceUuid, appVersion: appBuildInfo.version);
    _fiscal = FiscalDevice(h.store, h, transport);
    device = DeviceRuntime(
      store: h.store,
      engine: SyncEngine(h.store, transport),
      deviceUuid: deviceUuid,
      terminalUuid: terminalUuid,
    );
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) => syncNow());
  }

  void _detachDevice() {
    _syncTimer?.cancel();
    _syncTimer = null;
    device = null;
    _fiscal = null;
  }

  /// Provisions this installation for the selected terminal (online, by an authorized user).
  Future<bool> provisionDevice(String name) async {
    final h = host;
    final t = terminal;
    if (h == null || t == null) return false;
    final key = P256Key.generate();
    final row = await _run(() => device_api.provisionDevice(api.client,
        key: key, terminalUuid: t.uuid, name: name, platform: h.platform, appVersion: appBuildInfo.version));
    if (row == null) return false;
    await h.saveKey(key);
    h.store.setMeta('device', jsonEncode(row));
    _startDevice(h, key, normalizeUuid(row['SdvUUID'].toString()), t.uuid);
    session = device!.localSession();
    stage = session == null ? PosStage.openSession : PosStage.selling;
    notifyListeners();
    await syncNow();
    return true;
  }

  /// Pushes pending operations and refreshes the catalog; failures leave everything stored.
  Future<void> syncNow() async {
    final d = device;
    if (d == null) return;
    try {
      final report = await d.engine.sync();
      connection = report.reachable ? ConnectionStatus.online : ConnectionStatus.unreachable;
      syncMessage = null;
      // Offline NFC-e configuration: at most every 10 minutes while reachable.
      final last = DateTime.tryParse(d.store.meta('fiscal_refreshed_at') ?? '');
      if (report.reachable && _fiscal != null && (last == null || DateTime.now().difference(last).inMinutes >= 10)) {
        try {
          await _fiscal!.refresh();
          d.store.setMeta('fiscal_refreshed_at', DateTime.now().toIso8601String());
        } catch (_) {
          // Not enabled or not configured yet: sales go on; the NFC-e is issued online.
        }
      }
    } on ApiException catch (e) {
      if (e.code == 'DEVICE_SUSPENDED' || e.code == 'DEVICE_REVOKED') {
        syncMessage = 'This device was blocked by the server (${e.code}). Ask the manager to provision it again.';
      } else {
        syncMessage = e.message;
      }
    } catch (e) {
      syncMessage = e.toString();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    super.dispose();
  }
}
