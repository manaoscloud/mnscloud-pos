import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../core/money.dart';
import 'store.dart';

/// SQLite store (WAL, synchronous FULL, versioned migrations with a file backup before each
/// migration). Synchronous on purpose: POS writes are tiny and must be durable before the screen
/// says "saved".
class SqliteOfflineStore implements OfflineStore {
  SqliteOfflineStore._(this._db);

  static const schemaVersion = 2;

  final Database _db;

  /// Opens (or creates) the store at [path]; `:memory:` for tests.
  static SqliteOfflineStore open(String path) {
    if (path != ':memory:' && File(path).existsSync()) {
      final probe = sqlite3.open(path);
      final version = probe.select('PRAGMA user_version').first.values.first as int;
      probe.close();
      if (version != 0 && version < schemaVersion) {
        // Backup before migrating: pending operations survive a failed migration.
        File(path).copySync('$path.backup-v$version');
      }
    }
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = FULL');
    db.execute('PRAGMA foreign_keys = ON');
    final store = SqliteOfflineStore._(db);
    store._migrate();
    return store;
  }

  void _migrate() {
    final version = _db.select('PRAGMA user_version').first.values.first as int;
    if (version >= schemaVersion) return;
    _transaction(() {
      if (version < 1) {
        _db.execute('''
          CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
          CREATE TABLE catalog (
            product_uuid TEXT PRIMARY KEY, name TEXT NOT NULL, search TEXT NOT NULL, barcode TEXT,
            item TEXT NOT NULL, changed_at TEXT NOT NULL) STRICT;
          CREATE INDEX catalog_barcode_main ON catalog (barcode);
          CREATE TABLE catalog_barcode (
            barcode TEXT PRIMARY KEY, product_uuid TEXT NOT NULL, quantity TEXT NOT NULL) STRICT;
          CREATE TABLE catalog_staging (product_uuid TEXT PRIMARY KEY, item TEXT NOT NULL) STRICT;
          CREATE TABLE outbox (
            seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_uuid TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
            operation TEXT NOT NULL, hash TEXT NOT NULL, operator_uuid TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
            next_attempt_at INTEGER NOT NULL DEFAULT 0, result TEXT, error TEXT, created_at TEXT NOT NULL) STRICT;
          CREATE INDEX outbox_due ON outbox (status, next_attempt_at, seq);
          CREATE TABLE local_session (
            session_uuid TEXT PRIMARY KEY, terminal_uuid TEXT NOT NULL, operator_uuid TEXT NOT NULL,
            status TEXT NOT NULL, opened_at TEXT NOT NULL, opening_amount TEXT NOT NULL, closed_at TEXT,
            counted_cash TEXT, open_operation_uuid TEXT NOT NULL) STRICT;
          CREATE TABLE local_cash (
            id INTEGER PRIMARY KEY AUTOINCREMENT, session_uuid TEXT NOT NULL, kind TEXT NOT NULL,
            amount TEXT NOT NULL, occurred_at TEXT NOT NULL, operation_uuid TEXT NOT NULL) STRICT;
          CREATE TABLE local_sale (
            sale_uuid TEXT PRIMARY KEY, session_uuid TEXT NOT NULL, sale TEXT NOT NULL, total TEXT NOT NULL,
            occurred_at TEXT NOT NULL, operation_uuid TEXT NOT NULL) STRICT;
        ''');
      }
      if (version < 2) {
        _db.execute('''
          CREATE TABLE local_fiscal (
            sale_uuid TEXT PRIMARY KEY, access_key TEXT NOT NULL UNIQUE, number INTEGER NOT NULL, document TEXT NOT NULL,
            operation_uuid TEXT NOT NULL, created_at TEXT NOT NULL) STRICT;
        ''');
      }
      _db.execute('PRAGMA user_version = $schemaVersion');
    });
  }

  T _transaction<T>(T Function() work) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = work();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ---------- Meta

  @override
  String? meta(String key) {
    final rows = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  @override
  void setMeta(String key, String? value) {
    if (value == null) {
      _db.execute('DELETE FROM meta WHERE key = ?', [key]);
    } else {
      _db.execute('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [key, value]);
    }
  }

  @override
  int nextCounter() => _transaction(() {
        final next = (int.tryParse(meta('counter') ?? '') ?? 0) + 1;
        setMeta('counter', '$next');
        return next;
      });

  // ---------- Catalog

  @override
  void beginBootstrap() => _db.execute('DELETE FROM catalog_staging');

  @override
  void stageCatalog(List<Map<String, dynamic>> items) => _transaction(() {
        final insert = _db.prepare('INSERT OR REPLACE INTO catalog_staging (product_uuid, item) VALUES (?, ?)');
        try {
          for (final item in items) {
            if (item['deleted'] == true) continue;
            insert.execute([item['productUUID'], jsonEncode(item)]);
          }
        } finally {
          insert.close();
        }
      });

  @override
  void finishBootstrap(String cursor) => _transaction(() {
        final staged = _db.select('SELECT item FROM catalog_staging');
        _db.execute('DELETE FROM catalog');
        _db.execute('DELETE FROM catalog_barcode');
        for (final row in staged) {
          _upsert((jsonDecode(row['item'] as String) as Map).cast<String, dynamic>());
        }
        _db.execute('DELETE FROM catalog_staging');
        setMeta('catalog_cursor', cursor);
        setMeta('catalog_synced_at', DateTime.now().toUtc().toIso8601String());
      });

  @override
  void applyCatalogChanges(List<Map<String, dynamic>> items, String cursor) => _transaction(() {
        for (final item in items) {
          _db.execute('DELETE FROM catalog_barcode WHERE product_uuid = ?', [item['productUUID']]);
          if (item['deleted'] == true) {
            _db.execute('DELETE FROM catalog WHERE product_uuid = ?', [item['productUUID']]);
          } else {
            _upsert(item);
          }
        }
        setMeta('catalog_cursor', cursor);
        setMeta('catalog_synced_at', DateTime.now().toUtc().toIso8601String());
      });

  void _upsert(Map<String, dynamic> item) {
    final name = item['name']?.toString() ?? '';
    final code = item['id']?.toString() ?? '';
    final barcode = item['barcode']?.toString().trim().toUpperCase();
    _db.execute(
      'INSERT OR REPLACE INTO catalog (product_uuid, name, search, barcode, item, changed_at) VALUES (?, ?, ?, ?, ?, ?)',
      [item['productUUID'], name, '${name.toLowerCase()} ${code.toLowerCase()} ${barcode ?? ''}', barcode, jsonEncode(item),
        item['changedAt'] ?? ''],
    );
    for (final raw in (item['barcodes'] as List? ?? const [])) {
      if (raw is! Map || raw['barcode'] == null) continue;
      _db.execute('INSERT OR REPLACE INTO catalog_barcode (barcode, product_uuid, quantity) VALUES (?, ?, ?)',
          [raw['barcode'].toString().trim().toUpperCase(), item['productUUID'], (raw['quantity'] ?? 1).toString()]);
    }
  }

  @override
  List<Map<String, dynamic>> searchCatalog(String text, {int limit = 50}) {
    final query = text.trim().toLowerCase();
    final rows = query.isEmpty
        ? _db.select('SELECT item FROM catalog ORDER BY name LIMIT ?', [limit])
        : _db.select("SELECT item FROM catalog WHERE search LIKE ? ESCAPE '\\' ORDER BY name LIMIT ?",
            ['%${query.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')}%', limit]);
    return [for (final row in rows) (jsonDecode(row['item'] as String) as Map).cast<String, dynamic>()];
  }

  @override
  ({Map<String, dynamic> item, String quantity})? catalogByBarcode(String code) {
    final value = code.trim().toUpperCase();
    var rows = _db.select('SELECT item, ? AS quantity FROM catalog WHERE barcode = ? LIMIT 1', ['1', value]);
    if (rows.isEmpty) {
      rows = _db.select(
          'SELECT c.item, b.quantity FROM catalog_barcode b JOIN catalog c ON c.product_uuid = b.product_uuid WHERE b.barcode = ? LIMIT 1',
          [value]);
    }
    if (rows.isEmpty) return null;
    return (
      item: (jsonDecode(rows.first['item'] as String) as Map).cast<String, dynamic>(),
      quantity: rows.first['quantity'].toString(),
    );
  }

  @override
  int catalogCount() => _db.select('SELECT COUNT(*) AS n FROM catalog').first['n'] as int;

  // ---------- Operations

  void _enqueue(OutboxEntry entry) {
    _db.execute(
      'INSERT INTO outbox (operation_uuid, kind, operation, hash, operator_uuid, created_at) VALUES (?, ?, ?, ?, ?, ?)',
      [entry.operationUuid, entry.kind, entry.operation, entry.hash, entry.operatorUuid,
        DateTime.now().toUtc().toIso8601String()],
    );
  }

  @override
  void openSession(Map<String, dynamic> session, OutboxEntry operation) => _transaction(() {
        _db.execute(
          'INSERT INTO local_session (session_uuid, terminal_uuid, operator_uuid, status, opened_at, opening_amount, open_operation_uuid) '
          "VALUES (?, ?, ?, 'open', ?, ?, ?)",
          [session['sessionUUID'], session['terminalUUID'], operation.operatorUuid, session['openedAt'],
            session['openingAmount'], operation.operationUuid],
        );
        _db.execute(
          "INSERT INTO local_cash (session_uuid, kind, amount, occurred_at, operation_uuid) VALUES (?, 'opening', ?, ?, ?)",
          [session['sessionUUID'], session['openingAmount'], session['openedAt'], operation.operationUuid],
        );
        _enqueue(operation);
      });

  @override
  void recordCash(String sessionUuid, String kind, String amount, String occurredAt, OutboxEntry operation) =>
      _transaction(() {
        final signed = kind == 'withdrawal' ? (-Decimal.parse(amount)).toString() : amount;
        _db.execute('INSERT INTO local_cash (session_uuid, kind, amount, occurred_at, operation_uuid) VALUES (?, ?, ?, ?, ?)',
            [sessionUuid, kind, signed, occurredAt, operation.operationUuid]);
        _enqueue(operation);
      });

  @override
  void closeSession(String sessionUuid, String countedCash, String closedAt, OutboxEntry operation) => _transaction(() {
        _db.execute("UPDATE local_session SET status = 'closed', closed_at = ?, counted_cash = ? WHERE session_uuid = ?",
            [closedAt, countedCash, sessionUuid]);
        _enqueue(operation);
      });

  @override
  void recordSale(Map<String, dynamic> sale, String cashNet, OutboxEntry operation) => _transaction(() {
        _db.execute(
          'INSERT INTO local_sale (sale_uuid, session_uuid, sale, total, occurred_at, operation_uuid) VALUES (?, ?, ?, ?, ?, ?)',
          [sale['saleUUID'], sale['sessionUUID'], jsonEncode(sale), sale['total'] ?? '0', sale['occurredAt'],
            operation.operationUuid],
        );
        if (!Decimal.parse(cashNet).isZero) {
          _db.execute(
            "INSERT INTO local_cash (session_uuid, kind, amount, occurred_at, operation_uuid) VALUES (?, 'sale', ?, ?, ?)",
            [sale['sessionUUID'], cashNet, sale['occurredAt'], operation.operationUuid],
          );
        }
        _enqueue(operation);
      });

  @override
  int nextFiscalNumber(String rangeUuid, int from, int to) => _transaction(() {
        final key = 'fiscal_next:$rangeUuid';
        final next = int.tryParse(meta(key) ?? '') ?? from;
        if (next > to) throw StateError('Offline fiscal range exhausted');
        setMeta(key, '${next + 1}');
        return next;
      });

  @override
  void recordFiscalDocument(String saleUuid, Map<String, dynamic> document, OutboxEntry operation) => _transaction(() {
        _db.execute(
          'INSERT INTO local_fiscal (sale_uuid, access_key, number, document, operation_uuid, created_at) VALUES (?, ?, ?, ?, ?, ?)',
          [saleUuid, document['accessKey'], document['number'], jsonEncode(document), operation.operationUuid,
            DateTime.now().toUtc().toIso8601String()],
        );
        _enqueue(operation);
      });

  @override
  Map<String, dynamic>? fiscalDocument(String saleUuid) {
    final rows = _db.select('SELECT document FROM local_fiscal WHERE sale_uuid = ?', [saleUuid]);
    return rows.isEmpty ? null : (jsonDecode(rows.first['document'] as String) as Map).cast<String, dynamic>();
  }

  @override
  Map<String, dynamic>? openLocalSession(String terminalUuid) {
    final rows = _db.select(
        "SELECT * FROM local_session WHERE terminal_uuid = ? AND status = 'open' ORDER BY opened_at DESC LIMIT 1",
        [terminalUuid]);
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  @override
  String localExpectedCash(String sessionUuid) {
    var total = Decimal.zero();
    for (final row in _db.select('SELECT amount FROM local_cash WHERE session_uuid = ?', [sessionUuid])) {
      total = total + Decimal.parse(row['amount']);
    }
    return total.toString();
  }

  @override
  List<OutboxEntry> dueOperations(int nowMs, {int limit = 50}) => [
        for (final row in _db.select(
            "SELECT * FROM outbox WHERE status IN ('pending', 'retry') AND next_attempt_at <= ? ORDER BY seq LIMIT ?",
            [nowMs, limit]))
          _entry(row),
      ];

  OutboxEntry _entry(Row row) => OutboxEntry(
        operationUuid: row['operation_uuid'] as String,
        kind: row['kind'] as String,
        operation: row['operation'] as String,
        hash: row['hash'] as String,
        operatorUuid: row['operator_uuid'] as String,
        status: row['status'] as String,
        attempts: row['attempts'] as int,
        result: row['result'] as String?,
        error: row['error'] as String?,
        createdAt: row['created_at'] as String?,
      );

  @override
  void markOperation(String operationUuid, String status, {String? result, String? error, int? retryAtMs}) {
    _db.execute(
      'UPDATE outbox SET status = ?, result = COALESCE(?, result), error = ?, attempts = attempts + 1, '
      'next_attempt_at = COALESCE(?, next_attempt_at) WHERE operation_uuid = ?',
      [status, result, error, retryAtMs, operationUuid],
    );
  }

  @override
  String? operationStatus(String operationUuid) {
    final rows = _db.select('SELECT status FROM outbox WHERE operation_uuid = ?', [operationUuid]);
    return rows.isEmpty ? null : rows.first['status'] as String;
  }

  @override
  Map<String, int> outboxCounts() => {
        for (final row in _db.select('SELECT status, COUNT(*) AS n FROM outbox GROUP BY status'))
          row['status'] as String: row['n'] as int,
      };

  @override
  List<OutboxEntry> problemOperations({int limit = 50}) => [
        for (final row in _db.select(
            "SELECT * FROM outbox WHERE status IN ('rejected', 'conflict') ORDER BY seq DESC LIMIT ?", [limit]))
          _entry(row),
      ];

  @override
  void close() => _db.close();
}
