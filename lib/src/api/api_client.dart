import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../platform/session.dart';

/// Failure classes the UI explains differently.
enum ApiFailureKind {
  /// The request never reached the API, or the answer was lost (timeout, network): the outcome
  /// is UNKNOWN and must be checked before any retry of a write.
  unreachable,

  /// The API answered with a business or validation error: nothing was saved.
  rejected,

  /// The session expired or the operator lacks permission.
  unauthorized,

  /// The commercial module is not contracted.
  notContracted,
}

class ApiException implements Exception {
  ApiException(this.kind, this.message, {this.status, this.code, this.fields = const []});

  final ApiFailureKind kind;
  final String message;
  final int? status;
  final String? code;
  final List<String> fields;

  bool get outcomeUnknown => kind == ApiFailureKind.unreachable;

  @override
  String toString() => message;
}

/// Thin JSON client of the MNSCloud API. Authorization stays on the server: the client only
/// carries the session (cookie on the web, Bearer token on installed apps) and the tenant header.
class ApiClient {
  ApiClient({String? baseUrl, http.Client? client, this.timeout = const Duration(seconds: 20)})
      : baseUrl = (baseUrl == null || baseUrl.isEmpty) ? defaultApiBase() : baseUrl,
        _http = client ?? createHttpClient();

  final String baseUrl;
  final Duration timeout;
  final http.Client _http;

  /// Bearer token of installed apps (never used on the web, where the cookie session applies).
  String? bearerToken;

  /// Active tenant (`X-Environment-UUID`).
  String? environmentUuid;

  Uri _uri(String path, [Map<String, String>? query]) {
    final clean = path.startsWith('/') ? path.substring(1) : path;
    final uri = Uri.parse('$baseUrl/$clean');
    return query == null || query.isEmpty ? uri : uri.replace(queryParameters: {...uri.queryParameters, ...query});
  }

  Map<String, String> _headers({bool write = false, String? idempotencyKey}) {
    final headers = <String, String>{'Accept': 'application/json'};
    if (write) headers['Content-Type'] = 'application/json';
    final token = bearerToken;
    if (token != null && token.isNotEmpty) headers['Authorization'] = 'Bearer $token';
    final env = environmentUuid;
    if (env != null && env.isNotEmpty) headers['X-Environment-UUID'] = env;
    if (write) {
      final csrf = readCsrfToken();
      if (csrf != null) headers['X-CSRF-Token'] = csrf;
    }
    if (idempotencyKey != null) headers['Idempotency-Key'] = idempotencyKey;
    headers['X-Client-Name'] = 'mnscloud-pos';
    return headers;
  }

  Future<dynamic> get(String path, [Map<String, String>? query]) =>
      _send(() => _http.get(_uri(path, query), headers: _headers()));

  Future<dynamic> post(String path, Object? body, {String? idempotencyKey}) => _send(() => _http.post(
        _uri(path),
        headers: _headers(write: true, idempotencyKey: idempotencyKey),
        body: jsonEncode(body ?? const {}),
      ));

  /// Request with extra headers built from the exact URI and body text (device signatures).
  Future<dynamic> signed(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    required Map<String, String> Function(Uri uri, String bodyText) headers,
  }) {
    final uri = _uri(path, query);
    final text = body == null ? '' : jsonEncode(body);
    final base = _headers(write: body != null);
    final all = {...base, ...headers(uri, text)};
    return _send(() => method == 'GET'
        ? _http.get(uri, headers: all)
        : _http.post(uri, headers: all, body: text));
  }

  Future<dynamic> put(String path, Object? body) => _send(
      () => _http.put(_uri(path), headers: _headers(write: true), body: jsonEncode(body ?? const {})));

  Future<dynamic> _send(Future<http.Response> Function() request) async {
    http.Response response;
    try {
      response = await request().timeout(timeout);
    } on TimeoutException {
      throw ApiException(ApiFailureKind.unreachable, 'The server did not answer in time.');
    } catch (_) {
      throw ApiException(ApiFailureKind.unreachable, 'The server cannot be reached.');
    }
    dynamic decoded;
    if (response.body.isNotEmpty) {
      try {
        decoded = jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {
        decoded = null;
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded is Map ? decoded['data'] : decoded;
    }
    final body = decoded is Map ? decoded : const {};
    final message = (body['error'] ?? body['detail'] ?? 'Request failed (${response.statusCode}).').toString();
    final code = body['code']?.toString();
    final fields = (body['fields'] is List) ? (body['fields'] as List).map((f) => f.toString()).toList() : <String>[];
    if (response.statusCode >= 500 || response.statusCode == 502 || response.statusCode == 503 || response.statusCode == 504) {
      // A gateway error may hide a committed write: the caller checks before retrying.
      throw ApiException(ApiFailureKind.unreachable, message, status: response.statusCode, code: code);
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw ApiException(ApiFailureKind.unauthorized, message, status: response.statusCode, code: code);
    }
    if (response.statusCode == 402) {
      throw ApiException(ApiFailureKind.notContracted, message, status: response.statusCode, code: code);
    }
    throw ApiException(ApiFailureKind.rejected, message, status: response.statusCode, code: code, fields: fields);
  }
}
