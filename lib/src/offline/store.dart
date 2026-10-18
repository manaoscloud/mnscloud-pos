/// Local storage of installed apps (never used on the web). Every write that the operator sees as
/// done (sale, cash event) is stored together with its outbox operation in ONE transaction; a
/// failed write (disk full, I/O error) throws and nothing is shown as saved.
abstract class OfflineStore {
  // ---------- Device state (device, grant, terminal, cursor, counter, cart draft)

  String? meta(String key);
  void setMeta(String key, String? value);

  /// Next request counter, persisted before the request is sent (monotonic across restarts).
  int nextCounter();

  // ---------- Catalog

  void beginBootstrap();
  void stageCatalog(List<Map<String, dynamic>> items);

  /// Replaces the catalog with the staged bootstrap and stores the change cursor, atomically: an
  /// interrupted bootstrap leaves the previous catalog intact.
  void finishBootstrap(String cursor);

  /// Applies one change page (upserts and tombstones) and its cursor atomically.
  void applyCatalogChanges(List<Map<String, dynamic>> items, String cursor);

  List<Map<String, dynamic>> searchCatalog(String text, {int limit = 50});
  ({Map<String, dynamic> item, String quantity})? catalogByBarcode(String code);
  int catalogCount();

  // ---------- Operations (outbox) and the local records they carry

  void openSession(Map<String, dynamic> session, OutboxEntry operation);
  void recordCash(String sessionUuid, String kind, String amount, String occurredAt, OutboxEntry operation);
  void closeSession(String sessionUuid, String countedCash, String closedAt, OutboxEntry operation);
  void recordSale(Map<String, dynamic> sale, String cashNet, OutboxEntry operation);

  /// Reserves (persists) the next number of an offline range before the NFC-e is signed; throws when
  /// the range is exhausted. A number reserved for a document that was never stored is a gap the
  /// tax authority voids (inutilizacao). The signed NFC-e and its outbox operation are then stored
  /// together by [recordFiscalDocument].
  int nextFiscalNumber(String rangeUuid, int from, int to);
  void recordFiscalDocument(String saleUuid, Map<String, dynamic> document, OutboxEntry operation);
  Map<String, dynamic>? fiscalDocument(String saleUuid);

  Map<String, dynamic>? openLocalSession(String terminalUuid);
  String localExpectedCash(String sessionUuid);

  /// Pending operations in device order whose retry time has come.
  List<OutboxEntry> dueOperations(int nowMs, {int limit = 50});
  void markOperation(String operationUuid, String status, {String? result, String? error, int? retryAtMs});
  Map<String, int> outboxCounts();

  /// Outbox status of one operation (pending, retry, done, conflict, rejected) or null.
  String? operationStatus(String operationUuid);
  List<OutboxEntry> problemOperations({int limit = 50});

  void close();
}

class OutboxEntry {
  OutboxEntry({
    required this.operationUuid,
    required this.kind,
    required this.operation,
    required this.hash,
    required this.operatorUuid,
    this.status = 'pending',
    this.attempts = 0,
    this.result,
    this.error,
    this.createdAt,
  });

  final String operationUuid;
  final String kind;

  /// Canonical JSON of the operation (exactly what is hashed and pushed).
  final String operation;
  final String hash;
  final String operatorUuid;
  final String status;
  final int attempts;
  final String? result;
  final String? error;
  final String? createdAt;
}
