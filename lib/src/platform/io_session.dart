// Installed apps: no cookies; the API is reached with a Bearer token and an explicit base URL.
import 'package:http/http.dart' as http;

http.Client createHttpClient() => http.Client();

String? readCsrfToken() => null;

String defaultApiBase() => const String.fromEnvironment('POS_API_BASE_URL', defaultValue: '');

const bool isWebPlatform = false;
