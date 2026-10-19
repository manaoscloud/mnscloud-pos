// Web build: the POS runs on the same origin as the MNSCloud API but never uses the App session
// cookie. It sends its own POS access token (memory only); the refresh token is an HttpOnly cookie
// scoped to /api/v1/pos/auth, which scripts cannot read and the browser sends only there.
import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

http.Client createHttpClient() => BrowserClient()..withCredentials = true;

/// Same-origin API base of the web bundle (served under /pos/ next to /api/v1).
String defaultApiBase() => '${web.window.location.origin}/api/v1';

/// Single-use sign-in code from the App (`/pos/#handoff=<code>`), removed from the address bar
/// and history at once so it is never reused or shared.
String? takeHandoffCode() {
  final hash = web.window.location.hash;
  if (hash.length < 2) return null;
  final code = Uri.splitQueryString(hash.substring(1))['handoff'];
  if (code == null || code.isEmpty) return null;
  final location = web.window.location;
  web.window.history.replaceState(null, '', '${location.pathname}${location.search}');
  return code;
}

const bool isWebPlatform = true;
