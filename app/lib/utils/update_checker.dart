import 'dart:convert';

import 'package:http/http.dart' as http;

const _repo = 'Airoucat233/pawterm';

class GithubAsset {
  final String name;
  final String downloadUrl;
  final int size;
  const GithubAsset(
      {required this.name, required this.downloadUrl, required this.size});

  factory GithubAsset.fromJson(Map<String, dynamic> j) => GithubAsset(
        name: j['name'] as String,
        downloadUrl: j['browser_download_url'] as String,
        size: j['size'] as int? ?? 0,
      );
}

class GithubRelease {
  final String tagName;
  final String body;
  final List<GithubAsset> assets;
  const GithubRelease(
      {required this.tagName, required this.body, required this.assets});

  factory GithubRelease.fromJson(Map<String, dynamic> j) => GithubRelease(
        tagName: j['tag_name'] as String,
        body: j['body'] as String? ?? '',
        assets: (j['assets'] as List)
            .map((a) => GithubAsset.fromJson(a as Map<String, dynamic>))
            .toList(),
      );

  String get version => versionFromTag(tagName);
}

Future<GithubRelease?> fetchLatestRelease(
    {bool prereleaseChannel = false}) async {
  if (prereleaseChannel) return _fetchPrereleaseRelease();
  try {
    final resp = await http.get(
      Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode == 200) {
      return GithubRelease.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>);
    }
  } catch (_) {}
  return null;
}

Future<GithubRelease?> _fetchPrereleaseRelease() async {
  try {
    final resp = await http.get(
      Uri.parse('https://api.github.com/repos/$_repo/releases'),
      headers: {'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode == 200) {
      final list = jsonDecode(resp.body) as List;
      for (final item in list) {
        final r = GithubRelease.fromJson(item as Map<String, dynamic>);
        if (r.tagName.startsWith('prerelease-v')) return r;
      }
    }
  } catch (_) {}
  return null;
}

bool isNewerVersion(String latestTag, String currentVersion) {
  final latest = versionFromTag(latestTag);
  final current = currentVersion.split('+').first;
  final l = latest.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final c = current.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  for (var i = 0; i < 3; i++) {
    final lv = i < l.length ? l[i] : 0;
    final cv = i < c.length ? c[i] : 0;
    if (lv > cv) return true;
    if (lv < cv) return false;
  }
  return false;
}

String versionFromTag(String tagName) {
  for (final prefix in ['release-v', 'prerelease-v', 'v']) {
    if (tagName.startsWith(prefix)) return tagName.substring(prefix.length);
  }
  return tagName;
}

GithubAsset? findApkAsset(GithubRelease release) {
  final arm64 = release.assets
      .where((a) => a.name.endsWith('.apk') && a.name.contains('arm64'))
      .toList();
  if (arm64.isNotEmpty) return arm64.first;
  final any = release.assets.where((a) => a.name.endsWith('.apk')).toList();
  return any.isEmpty ? null : any.first;
}
