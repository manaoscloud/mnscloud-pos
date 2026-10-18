import 'package:flutter/material.dart';

import 'src/api/api_client.dart';
import 'src/api/pos_api.dart';
import 'src/offline/device_host.dart';
import 'src/state/pos_controller.dart';
import 'src/ui/screens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Installed apps open their local store (offline sales); the web build has none.
  DeviceHost? host;
  try {
    host = await openDeviceHost();
  } catch (_) {
    host = null; // No local storage: the app still sells online.
  }
  final controller = PosController(PosApi(ApiClient()), host: host);
  AppLifecycleListener(onResume: controller.syncNow);
  runApp(PosApp(controller: controller));
  controller.restore();
}

class PosApp extends StatelessWidget {
  const PosApp({super.key, required this.controller});
  final PosController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MNSCloud POS',
        debugShowCheckedModeBanner: false,
        supportedLocales: const [Locale('pt', 'BR'), Locale('en', 'US'), Locale('es', 'ES')],
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1565C0), useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF1565C0), useMaterial3: true, brightness: Brightness.dark),
        home: PosHome(controller: controller),
      );
}
