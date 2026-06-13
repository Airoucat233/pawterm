import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 运行时读取 pubspec.yaml 里的 version / buildNumber，全局缓存一次。
final packageInfoProvider = FutureProvider<PackageInfo>((ref) async {
  return PackageInfo.fromPlatform();
});

String formatPackageVersion(PackageInfo info) {
  final buildNumber = info.buildNumber.trim();
  if (buildNumber.isEmpty) return 'v${info.version}';
  return 'v${info.version}+$buildNumber';
}
