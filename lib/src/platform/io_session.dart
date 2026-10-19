// Installed apps: no cookies; the API is reached with the POS session Bearer token and an explicit
// base URL. The refresh token is kept only in memory.
import 'package:http/http.dart' as http;

http.Client createHttpClient() => http.Client();

String defaultApiBase() => const String.fromEnvironment('POS_API_BASE_URL', defaultValue: '');

/// Installed apps are not opened from the App with a sign-in code.
String? takeHandoffCode() => null;

const bool isWebPlatform = false;
