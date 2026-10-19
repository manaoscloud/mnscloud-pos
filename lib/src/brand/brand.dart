import 'package:flutter/material.dart';

/// Brand of the host for the POS (Settings › Themes › POS tab of the tenant domain); every field
/// the POS tab leaves empty comes from the App brand. Null fields keep the MNSCloud defaults.
class Brand {
  const Brand({this.title, this.logoUrl, this.faviconUrl, this.primaryColor});

  final String? title;
  final String? logoUrl;
  final String? faviconUrl;
  final Color? primaryColor;

  /// `data` of `GET /public/theme/context?app=pos`: `{ context: {...} | null }`.
  static Brand? fromContext(dynamic data) {
    final context = data is Map ? data['context'] : null;
    if (context is! Map) return null;
    String? text(Object? value) {
      final result = value?.toString().trim();
      return result == null || result.isEmpty ? null : result;
    }

    return Brand(
      title: text(context['PageTitle']),
      logoUrl: safeImageUrl(text(context['LogoUrl'])),
      faviconUrl: safeImageUrl(text(context['FaviconUrl'])),
      primaryColor: parseHexColor(text(context['PrimaryColor'])),
    );
  }

  /// Only images uploaded to the theme (same origin) or https addresses are shown.
  static String? safeImageUrl(String? url) {
    if (url == null) return null;
    if (RegExp(r'^/api/v1/public/theme/assets/[0-9a-f]{32}$').hasMatch(url)) {
      return url;
    }
    final uri = Uri.tryParse(url);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
        ? url
        : null;
  }

  static Color? parseHexColor(String? value) {
    final match = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(value ?? '');
    return match == null
        ? null
        : Color(0xFF000000 | int.parse(match.group(1)!, radix: 16));
  }
}
