import '../core/canonical_json.dart';
import '../core/models.dart';
import 'api_client.dart';

class TenantOption {
  TenantOption(this.uuid, this.name, this.code);
  final String uuid;
  final String name;
  final String? code;
}

class SignedInUser {
  SignedInUser({required this.uuid, required this.name, required this.email, this.jwt, this.environmentUuid});
  final String uuid;
  final String name;
  final String email;
  final String? jwt;
  final String? environmentUuid;
}

/// Outcome of a sale submission. `pending` means the answer is unknown and the same sale (same
/// UUID and payload) must be checked or resent later; it is never shown as saved.
class SubmitOutcome {
  SubmitOutcome.saved(this.sale) : pending = false;
  SubmitOutcome.unknown() : sale = null, pending = true;
  final PosSaleResult? sale;
  final bool pending;
}

List<Map<String, dynamic>> _items(dynamic data) {
  final items = data is Map ? data['items'] : data;
  if (items is! List) return const [];
  return items.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
}

class PosApi {
  PosApi(this.client);
  final ApiClient client;

  Future<SignedInUser> signIn(String email, String password) async {
    final data = await client.post('auth/signin', {'email': email, 'password': password, 'rememberMe': false});
    final user = (data is Map ? data['user'] : null) as Map? ?? const {};
    return SignedInUser(
      uuid: user['uuid']?.toString() ?? '',
      name: user['name']?.toString() ?? '',
      email: user['email']?.toString() ?? email,
      jwt: data is Map ? data['jwt']?.toString() : null,
      environmentUuid: user['EnvironmentUUID']?.toString(),
    );
  }

  /// Ends the session on the server (revokes the token and clears the web cookie).
  Future<void> signOut() async {
    await client.post('auth/signout', const {});
  }

  /// Current session (web: cookie set by the App or by the POS sign-in).
  Future<SignedInUser?> currentUser() async {
    try {
      final data = await client.get('user/me');
      final user = (data is Map ? (data['user'] ?? data) : null) as Map? ?? const {};
      return SignedInUser(
        uuid: (user['uuid'] ?? user['UserUUID'] ?? '').toString(),
        name: (user['name'] ?? user['Name'] ?? '').toString(),
        email: (user['email'] ?? user['Email'] ?? '').toString(),
        environmentUuid: user['EnvironmentUUID']?.toString(),
      );
    } on ApiException catch (e) {
      if (e.kind == ApiFailureKind.unauthorized) return null;
      rethrow;
    }
  }

  Future<List<TenantOption>> tenants() async {
    final data = await client.get('user/access');
    final rows = data is Map ? (data['access'] ?? const []) : const [];
    return (rows as List)
        .whereType<Map>()
        .map((r) => TenantOption(
              (r['EnvironmentUUID'] ?? '').toString(),
              (r['EnvironmentName'] ?? '').toString(),
              r['TenantCode']?.toString(),
            ))
        .where((t) => t.uuid.isNotEmpty)
        .toList();
  }

  Future<List<PosTerminal>> terminals() async =>
      _items(await client.get('pos/terminals', {'status': '1', 'limit': '200'})).map(PosTerminal.fromJson).toList();

  Future<PosTerminal> terminal(String uuid) async =>
      PosTerminal.fromJson((await client.get('pos/terminals/$uuid') as Map).cast<String, dynamic>());

  Future<CashSession> session(String uuid) async =>
      CashSession.fromJson((await client.get('pos/sessions/$uuid') as Map).cast<String, dynamic>());

  Future<CashSession> openSession(String terminalUuid, String openingAmount, String idempotencyKey) async =>
      CashSession.fromJson((await client.post(
        'pos/sessions',
        {'terminalUUID': terminalUuid, 'openingAmount': openingAmount, 'idempotencyKey': idempotencyKey},
      ) as Map)
          .cast<String, dynamic>());

  Future<CashSession> cashMovement(String sessionUuid, String kind, String amount, String? notes, String key) async =>
      CashSession.fromJson((await client.post(
        'pos/sessions/$sessionUuid/movements',
        {'kind': kind, 'amount': amount, 'notes': notes, 'idempotencyKey': key},
      ) as Map)
          .cast<String, dynamic>());

  Future<CashSession> closeSession(String sessionUuid, String countedCash, String? notes) async =>
      CashSession.fromJson((await client.post(
        'pos/sessions/$sessionUuid/close',
        {'countedCash': countedCash, 'notes': notes},
      ) as Map)
          .cast<String, dynamic>());

  Future<List<CatalogItem>> catalog(String terminalUuid, {String? search, String? barcode, int limit = 50}) async =>
      _items(await client.get('pos/terminals/$terminalUuid/catalog', {
        if (search != null && search.isNotEmpty) 'search': search,
        if (barcode != null && barcode.isNotEmpty) 'barcode': barcode,
        'limit': '$limit',
      }))
          .map(CatalogItem.fromJson)
          .toList();

  Future<PosSaleResult?> sale(String uuid) async {
    try {
      return PosSaleResult.fromJson((await client.get('pos/sales/$uuid') as Map).cast<String, dynamic>());
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// Submits a sale and resolves lost answers: on an unknown outcome it reads the sale back by its
  /// UUID; if the server never saw it, it resends the identical payload once (idempotent).
  Future<SubmitOutcome> submitSale(Map<String, dynamic> payload) async {
    final body = {'sale': payload, 'payloadHash': payloadHash(payload)};
    final uuid = payload['saleUUID'] as String;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final data = await client.post('pos/sales', body, idempotencyKey: uuid);
        return SubmitOutcome.saved(PosSaleResult.fromJson((data as Map).cast<String, dynamic>()));
      } on ApiException catch (e) {
        if (!e.outcomeUnknown) rethrow;
        try {
          final existing = await sale(uuid);
          if (existing != null) return SubmitOutcome.saved(existing);
        } on ApiException catch (check) {
          if (!check.outcomeUnknown) rethrow;
          return SubmitOutcome.unknown();
        }
      }
    }
    return SubmitOutcome.unknown();
  }

  Future<PosSaleResult> cancelSale(String uuid, String reason) async =>
      PosSaleResult.fromJson((await client.post('pos/sales/$uuid/cancel', {'reason': reason}) as Map).cast<String, dynamic>());

  /// Creates (or returns) the Pix charge of a pending payment; `pixCopyPaste` feeds the QR code.
  Future<Map<String, dynamic>> pixCharge(String paymentUuid) async =>
      (await client.post('pos/payments/$paymentUuid/pix', const {}) as Map).cast<String, dynamic>();

  /// Payment state, refreshed from the gateway for Pix.
  Future<Map<String, dynamic>> payment(String paymentUuid) async =>
      (await client.get('pos/payments/$paymentUuid') as Map).cast<String, dynamic>();

  Future<PosSaleResult> confirmCard(String paymentUuid, String nsu, String? authorizationCode) async =>
      PosSaleResult.fromJson((await client.post('pos/payments/$paymentUuid/confirm', {
        'source': 'terminal',
        'providerReference': nsu,
        'authorizationCode': authorizationCode,
      }) as Map)
          .cast<String, dynamic>());

  Future<PosSaleResult> declinePayment(String paymentUuid) async =>
      PosSaleResult.fromJson((await client.post('pos/payments/$paymentUuid/decline', const {}) as Map).cast<String, dynamic>());
}
