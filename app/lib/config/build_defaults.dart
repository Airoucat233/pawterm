class BuildDefaults {
  static const int defaultServerPort = int.fromEnvironment(
    'PAWTERM_DEFAULT_PORT',
    defaultValue: 18765,
  );
}
