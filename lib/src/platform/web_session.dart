// Web build: the POS runs on the same origin as the MNSCloud API, so the HttpOnly session
// cookie set by sign-in is sent automatically; writes echo the readable CSRF cookie.
import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

http.Client createHttpClient() => BrowserClient()..withCredentials = true;

String? readCsrfToken() {
  for (final part in web.document.cookie.split(';')) {
    final kv = part.trim().split('=');
    if (kv.length >= 2 && kv.first == 'mnscloud_csrf') return Uri.decodeComponent(kv.sublist(1).join('='));
  }
  return null;
}

/// Same-origin API base of the web bundle (served under /pos/ next to /api/v1).
String defaultApiBase() => '${web.window.location.origin}/api/v1';

const bool isWebPlatform = true;
