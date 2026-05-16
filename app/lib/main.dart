import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'i18n/locale_provider.dart';
import 'screens/connections_screen.dart';
import 'state/prefs.dart';
import 'theme.dart';

void main() {
  runApp(const ProviderScope(child: CcApp()));
}

class CcApp extends ConsumerWidget {
  const CcApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(prefsProvider);
    final locale = ref.watch(materialLocaleProvider);
    return MaterialApp(
      title: 'Claude Companion',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: themeMode,
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      // 让状态栏 / 导航栏跟随当前主题切换，避免系统 scrim 蒙灰。
      // 用 builder 而非外层 wrap，是为了在 MaterialApp 解析出 Theme 之后再读取。
      builder: (context, child) {
        final t = AppTokens.of(context);
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
            statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
            systemNavigationBarColor: t.bg,
            systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
            systemNavigationBarDividerColor: Colors.transparent,
          ),
          child: child!,
        );
      },
      home: const ConnectionsScreen(),
    );
  }
}
