import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'i18n/locale_provider.dart';
import 'screens/connections_screen.dart';
import 'state/prefs.dart';
import 'state/reconnect_service.dart';
import 'theme.dart';

/// 全局 RouteObserver，让需要感知"我被 push 覆盖 / 我从被覆盖回到顶层"的 Screen
/// 通过 RouteAware mixin 订阅。当前用途：ProjectPickerScreen 在 didPopNext
/// （从 MainShell 返回）时刷新已展开项目的 session 列表，否则 sessionsProvider
/// 的缓存会让标题/最近时间停留在用户离开前的状态。
final routeObserver = RouteObserver<PageRoute<dynamic>>();

void main() {
  runApp(const ProviderScope(child: CcApp()));
}

class CcApp extends ConsumerWidget {
  const CcApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Boot the reconnect service (scans LAN on startup + network changes).
    ref.watch(reconnectProvider);
    final themeMode = ref.watch(prefsProvider);
    final locale = ref.watch(materialLocaleProvider);
    return MaterialApp(
      title: 'PawTerm',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: themeMode,
      // 让 Material 内部的 ColorTween 立即结束，所有组件在同一帧翻牌。
      // 不然 Material 的 Theme.of 在做 200ms 渐变、AppTokens.of 已经在中点突变，
      // 视觉上就是"有的组件先变，有的后变"。
      themeAnimationDuration: Duration.zero,
      themeAnimationCurve: Curves.linear,
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      navigatorObservers: [routeObserver],
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
