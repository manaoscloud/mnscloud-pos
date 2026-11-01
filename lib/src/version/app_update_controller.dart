import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app_build_info.dart';
import 'client_identity.dart';
import 'runtime_version.dart';
import 'runtime_version_fetcher_stub.dart' if (dart.library.js_interop) 'runtime_version_fetcher_web.dart' as platform;

typedef DeployedVersionReader = Future<RuntimeReleaseInfo?> Function();
typedef ClientPolicyReader = Future<ClientVersionPolicy?> Function();

/// Detects that a newer POS release went live while the web POS stays open.
///
/// It reads the release `build.json` on start, every ~5 minutes while the page is visible and when
/// the page becomes visible again, and accepts a different version only after two reads agree
/// [confirmDelay] apart. It never reloads by itself: the UI shows a notice and the operator updates
/// between sales. "Later" is kept in memory only (the web POS stores nothing in the browser).
///
/// Installed apps have no store link yet, so they show only the mandatory notice: they read the
/// client policy ([policyReader]) on start, every 6 hours and on resume, and the notice is critical
/// when the running version is below the minimum of their platform or the API refused this version
/// ([markUnsupported], HTTP 426). A failed read or a platform without minimum shows nothing.
class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    DeployedVersionReader? reader,
    this._policyReader,
    String? runningVersion,
    String? platformName,
    bool? web,
    DateTime Function()? clock,
  })  : _reader = reader ?? (() => platform.fetchLatestRuntimeRelease(appBuildInfo.product)),
        runningVersion = normalizeVersion(runningVersion ?? appBuildInfo.version),
        platformName = platformName ?? clientPlatform(),
        isWeb = web ?? kIsWeb,
        _clock = clock ?? DateTime.now;

  static const pollInterval = Duration(minutes: 5);
  static const policyPollInterval = Duration(hours: 6);
  static const minCheckGap = Duration(minutes: 1);
  static const confirmDelay = Duration(seconds: 45);
  static const snoozeDuration = Duration(hours: 4);

  final DeployedVersionReader _reader;
  final ClientPolicyReader? _policyReader;
  final DateTime Function() _clock;
  final String runningVersion;
  final String platformName;
  final bool isWeb;

  /// Installed apps: minimum of this platform from the last policy read, and the API refusal.
  String? _minimum;
  bool _refused = false;
  AppLifecycleListener? _lifecycle;

  RuntimeReleaseInfo? _deployed;
  ({String version, DateTime seenAt})? _candidate;
  ({String version, DateTime until})? _snooze;
  DateTime? _lastCheckAt;
  Future<void>? _inFlight;
  Timer? _pollTimer;
  Timer? _confirmTimer;
  bool _started = false;
  bool _disposed = false;

  RuntimeReleaseInfo? get deployed => _deployed;

  bool get updateAvailable {
    if (!isWeb) return critical;
    final version = _deployed?.version;
    return version != null && version != runningVersion;
  }

  /// The running bundle is below the release `minimumVersion`: the notice cannot be postponed (it
  /// still never reloads by itself).
  bool get critical {
    if (!isWeb) {
      final minimum = _minimum;
      return _refused || (minimum != null && compareSemver(runningVersion, minimum) < 0);
    }
    final minimum = _deployed?.minimumVersion;
    return minimum != null && updateAvailable && compareSemver(runningVersion, minimum) < 0;
  }

  bool get noticeVisible {
    if (!isWeb) return critical;
    if (!updateAvailable) return false;
    if (critical) return true;
    final snooze = _snooze;
    return snooze == null || snooze.version != _deployed!.version || !snooze.until.isAfter(_clock());
  }

  /// Starts background detection: release `build.json` on the web, client policy on installed apps.
  void start() {
    if (_started) return;
    if (!isWeb) {
      if (_policyReader == null) return;
      _started = true;
      _lifecycle = AppLifecycleListener(onResume: () => unawaited(check()));
      _pollTimer = Timer.periodic(policyPollInterval, (_) => unawaited(check()));
      unawaited(check(force: true));
      return;
    }
    if (!kIsWeb) return; // build.json and page visibility exist only in the browser.
    _started = true;
    platform.listenPageVisible(() => unawaited(check()));
    _schedulePoll();
    unawaited(check(force: true));
  }

  Future<void> check({bool force = false}) {
    final pending = _inFlight;
    if (pending != null) return pending;
    final now = _clock();
    final last = _lastCheckAt;
    if (!force && last != null && now.difference(last) < minCheckGap) return Future.value();
    _lastCheckAt = now;
    if (!isWeb) return _track(_checkPolicy().whenComplete(() => _inFlight = null));
    final future = _reader()
        .then((build) {
          if (build?.version != null && !_disposed) observe(build!, _clock());
        })
        .catchError((Object _) {})
        .whenComplete(() => _inFlight = null);
    return _track(future);
  }

  Future<void> _track(Future<void> future) {
    _inFlight = future;
    return future;
  }

  /// Fails open: a failed read keeps the last answer; a policy without minimum clears it.
  Future<void> _checkPolicy() async {
    final reader = _policyReader;
    if (reader == null) return;
    try {
      final policy = await reader();
      if (policy == null || _disposed) return;
      final minimum = normalizeVersion(policy.minimum[platformName]);
      final next = isReleaseVersion(minimum) ? minimum : null;
      if (next == _minimum) return;
      _minimum = next;
      notifyListeners();
    } catch (_) {}
  }

  /// The API refused this app version (426 `CLIENT_VERSION_UNSUPPORTED`): the notice becomes
  /// critical until the app is updated. Only installed apps are refused.
  void markUnsupported() {
    if (isWeb || _refused || _disposed) return;
    _refused = true;
    notifyListeners();
  }

  /// Feeds one `build.json` read into the confirmation state.
  @visibleForTesting
  void observe(RuntimeReleaseInfo build, DateTime at) {
    final version = normalizeVersion(build.version);
    if (version.isEmpty) return;
    final current = _deployed;
    if (version == (current?.version ?? runningVersion)) {
      _candidate = null;
      _confirmTimer?.cancel();
      if (current == null || current.minimumVersion != build.minimumVersion) {
        _deployed = RuntimeReleaseInfo(version: version, buildRef: build.buildRef, minimumVersion: build.minimumVersion);
        notifyListeners();
      }
      return;
    }
    final candidate = _candidate;
    if (candidate != null && candidate.version == version) {
      if (at.difference(candidate.seenAt) >= confirmDelay) {
        _candidate = null;
        _confirmTimer?.cancel();
        _deployed = RuntimeReleaseInfo(version: version, buildRef: build.buildRef, minimumVersion: build.minimumVersion);
        notifyListeners();
      }
      return;
    }
    _candidate = (version: version, seenAt: at);
    _confirmTimer?.cancel();
    if (_started) _confirmTimer = Timer(confirmDelay, () => unawaited(check(force: true)));
  }

  /// "Later": hide the notice for this version for a few hours (this tab only).
  void postpone() {
    final version = _deployed?.version;
    if (version == null) return;
    _snooze = (version: version, until: _clock().add(snoozeDuration));
    notifyListeners();
  }

  void reloadNow() => platform.reloadPage();

  void _schedulePoll() {
    final jitter = Duration(seconds: Random().nextInt(60) - 30);
    _pollTimer = Timer(pollInterval + jitter, () {
      if (platform.isPageVisible()) unawaited(check());
      if (!_disposed) _schedulePoll();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _lifecycle?.dispose();
    _pollTimer?.cancel();
    _confirmTimer?.cancel();
    super.dispose();
  }
}
