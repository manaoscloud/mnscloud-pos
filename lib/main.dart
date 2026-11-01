import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/api/api_client.dart';
import 'src/api/pos_api.dart';
import 'src/brand/brand.dart';
import 'src/offline/device_host.dart';
import 'src/state/pos_controller.dart';
import 'src/ui/screens.dart';
import 'src/version/app_update_controller.dart';
import 'src/version/app_update_overlay.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Installed apps open their local store (offline sales); the web build has none.
  DeviceHost? host;
  try {
    host = await openDeviceHost();
  } catch (_) {
    host = null; // No local (encrypted) storage: the app still sells online.
  }
  final controller = PosController(PosApi(ApiClient()), host: host);
  // Web: newer release in build.json. Installed apps: minimum version of their platform, and any
  // API refusal of this version (426), make the update notice mandatory.
  final updates = AppUpdateController(policyReader: controller.api.clientVersionPolicy);
  ApiClient.onClientVersionUnsupported = updates.markUnsupported;
  // Back from the background: sync, and after OperatorPin.idle the operator PIN (installed apps).
  AppLifecycleListener(onResume: controller.resumed, onHide: controller.backgrounded);
  runApp(PosApp(controller: controller, updates: updates));
  controller.loadBrand();
  controller.restore();
}

class PosApp extends StatelessWidget {
  const PosApp({super.key, required this.controller, this.updates});
  final PosController controller;
  final AppUpdateController? updates;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Locale?>(
        valueListenable: controller.locale,
        builder: (context, locale, _) => ValueListenableBuilder<Brand?>(
          valueListenable: controller.brand,
          builder: (context, brand, _) => _app(brand, locale),
        ),
      );

  Widget _app(Brand? brand, Locale? locale) {
    final seed = brand?.primaryColor ?? const Color(0xFF1565C0);
    return MaterialApp(
        title: brand?.title ?? 'MNSCloud POS',
        debugShowCheckedModeBanner: false,
        locale: locale,
        // Material widgets (text fields, dialogs) need their own strings for every supported
        // locale; without the delegates a pt/es browser renders them as grey error boxes.
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('pt', 'BR'), Locale('en', 'US'), Locale('es', 'ES')],
        theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: seed, useMaterial3: true, brightness: Brightness.dark),
        themeMode: switch (brand?.login['appearance']) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        // A newer release (web) or a mandatory update (installed apps) shows a notice, never in
        // the middle of a sale.
        builder: (context, child) => AppUpdateOverlay(
          controller: updates,
          busy: () => controller.saleInProgress,
          listenable: controller,
          child: child ?? const SizedBox.shrink(),
        ),
        home: PosHome(controller: controller),
      );
  }
}
