/// Stamped from pubspec.yaml by scripts/release-pos.sh on every release.
const appBuildInfo = AppBuildInfo(product: "mnscloud-pos", version: "1.0.15");

class AppBuildInfo {
  const AppBuildInfo({required this.product, required this.version});

  final String product;
  final String version;
}
