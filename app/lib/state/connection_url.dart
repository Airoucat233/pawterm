import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../config/build_defaults.dart';

const String defaultConnectionScheme = 'http';

class ConnectionUrlParts {
  final String scheme;
  final String host;
  final int port;

  const ConnectionUrlParts({
    required this.scheme,
    required this.host,
    required this.port,
  });

  String get baseUrl => '$scheme://$host:$port';
}

int defaultPortForScheme(String scheme) {
  switch (scheme.toLowerCase()) {
    case 'https':
      return 443;
    case 'http':
      return 80;
    default:
      return BuildDefaults.defaultServerPort;
  }
}

String normalizeHostForPlatform(String host) {
  if (!kIsWeb && Platform.isAndroid && host == 'localhost') {
    return '10.0.2.2';
  }
  return host;
}

ConnectionUrlParts? parseConnectionUrlInput({
  required String input,
  String fallbackScheme = defaultConnectionScheme,
  int fallbackPort = BuildDefaults.defaultServerPort,
}) {
  final raw = input.trim();
  if (raw.isEmpty) return null;

  final parsed = Uri.tryParse(raw);
  final hasExplicitScheme = parsed != null &&
      (parsed.scheme == 'http' || parsed.scheme == 'https') &&
      parsed.host.isNotEmpty;

  if (hasExplicitScheme) {
    final scheme = parsed.scheme;
    final port =
        parsed.hasPort ? parsed.port : defaultPortForScheme(parsed.scheme);
    return ConnectionUrlParts(
      scheme: scheme,
      host: normalizeHostForPlatform(parsed.host),
      port: port,
    );
  }

  final withoutPath = raw.split('/').first;
  final hostPort = Uri.tryParse('$fallbackScheme://$withoutPath');
  final host = hostPort?.host ?? withoutPath.split(':').first;
  if (host.isEmpty) return null;
  return ConnectionUrlParts(
    scheme: fallbackScheme,
    host: normalizeHostForPlatform(host),
    port: hostPort?.hasPort == true ? hostPort!.port : fallbackPort,
  );
}

ConnectionUrlParts? parseConnectionFields({
  required String scheme,
  required String hostInput,
  required String portInput,
}) {
  return parseConnectionUrlInput(
    input: hostInput,
    fallbackScheme: scheme,
    fallbackPort:
        int.tryParse(portInput.trim()) ?? BuildDefaults.defaultServerPort,
  );
}

String webSocketBaseForHttpBase(String baseUrl) {
  final uri = Uri.parse(baseUrl);
  final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
  return uri
      .replace(scheme: wsScheme)
      .toString()
      .replaceFirst(RegExp(r'/$'), '');
}
