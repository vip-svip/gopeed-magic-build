import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shadcn_flutter/shadcn_flutter.dart' as shad;

import '../api/model/downloader_config.dart';
import '../core/platform/system_bridge.dart';
import '../util/util.dart';
import '../core/window/app_window_frame.dart';
import '../core/window/app_window_appearance.dart';
import '../core/window/window_capability_transport.dart';
import '../l10n/l10n.dart';
import '../shared/theme/app_component_themes.dart';
import '../shared/theme/app_theme.dart';
import '../features/auth/application/web_auth_controller.dart';
import 'application/app_appearance_controller.dart';
import 'application/app_runtime_controller.dart';
import 'rpc/webview_rpc_overlay.dart';
import 'rpc/webview_rpc_service.dart';
import 'router/app_router.dart';

class GopeedApp extends ConsumerStatefulWidget {
  const GopeedApp({super.key});

  @override
  ConsumerState<GopeedApp> createState() => _GopeedAppState();
}

class _GopeedAppState extends ConsumerState<GopeedApp> with WidgetsBindingObserver {
  late final GoRouter _router;

  /// 只应用一次启动期系统设置，避免每次 rebuild 重复调用原生通道。
  bool _systemPrefsApplied = false;

  /// 把系统级偏好整体下发给原生层。
  ///
  /// 之前只有设置页点保存才同步静默模式，App 冷启动时原生仍留着上次的旧值，
  /// 于是"用户已关掉静默"但外链进来还是按静默走（表现为仍然弹窗 / 仍然无后台）。
  /// 启动时按当前配置整体下发一遍，保证原生与配置始终一致。
  Future<void> _applySystemPrefs(ExtraConfig extra) async {
    if (!Util.isAndroid()) return;
    final bridge = ref.read(systemBridgeProvider);
    final mode = extra.silentDownloadMode;
    await bridge.setSilentMode(
      mode == 'none' ? 'headless' : (mode == 'list' ? 'jump' : 'off'),
    );
    await bridge.hideFromRecents(extra.hideFromRecents);
    await bridge.setMinimizeOnExit(extra.minimizeOnExit);
    await bridge.setOverlayEnabled(extra.showsInAppProgress || extra.silentEnabled);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _router = AppRouter.build(ref.read(webAuthControllerProvider));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router.dispose();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appRuntimeControllerProvider, (_, next) {
      final runtime = next.value;
      if (runtime != null) {
        ref.read(appAppearanceControllerProvider.notifier).initialize(runtime.downloaderConfig.extra);
        if (!_systemPrefsApplied) {
          _systemPrefsApplied = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            unawaited(_applySystemPrefs(runtime.downloaderConfig.extra));
          });
        }
      }
    });
    final runtime = ref.watch(appRuntimeControllerProvider).value;
    if (runtime != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(appAppearanceControllerProvider.notifier).initialize(runtime.downloaderConfig.extra);
      });
    }

    final appearance = ref.watch(appAppearanceControllerProvider);
    final themeColor = appearance.themeColor;
    final isLightTheme = appearance.resolveIsLight(WidgetsBinding.instance.platformDispatcher.platformBrightness);
    final themeMode = switch (appearance.themeMode) {
      AppThemeMode.system => shad.ThemeMode.system,
      AppThemeMode.light => shad.ThemeMode.light,
      AppThemeMode.dark => shad.ThemeMode.dark,
    };
    AppWindowCapabilityHost.instance.updateAppearance(
      AppWindowAppearance(
        themeMode: appearance.themeMode.key,
        themeColor: appearance.themeColor.key,
        locale: runtime?.downloaderConfig.extra.locale ?? '',
      ),
    );

    return shad.ShadcnApp.router(
      debugShowCheckedModeBanner: false,
      disableBrowserContextMenu: false,
      title: 'Gopeed',
      theme: AppTheme.light(themeColor),
      darkTheme: AppTheme.dark(themeColor),
      materialTheme: isLightTheme ? AppTheme.materialLight(themeColor) : AppTheme.materialDark(themeColor),
      themeMode: themeMode,
      locale: supportedLocaleFromConfig(runtime?.downloaderConfig.extra.locale ?? ''),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) {
        // prism_ui 的液态玻璃需要根部宿主捕获其下方画面才能产生真实折射，
        // 否则玻璃 pane 不绘制任何内容（表现为透明/空白）。
        final content = prism.LiquidGlassScope(
          enabled: true,
          quality: prism.LiquidGlassQuality.ultra,
          child: prism.LiquidGlassHost(
            enabled: true,
            child: AppComponentThemes(child: AppWindowFrame(child: child ?? const SizedBox.shrink())),
          ),
        );
        if (!WebViewRpcService.instance.supported) {
          return content;
        }
        return Overlay(
          initialEntries: [
            OverlayEntry(builder: (_) => content),
            OverlayEntry(builder: (_) => const WebViewRpcOverlay()),
          ],
        );
      },
      routerConfig: _router,
    );
  }
}
