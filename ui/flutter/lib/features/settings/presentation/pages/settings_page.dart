import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons, ScaffoldMessenger, SnackBar;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:go_router/go_router.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shad;
import 'package:url_launcher/url_launcher.dart';

import '../../../../api/model/downloader_config.dart';
import '../../../../app/application/app_appearance_controller.dart';
import '../../../../app/application/app_platform_controller.dart';
import '../../../../app/application/app_runtime_controller.dart';
import '../../../../app/application/location_keep_alive.dart';
import '../../../../app/application/continued_processing.dart';
import '../../../../core/common/start_config.dart';
import '../../../../core/network/gopeed/gopeed_transport.dart';
import '../../../../core/platform/system_bridge.dart';
import '../../../../core/utils/breakpoints.dart';
import '../../../../core/window/app_window_chrome.dart';
import '../../../../shared/theme/app_design_tokens.dart';
import '../../../../shared/theme/app_palette.dart';
import '../../../../shared/widgets/app_choice_segmented_control.dart';
import '../../../../shared/widgets/app_loading_button.dart';
import '../../../../shared/widgets/app_number_input.dart';
import '../../../../shared/widgets/app_path_picker_field.dart';
import '../../../../shared/widgets/app_text_field.dart';
import '../../../../shared/widgets/app_tooltip.dart';
import '../../../../shared/widgets/app_toast.dart';
import '../../../../shared/widgets/responsive_menu_layout.dart';
import '../../../../shared/widgets/skia_liquid_glass.dart';
import '../../../../l10n/l10n.dart';
import '../../../../util/log_util.dart';
import '../../../../util/package_info.dart';
import '../../../../util/scheme_register/scheme_register.dart';
import '../../../../util/util.dart';
import '../../../home/presentation/widgets/primary_rail.dart';
import '../../application/settings_controller.dart';
import '../widgets/app_update_dialog.dart';
import '../widgets/download_categories_setting.dart';
import '../widgets/mcp_agent_setup.dart';
import '../widgets/settings_language_select.dart';
import '../widgets/settings_content_frame.dart';
import '../widgets/settings_item.dart';
import '../widgets/settings_list_editor.dart';
import '../widgets/theme_settings_control.dart';
import '../widgets/tracker_subscriptions_control.dart';

enum _SettingsSection { basic, downloads, advanced }

String webApiDisplayAddress(Uri pageUri) {
  final host = pageUri.host.toLowerCase() == 'localhost' ? '127.0.0.1' : pageUri.host;
  return Uri(host: host, port: pageUri.hasPort ? pageUri.port : null).authority;
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.sectionKey});

  final String? sectionKey;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _downloadDirController = TextEditingController();
  final _maxRunningController = TextEditingController();
  final _httpUserAgentController = TextEditingController();
  final _httpConnectionsController = TextEditingController();
  final _ftpConnectionsController = TextEditingController();
  final _hlsConnectionsController = TextEditingController();
  final _hlsMaxRetriesController = TextEditingController();
  final _btListenPortController = TextEditingController();
  final _btSeedRatioController = TextEditingController();
  final _btSeedTimeController = TextEditingController();
  final _ed2kListenPortController = TextEditingController();
  final _ed2kUdpPortController = TextEditingController();
  final _ed2kServerAddrController = TextEditingController();
  final _ed2kServerMetController = TextEditingController();
  final _ed2kNodesDatController = TextEditingController();
  final _proxyHostController = TextEditingController();
  final _proxyPortController = TextEditingController();
  final _proxyUserController = TextEditingController();
  final _proxyPasswordController = TextEditingController();
  final _customTrackersController = TextEditingController();
  final _apiHostController = TextEditingController();
  final _apiPortController = TextEditingController();
  final _apiTokenController = TextEditingController();

  DownloaderConfig? _config;
  StartConfig? _startConfig;
  String? _loadedSignature;
  String? _appliedDownloadDir;
  String? _loadedStartSignature;
  Timer? _textSaveTimer;
  bool _syncingControllers = false;
  bool _syncingStartControllers = false;
  bool _savingStartConfig = false;

  // ----- 模块（KernelSU / Magisk）联动状态 -----
  // 之前设置页完全不知道模块存在，用户只能自己开终端跑 gopeedctl，
  // 所以表现为「模块未联动 App」。这里直接读取并控制模块。
  // 模块目录名随 module.prop 的 id 变化，安装位置也随 Magisk / KernelSU /
  // APatch 不同，所以控制脚本路径不能写死；下面用通配探测一次并缓存。
  String? _ctlPath;
  Map<String, String>? _moduleInfo;
  bool _moduleLoading = false;
  bool _moduleBusy = false;
  String? _moduleError;

  // ----- 系统级悬浮窗 -----
  // 静默下载的浮窗是原生 overlay，不是 App 内组件，所以开关存在原生偏好里。
  bool _overlayEnabled = true;
  bool _overlayPermission = false;

  // ----- Android 系统级开关 -----
  // 之前只有配置字段没有入口，用户根本没法开。这里接原生偏好。
  bool _autoStart = false;
  bool _minimizeOnExit = false;
  bool _hideFromRecents = false;

  List<TextEditingController> get _textControllers => [
    _downloadDirController,
    _maxRunningController,
    _httpUserAgentController,
    _httpConnectionsController,
    _ftpConnectionsController,
    _hlsConnectionsController,
    _hlsMaxRetriesController,
    _btListenPortController,
    _btSeedRatioController,
    _btSeedTimeController,
    _ed2kListenPortController,
    _ed2kUdpPortController,
    _ed2kServerAddrController,
    _ed2kServerMetController,
    _ed2kNodesDatController,
    _proxyHostController,
    _proxyPortController,
    _proxyUserController,
    _proxyPasswordController,
    _customTrackersController,
  ];

  List<TextEditingController> get _startTextControllers => [
    _apiHostController,
    _apiPortController,
    _apiTokenController,
  ];

  @override
  void initState() {
    super.initState();
    for (final controller in _textControllers) {
      controller.addListener(_scheduleTextSave);
    }
    for (final controller in _startTextControllers) {
      controller.addListener(_handleStartDraftChanged);
    }
    // 模块状态与悬浮窗权限：设置页一进来就读取，避免用户以为没生效。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadModuleInfo());
      if (mounted) unawaited(_loadOverlayState());
      if (mounted) unawaited(_loadSystemPrefs());
    });
  }

  /// 读取悬浮窗权限与开关状态（都存在原生侧）。
  Future<void> _loadOverlayState() async {
    if (!_moduleSupported) return;
    final bridge = ref.read(systemBridgeProvider);
    final granted = await bridge.hasOverlayPermission();
    if (!mounted) return;
    setState(() => _overlayPermission = granted);
  }

  /// 读取原生已保存的三项开关，避免界面默认值与真实状态不一致。
  Future<void> _loadSystemPrefs() async {
    if (!_moduleSupported) return;
    // 注意：不受 _moduleSupported/模块检测影响，开关状态与模块无关。
    final bridge = ref.read(systemBridgeProvider);
    final prefs = await bridge.readSystemPrefs();
    if (!mounted) return;
    // 原生偏好可能缺键（这些开关以前根本没写盘），
    // 此时必须保留配置里已有的值，不能用 false 覆盖 ——
    // 这就是「开关明明生效了，退出再进来却显示关闭」的根因。
    setState(() {
      _autoStart = prefs['autoStart'] ?? _autoStart;
      _minimizeOnExit = prefs['minimizeOnExit'] ?? _minimizeOnExit;
      _hideFromRecents = prefs['hideFromRecents'] ?? _hideFromRecents;
    });
  }

  Future<void> _setAutoStart(bool value) async {
    setState(() => _autoStart = value);
    // 自动运行只由原生偏好承载（配置模型里没有对应字段，也不该为此改模型）
    await ref.read(systemBridgeProvider).setAutoStart(value);
  }

  Future<void> _setMinimizeOnExit(bool value) async {
    setState(() => _minimizeOnExit = value);
    await ref.read(systemBridgeProvider).setMinimizeOnExit(value);
    await _persistExtra((extra) => extra.minimizeOnExit = value);
  }

  Future<void> _setHideFromRecents(bool value) async {
    setState(() => _hideFromRecents = value);
    await ref.read(systemBridgeProvider).hideFromRecents(value);
    await _persistExtra((extra) => extra.hideFromRecents = value);
  }

  /// 统一把额外配置改动写回后端，避免只改本地界面不落库。
  Future<void> _persistExtra(void Function(ExtraConfig extra) apply) async {
    try {
      // 控制器本身接收 mutation 回调，直接交给它改，避免手动改副本后忘记回写
      await ref
          .read(appRuntimeControllerProvider.notifier)
          .updateExtraConfig((e) => apply(e));
    } catch (_) {
      // 配置写回失败不应阻塞开关交互
    }
  }

  @override
  void dispose() {
    _textSaveTimer?.cancel();
    for (final controller in _textControllers) {
      controller.removeListener(_scheduleTextSave);
      controller.dispose();
    }
    for (final controller in _startTextControllers) {
      controller.removeListener(_handleStartDraftChanged);
      controller.dispose();
    }
    super.dispose();
  }

  /// 申请「显示在其他应用上层」权限，并回读真实结果。
  Future<void> _requestOverlayPermission() async {
    final bridge = ref.read(systemBridgeProvider);
    try {
      await bridge.requestOverlayPermission();
    } catch (_) {
      // 打不开系统设置页时继续走下面的回读，不假装成功。
    }
    // 用户从系统设置页返回需要时间，短暂轮询几次。
    var granted = false;
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      granted = await bridge.hasOverlayPermission();
      if (granted) break;
    }
    if (!mounted) return;
    setState(() => _overlayPermission = granted);
    _toast(granted ? '已获得悬浮窗权限' : '未获得悬浮窗权限，静默下载将只发送通知');
  }

  // ---------------- 模块（KernelSU / Magisk）联动 ----------------

  static bool get _moduleSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _loadModuleInfo({bool silent = false}) async {
    if (!_moduleSupported) return;
    if (!silent) setState(() => _moduleLoading = true);
    try {
      final bridge = ref.read(systemBridgeProvider);
      // 之前不判断模块是否存在就直接跑 gopeedctl，没装模块时 shell 只会回
      // "not found"，被当成「检测失败」——这就是误报的根因。这里先看文件。
      final installed = await _moduleFilesExist(bridge);
      if (!installed) {
        if (!mounted) return;
        setState(() {
          _moduleInfo = null;
          _moduleError = '未安装模块（需在 KernelSU / Magisk 中刷入本模块包）';
        });
        return;
      }
      final ctl = await _resolveCtlPath(bridge);
      if (ctl == null) {
        if (!mounted) return;
        setState(() {
          _moduleInfo = null;
          _moduleError = '已找到模块文件，但定位不到 bin/gopeedctl（请确认已授予 root 权限）';
        });
        return;
      }
      final result = await bridge.rootExec('sh $ctl info 2>&1');
      final out = (result.stdout as String).trim();
      final text = out.isEmpty ? (result.stderr as String) : out;
      final map = <String, String>{};
      for (final line in text.split('\n')) {
        final t = line.trim();
        final eq = t.indexOf('=');
        if (eq > 0) map[t.substring(0, eq).trim()] = t.substring(eq + 1).trim();
      }
      if (!mounted) return;
      setState(() {
        if (map.isEmpty) {
          _moduleInfo = null;
          // 文件在但 info 没内容：多为未授予 root，与「未安装」区分开
          _moduleError = text.trim().isEmpty
              ? '模块已安装，但状态为空（请确认已授予 root 权限后重试）'
              : '模块状态读取异常：${text.trim().split('\n').first}';
        } else {
          _moduleInfo = map;
          // 只要 info 有输出就说明模块在正常工作，缺 installed 字段不再报错
          _moduleError = null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _moduleInfo = null;
        _moduleError = '读取模块状态失败：$e';
      });
    } finally {
      if (mounted && !silent) setState(() => _moduleLoading = false);
    }
  }

  /// 探测模块控制脚本的真实路径。
  ///
  /// 模块目录名来自 module.prop 的 id，安装位置又随 Magisk / KernelSU /
  /// APatch 不同，写死路径会让 `sh <path>` 直接失败且没有任何输出，
  /// 界面就只剩一句「未就绪」。这里按候选目录逐个找 bin/gopeedctl，
  /// 并兜底 PATH 里的同名命令，找到就缓存。
  Future<String?> _resolveCtlPath(dynamic bridge) async {
    final cached = _ctlPath;
    if (cached != null && cached.isNotEmpty) return cached;
    try {
      final r = await bridge.rootExec(
        'for d in /data/adb/modules/*gopeed* /data/adb/modules_update/*gopeed* '
        '/data/adb/ksu/modules/*gopeed* /data/adb/ap/modules/*gopeed*; do '
        '[ -f "\$d/bin/gopeedctl" ] && echo "\$d/bin/gopeedctl" && exit 0; done; '
        'command -v gopeedctl 2>/dev/null',
      );
      final lines = (r.stdout as String)
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && !e.contains('not found'))
          .toList();
      final found = lines.isEmpty ? null : lines.first;
      _ctlPath = found;
      return found;
    } catch (_) {
      return null;
    }
  }

  /// 模块文件是否存在。不依赖 root 命令输出，避免把「没装」误判成「检测失败」。
  Future<bool> _moduleFilesExist(dynamic bridge) async {
    try {
      // 覆盖 Magisk / KernelSU / APatch 的真实落盘位置，并用通配匹配目录名
      // （模块目录名随 module.prop 的 id 变化），避免「装着模块却报未就绪」。
      final r = await bridge.rootExec(
        'ls -d /data/adb/modules/*gopeed* /data/adb/modules_update/*gopeed* '
        '/data/adb/ksu/modules/*gopeed* /data/adb/ap/modules/*gopeed* '
        '2>/dev/null; command -v gopeedctl 2>/dev/null',
      );
      if ((r.stdout as String).trim().isNotEmpty) return true;
      // 目录探测不到，再看控制脚本本身能不能定位（自定义目录安装的情况）。
      final ctl = await _resolveCtlPath(bridge);
      return ctl != null && ctl.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _runModuleAction(String arg, String label) async {
    if (_moduleBusy) return;
    setState(() => _moduleBusy = true);
    try {
      final bridge = ref.read(systemBridgeProvider);
      final ctl = await _resolveCtlPath(bridge);
      if (ctl == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未找到模块控制脚本，请确认模块已安装并已授予 root')),
          );
        }
        return;
      }
      final result = await bridge.rootExec('sh $ctl $arg 2>&1');
      final out = result.stdout.trim().isEmpty ? result.stderr.trim() : result.stdout.trim();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(out.isEmpty ? '$label完成' : out)),
      );
      await _loadModuleInfo(silent: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _moduleBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final stateAsync = ref.watch(settingsControllerProvider);
    final runtimeState = ref.watch(appRuntimeControllerProvider).value;
    final isDesktop = MediaQuery.sizeOf(context).width >= Breakpoints.mobile;
    final selectedSection = _sectionFromKey(widget.sectionKey) ?? _SettingsSection.basic;
    final content = stateAsync.when(
      loading: () => const Center(child: shad.CircularProgressIndicator()),
      error: (error, _) =>
          _ErrorState(error: error, onRetry: () => ref.read(settingsControllerProvider.notifier).reload()),
      data: (state) {
        _syncConfig(state.config);
        if (kIsWeb) {
          _syncWebStartConfig(state.config.api, runtimeState);
        } else if (runtimeState != null) {
          _syncStartConfig(runtimeState.startConfig);
        }
        return ResponsiveMenuLayout<_SettingsSection>(
          title: context.l10n.setting,
          items: _menuItems,
          selectedValue: selectedSection,
          onSelected: (section) => _selectSection(section, isDesktop: isDesktop),
          mobileContentTitleBuilder: _sectionTitle,
          mobileContentVisible: widget.sectionKey != null,
          onMobileBack: _leaveMobileSection,
          contentBuilder: (context, section) => _buildSectionContent(section, runtimeState),
        );
      },
    );

    return shad.Scaffold(
      backgroundColor: palette.bg,
      child: isDesktop
          ? Row(
              children: [
                const PrimaryRail(activeSection: RailSection.settings),
                Expanded(child: content),
              ],
            )
          : Stack(
              children: [
                Positioned.fill(child: BottomNavInset(child: content)),
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: PrimaryBottomNavigation(activeSection: RailSection.settings),
                ),
              ],
            ),
    );
  }

  void _selectSection(_SettingsSection section, {required bool isDesktop}) {
    final location = '/settings/${section.name}';
    if (isDesktop) {
      context.go(location);
    } else {
      context.push(location);
    }
  }

  void _leaveMobileSection() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/settings');
    }
  }

  _SettingsSection? _sectionFromKey(String? key) {
    for (final section in _SettingsSection.values) {
      if (section.name == key) return section;
    }
    return null;
  }

  List<ResponsiveMenuItem<_SettingsSection>> get _menuItems => [
    ResponsiveMenuItem(value: _SettingsSection.basic, label: context.l10n.basicSettings, icon: Icons.tune_outlined),
    ResponsiveMenuItem(
      value: _SettingsSection.downloads,
      label: context.l10n.downloadSettings,
      icon: Icons.download_outlined,
    ),
    ResponsiveMenuItem(
      value: _SettingsSection.advanced,
      label: context.l10n.advancedSettings,
      icon: Icons.code_outlined,
    ),
  ];

  Widget _buildSectionContent(_SettingsSection section, AppRuntimeState? runtimeState) {
    final config = _config!;
    final palette = AppPalette.of(context);
    final platform = ref.watch(appPlatformControllerProvider).value;
    final isDesktop = MediaQuery.sizeOf(context).width >= Breakpoints.mobile;

    return Padding(
      padding: EdgeInsets.only(
        top: isDesktop && AppWindowChrome.reservesHeaderInset ? AppDesignTokens.windowHeaderHeight : 0,
      ),
      child: Column(
        children: [
          if (isDesktop)
            SizedBox(
              height: AppDesignTokens.contentHeaderHeight,
              child: SettingsContentFrame(
                child: SizedBox(
                  key: const ValueKey('settings-header-content'),
                  width: double.infinity,
                  child: Row(
                    children: [
                      Text(
                        _sectionTitle(section),
                        style: TextStyle(color: palette.textPrimary, fontSize: 22, fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: ListView(
              key: const ValueKey('settings-section-scroll-view'),
              padding: const EdgeInsets.only(top: AppDesignTokens.space8, bottom: 28),
              children: [
                SettingsContentFrame(
                  child: SizedBox(
                    key: const ValueKey('settings-body-content'),
                    width: double.infinity,
                    child: _sectionBody(section, config, platform, runtimeState),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionBody(
    _SettingsSection section,
    DownloaderConfig config,
    AppPlatformState? platform,
    AppRuntimeState? runtimeState,
  ) {
    final apiConfigDirty = _startConfig != null && _startDraftSignature() != _loadedStartSignature;
    final apiServerVisualState = _apiServerVisualState(runtimeState);
    final palette = AppPalette.of(context);
    switch (section) {
      case _SettingsSection.basic:
        return _SettingsSectionStack(
          children: [
            _SettingsBlock(
              title: context.l10n.ui,
              child: _SettingsGroup(
                children: [
                  SettingsItem(
                    title: context.l10n.theme,
                    child: ThemeModeSelector(
                      value: ref.watch(appAppearanceControllerProvider).themeMode,
                      accent: ref.watch(appAppearanceControllerProvider).themeColor,
                      onChanged: (mode) {
                        ref.read(appAppearanceControllerProvider.notifier).setThemeMode(mode);
                        _mutateConfig((next) => next.extra.themeMode = mode.key);
                      },
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.themeColor,
                    subtitle: context.l10n.themeColorDescription,
                    child: ThemeColorSelector(
                      value: ref.watch(appAppearanceControllerProvider).themeColor,
                      onChanged: (color) {
                        ref.read(appAppearanceControllerProvider.notifier).setThemeColor(color);
                        _mutateConfig((next) => next.extra.themeColor = color.key);
                      },
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.locale,
                    child: SettingsLanguageSelect(
                      value: _languageValue(config),
                      onChanged: (value) {
                        _mutateConfig((next) => next.extra.locale = value == 'system' ? '' : value);
                      },
                    ),
                  ),
                ],
              ),
            ),
            _SettingsBlock(
              title: context.l10n.general,
              child: _SettingsGroup(
                children: [
                  SettingsItem(
                    title: context.l10n.browserExtension,
                    subtitle: context.l10n.browserExtensionDescription,
                    child: _BrowserExtensionLinks(onOpen: _openBrowserExtension),
                  ),
                  if (Util.isWindows() || Util.isLinux())
                    SettingsItem(
                      title: context.l10n.launchAtStartup,
                      child: shad.Switch(
                        value: platform?.launchAtStartup ?? false,
                        onChanged: (value) => _runAction(
                          () => ref.read(appPlatformControllerProvider.notifier).setLaunchAtStartup(value),
                        ),
                      ),
                    ),
                  if (Util.isMacos())
                    SettingsItem(
                      title: context.l10n.runAsMenubarApp,
                      subtitle: context.l10n.runAsMenubarAppDesc,
                      child: shad.Switch(
                        value: platform?.runAsMenubarApp ?? false,
                        onChanged: (value) => _runAction(
                          () => ref.read(appPlatformControllerProvider.notifier).setRunAsMenubarApp(value),
                        ),
                      ),
                    ),
                  // ===== Android 系统级行为开关 =====
                  // 这三项之前只有配置字段、没有入口，用户完全没法开。
                  if (Util.isAndroid())
                    SettingsItem(
                      title: '开机自动运行',
                      subtitle: '开机后自动拉起内核与端口，无需手动打开',
                      child: shad.Switch(
                        value: _autoStart,
                        onChanged: (value) => unawaited(_setAutoStart(value)),
                      ),
                    ),
                  if (Util.isAndroid())
                    SettingsItem(
                      title: '退出时最小化',
                      subtitle: '按返回/关闭时不结束进程，转为后台继续下载',
                      child: shad.Switch(
                        value: _minimizeOnExit,
                        onChanged: (value) => unawaited(_setMinimizeOnExit(value)),
                      ),
                    ),
                  if (Util.isAndroid())
                    SettingsItem(
                      title: '从最近任务隐藏',
                      subtitle: '不在系统多任务列表中出现，仅通过通知与悬浮窗交互',
                      child: shad.Switch(
                        value: _hideFromRecents,
                        onChanged: (value) => unawaited(_setHideFromRecents(value)),
                      ),
                    ),
                  if (Util.isDesktop())
                    SettingsItem(
                      title: context.l10n.desktopNotification,
                      subtitle: context.l10n.desktopNotificationDescription,
                      child: shad.Switch(
                        value: config.extra.desktopNotification,
                        onChanged: (value) => _mutateConfig((next) => next.extra.desktopNotification = value),
                      ),
                    ),
                  if (Util.isIOS())
                    SettingsItem(
                      title: context.l10n.backgroundLocationKeepAlive,
                      subtitle: context.l10n.backgroundLocationKeepAliveDescription,
                      child: shad.Switch(
                        value: config.extra.backgroundLocationKeepAlive,
                        onChanged: (value) => unawaited(_setBackgroundLocationKeepAlive(value)),
                      ),
                    ),
                  if (Util.isIOS())
                    SettingsItem(
                      title: context.l10n.backgroundContinuedProcessing,
                      subtitle: context.l10n.backgroundContinuedProcessingDescription,
                      child: shad.Switch(
                        value: config.extra.backgroundContinuedProcessing,
                        onChanged: (value) => unawaited(_setBackgroundContinuedProcessing(value)),
                      ),
                    ),
                ],
              ),
            ),
            _SettingsBlock(
              title: context.l10n.about,
              child: _SettingsGroup(
                children: [
                  SettingsItem(
                    title: context.l10n.notifyWhenNewVersion,
                    child: shad.Switch(
                      value: config.extra.notifyWhenNewVersion,
                      onChanged: (value) => _mutateConfig((next) => next.extra.notifyWhenNewVersion = value),
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.version,
                    subtitle: context.l10n.currentVersion(_versionLabel),
                    child: _UpdateActionControl(platform: platform),
                  ),
                ],
              ),
            ),
          ],
        );
      case _SettingsSection.downloads:
        return _SettingsSectionStack(
          children: [
            _SettingsBlock(
              title: context.l10n.general,
              child: _SettingsGroup(
                children: [
                  SettingsItem(
                    title: '静默下载',
                    subtitle: '关闭：正常弹出创建页 · 静默：不弹创建页直接下载并进入任务列表 · 无界面：不弹任何页面，仅系统通知',
                    child: AppChoiceSegmentedControl<String>(
                      value: config.extra.silentDownloadMode,
                      buttonKeyPrefix: 'settings-silent-mode',
                      alignment: WrapAlignment.start,
                      options: const [
                        AppChoiceOption(value: 'off', label: '关闭', icon: Icons.cancel_outlined),
                        AppChoiceOption(value: 'list', label: '静默（跳列表）', icon: Icons.list_alt_outlined),
                        AppChoiceOption(value: 'none', label: '无界面（仅通知）', icon: Icons.notifications_none_outlined),
                      ],
                      onChanged: (value) => _mutateConfig((next) => next.extra.silentDownloadMode = value),
                    ),
                  ),
                  if (_moduleSupported)
                    SettingsItem(
                      title: '悬浮窗提示',
                      subtitle: _overlayPermission
                          ? '无界面下载时显示系统级悬浮窗（独立于 App，可跨应用显示）'
                          : '未授予「显示在其他应用上层」权限，点此开启；否则仅发送通知',
                      child: Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (!_overlayPermission)
                            AppLoadingButton(
                              key: const ValueKey('overlay-permission-button'),
                              onPressed: () => unawaited(_requestOverlayPermission()),
                              loading: false,
                              icon: const Icon(Icons.layers_outlined),
                              child: const Text('授权'),
                            ),
                          shad.Switch(
                            value: _overlayEnabled,
                            onChanged: (value) => _runAction(() async {
                              setState(() => _overlayEnabled = value);
                              await ref.read(systemBridgeProvider).setOverlayEnabled(value);
                            }),
                          ),
                        ],
                      ),
                    ),
                  SettingsItem(
                    title: '下载弹窗样式',
                    subtitle: '创建任务时的呈现方式',
                    child: AppChoiceSegmentedControl<String>(
                      value: config.extra.downloadPopupStyle,
                      buttonKeyPrefix: 'settings-popup-style',
                      alignment: WrapAlignment.start,
                      options: const [
                        AppChoiceOption(value: 'fullscreen', label: '全屏', icon: Icons.fullscreen_outlined),
                        AppChoiceOption(value: 'floating', label: '浮窗', icon: Icons.picture_in_picture_alt_outlined),
                        AppChoiceOption(value: 'notification', label: '实时通知', icon: Icons.notifications_active_outlined),
                        AppChoiceOption(
                          value: 'floatingNotification',
                          label: '浮窗 + 通知',
                          icon: Icons.layers_outlined,
                        ),
                      ],
                      onChanged: (value) => _mutateConfig((next) => next.extra.downloadPopupStyle = value),
                    ),
                  ),
                  SettingsItem(
                    title: '弹窗呈现位置',
                    subtitle: '创建任务弹窗从哪里出现',
                    child: AppChoiceSegmentedControl<String>(
                      value: config.extra.dialogPresentation,
                      buttonKeyPrefix: 'settings-dialog-pos',
                      alignment: WrapAlignment.start,
                      options: const [
                        AppChoiceOption(value: 'center', label: '居中浮窗', icon: Icons.crop_square_outlined),
                        AppChoiceOption(value: 'bottom', label: '底部弹出', icon: Icons.vertical_align_bottom_outlined),
                      ],
                      onChanged: (value) {
                        _mutateConfig((next) => next.extra.dialogPresentation = value);
                        // 系统悬浮窗（静默下载）读的是原生偏好，
                        // 只改 Dart 配置会让两边样式不一致。
                        ref.read(systemBridgeProvider).setDialogPresentation(value);
                      },
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.downloadDir,
                    child: AppPathPickerField.downloadDirectory(
                      fieldKey: const ValueKey('download-directory-input'),
                      controller: _downloadDirController,
                      pickerKey: const ValueKey('download-directory-picker'),
                      desktopWidth: AppDesignTokens.settingsFormControlWidth,
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.downloadCategories,
                    child: DownloadCategoriesControl(
                      categories: config.categories,
                      displayName: _categoryName,
                      onAdd: () => unawaited(_editDownloadCategory()),
                      onEdit: (category) => unawaited(_editDownloadCategory(category)),
                      onDelete: (category) => unawaited(_deleteDownloadCategory(category)),
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.autoCategorizeByExtension,
                    subtitle: context.l10n.autoCategorizeByExtensionDescription,
                    child: shad.Switch(
                      value: config.autoCategorize,
                      onChanged: (value) => _mutateConfig((next) => next.autoCategorize = value),
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.maxRunning,
                    subtitle: context.l10n.maxRunningDescription,
                    child: _NumberSettingControl(
                      fieldKey: const ValueKey('max-running-input'),
                      controller: _maxRunningController,
                      min: 1,
                      max: 256,
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.defaultDirectDownload,
                    child: shad.Switch(
                      value: config.extra.defaultDirectDownload,
                      onChanged: (value) => _mutateConfig((next) => next.extra.defaultDirectDownload = value),
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.autoStartTasks,
                    child: shad.Switch(
                      value: config.autoStartTasks,
                      onChanged: (value) => _mutateConfig((next) => next.autoStartTasks = value),
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.autoTorrentEnable,
                    child: shad.Switch(
                      value: config.autoTorrent.enable,
                      onChanged: (value) => _mutateConfig((next) => next.autoTorrent.enable = value),
                    ),
                  ),
                  if (config.autoTorrent.enable)
                    SettingsItem(
                      title: context.l10n.autoTorrentDeleteAfterDownload,
                      child: shad.Switch(
                        value: config.autoTorrent.deleteAfterDownload,
                        onChanged: (value) => _mutateConfig((next) => next.autoTorrent.deleteAfterDownload = value),
                      ),
                    ),
                  SettingsItem(
                    title: context.l10n.autoDeleteMissingFileTasks,
                    child: shad.Switch(
                      value: config.autoDeleteMissingFileTasks,
                      onChanged: (value) => _mutateConfig((next) => next.autoDeleteMissingFileTasks = value),
                    ),
                  ),
                ],
              ),
            ),
            _SettingsBlock(
              key: const ValueKey('settings-http-block'),
              title: 'HTTP',
              child: _SettingsGroup(
                children: [
                  SettingsItem(
                    title: 'User-Agent',
                    subtitle: context.l10n.defaultUserAgentDescription,
                    child: _TextSettingControl(
                      fieldKey: const ValueKey('http-user-agent-input'),
                      controller: _httpUserAgentController,
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.connections,
                    child: _NumberSettingControl(
                      fieldKey: const ValueKey('http-connections-input'),
                      controller: _httpConnectionsController,
                      min: 1,
                      max: 256,
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.useServerCtime,
                    child: shad.Switch(
                      value: config.protocolConfig.http.useServerCtime,
                      onChanged: (value) => _mutateConfig((next) => next.protocolConfig.http.useServerCtime = value),
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.autoExtract,
                    child: shad.Switch(
                      value: config.archive.autoExtract,
                      onChanged: (value) => _mutateConfig((next) => next.archive.autoExtract = value),
                    ),
                  ),
                  if (config.archive.autoExtract)
                    SettingsItem(
                      title: context.l10n.deleteAfterExtract,
                      child: shad.Switch(
                        value: config.archive.deleteAfterExtract,
                        onChanged: (value) => _mutateConfig((next) => next.archive.deleteAfterExtract = value),
                      ),
                    ),
                ],
              ),
            ),
            _SettingsBlock(
              key: const ValueKey('settings-ftp-block'),
              title: 'FTP',
              child: _SettingsGroup(
                children: [
                  SettingsItem(
                    title: context.l10n.connections,
                    child: _NumberSettingControl(
                      fieldKey: const ValueKey('ftp-connections-input'),
                      controller: _ftpConnectionsController,
                      min: 1,
                      max: _ftpMaxConnections,
                    ),
                  ),
                ],
              ),
            ),
            _SettingsBlock(
              title: 'BitTorrent',
              child: _SettingsGroup(
                children: [
                  if (Util.isWindows())
                    SettingsItem(
                      title: context.l10n.setAsDefaultBtClient,
                      child: shad.Switch(
                        value: config.extra.defaultBtClient,
                        onChanged: (value) => unawaited(_setDefaultBtClient(value)),
                      ),
                    ),
                  SettingsItem(
                    title: context.l10n.listenPort,
                    child: _NumberSettingControl(
                      fieldKey: const ValueKey('bt-listen-port-input'),
                      controller: _btListenPortController,
                      min: 0,
                      max: 65535,
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.enableDht,
                    subtitle: context.l10n.restartRequired,
                    child: shad.Switch(
                      value: !config.protocolConfig.bt.disableDht,
                      onChanged: (value) => _mutateConfig((next) => next.protocolConfig.bt.disableDht = !value),
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.enablePex,
                    subtitle: context.l10n.restartRequired,
                    child: shad.Switch(
                      value: !config.protocolConfig.bt.disablePex,
                      onChanged: (value) => _mutateConfig((next) => next.protocolConfig.bt.disablePex = !value),
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.seedKeep,
                    child: shad.Switch(
                      value: config.protocolConfig.bt.seedKeep,
                      onChanged: (value) => _mutateConfig((next) => next.protocolConfig.bt.seedKeep = value),
                    ),
                  ),
                  if (!config.protocolConfig.bt.seedKeep) ...[
                    SettingsItem(
                      title: context.l10n.seedRatio,
                      child: _NumberSettingControl(
                        fieldKey: const ValueKey('bt-seed-ratio-input'),
                        controller: _btSeedRatioController,
                        min: 0,
                        step: 0.1,
                        decimalPlaces: 2,
                      ),
                    ),
                    SettingsItem(
                      title: context.l10n.seedTime,
                      child: _NumberSettingControl(
                        fieldKey: const ValueKey('bt-seed-time-input'),
                        controller: _btSeedTimeController,
                        min: 0,
                        max: 100000000,
                      ),
                    ),
                  ],
                  SettingsItem(
                    title: context.l10n.subscribeTracker,
                    stacked: true,
                    child: TrackerSubscriptionsControl(
                      urls: config.protocolConfig.bt.trackerSubscribeUrls,
                      statuses: config.protocolConfig.bt.state.trackerSubscriptionStatuses,
                      autoUpdate: config.protocolConfig.bt.autoUpdateTrackers,
                      lastUpdated: config.protocolConfig.bt.state.lastTrackerUpdateTime,
                      onChanged: (urls) => _mutateConfig((next) => next.protocolConfig.bt.trackerSubscribeUrls = urls),
                      onAutoUpdateChanged: (value) =>
                          _mutateConfig((next) => next.protocolConfig.bt.autoUpdateTrackers = value),
                      onUpdate: _updateTrackers,
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.addTracker,
                    subtitle: context.l10n.onePerLine,
                    child: _TextSettingControl(controller: _customTrackersController, minLines: 7),
                  ),
                ],
              ),
            ),
            _SettingsBlock(
              key: const ValueKey('settings-hls-block'),
              title: 'HLS',
              child: _SettingsGroup(
                children: [
                  SettingsItem(
                    title: context.l10n.connections,
                    child: _NumberSettingControl(
                      fieldKey: const ValueKey('hls-connections-input'),
                      controller: _hlsConnectionsController,
                      min: 1,
                      max: 256,
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.maxRetries,
                    child: _NumberSettingControl(
                      fieldKey: const ValueKey('hls-max-retries-input'),
                      controller: _hlsMaxRetriesController,
                      min: 0,
                      max: 30,
                    ),
                  ),
                ],
              ),
            ),
            _SettingsBlock(
              title: 'ED2K',
              child: _SettingsGroup(
                children: [
                  SettingsItem(
                    title: context.l10n.ed2kTcpPort,
                    child: _NumberSettingControl(
                      fieldKey: const ValueKey('ed2k-tcp-port-input'),
                      controller: _ed2kListenPortController,
                      min: 0,
                      max: 65535,
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.ed2kUdpPort,
                    child: _NumberSettingControl(
                      fieldKey: const ValueKey('ed2k-udp-port-input'),
                      controller: _ed2kUdpPortController,
                      min: 0,
                      max: 65535,
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.ed2kServerList,
                    subtitle: context.l10n.onePerLine,
                    child: _TextSettingControl(
                      fieldKey: const ValueKey('ed2k-server-address-input'),
                      hintText: context.l10n.ed2kServersHint,
                      controller: _ed2kServerAddrController,
                      minLines: 5,
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.ed2kServerMet,
                    subtitle: context.l10n.onePerLine,
                    child: _TextSettingControl(
                      fieldKey: const ValueKey('ed2k-server-met-input'),
                      hintText: context.l10n.ed2kServerMetHint,
                      controller: _ed2kServerMetController,
                      minLines: 4,
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.ed2kNodesDat,
                    subtitle: context.l10n.onePerLine,
                    child: _TextSettingControl(
                      fieldKey: const ValueKey('ed2k-nodes-dat-input'),
                      hintText: context.l10n.ed2kNodesDatHint,
                      controller: _ed2kNodesDatController,
                      minLines: 4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      case _SettingsSection.advanced:
        return _SettingsSectionStack(
          children: [
            if (_moduleSupported)
              _SettingsBlock(
                title: '模块',
                child: _SettingsGroup(
                  children: [
                    SettingsItem(
                      title: '模块服务',
                      subtitle: _moduleError ??
                          (_moduleInfo == null
                              ? '正在读取…'
                              : '端口 ${_moduleInfo!['port'] ?? '—'} · '
                                  '${_moduleInfo!['enabled'] == '1' ? '开机自启已开启' : '开机自启已关闭'}'),
                      child: _ApiServerStatusLight(
                        key: const ValueKey('module-status-light'),
                        state: _moduleInfo == null
                            ? (_moduleError != null
                                ? _ApiServerVisualState.failed
                                : _ApiServerVisualState.loading)
                            : (_moduleInfo!['state'] == 'running' &&
                                    _moduleInfo!['portopen'] == '1'
                                ? _ApiServerVisualState.running
                                : _ApiServerVisualState.stopped),
                        label: _moduleInfo == null
                            ? (_moduleError != null ? '未就绪' : '读取中')
                            : (_moduleInfo!['state'] == 'running' &&
                                    _moduleInfo!['portopen'] == '1'
                                ? '运行中'
                                : '已停止'),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.end,
                        children: [
                          AppLoadingButton(
                            key: const ValueKey('module-refresh-button'),
                            onPressed: _moduleLoading || _moduleBusy
                                ? null
                                : () => unawaited(_loadModuleInfo()),
                            loading: _moduleLoading,
                            icon: const Icon(Icons.refresh),
                            child: const Text('刷新'),
                          ),
                          AppLoadingButton(
                            key: const ValueKey('module-restart-button'),
                            onPressed: _moduleBusy || _moduleInfo == null
                                ? null
                                : () => unawaited(_runModuleAction('restart', '重启服务')),
                            loading: _moduleBusy,
                            icon: const Icon(Icons.restart_alt),
                            child: const Text('重启服务'),
                          ),
                          AppLoadingButton(
                            key: const ValueKey('module-toggle-button'),
                            onPressed: _moduleBusy || _moduleInfo == null
                                ? null
                                : () => unawaited(_runModuleAction(
                                      _moduleInfo!['enabled'] == '1' ? 'disable' : 'enable',
                                      _moduleInfo!['enabled'] == '1' ? '关闭端口' : '开启端口',
                                    )),
                            loading: _moduleBusy,
                            icon: Icon(
                              _moduleInfo?['enabled'] == '1'
                                  ? Icons.power_settings_new
                                  : Icons.play_circle_outline,
                            ),
                            child: Text(_moduleInfo?['enabled'] == '1' ? '关闭端口' : '开启端口'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            _SettingsBlock(
              title: 'API',
              child: _SettingsGroup(
                children: [
                  SettingsItem(
                    title: context.l10n.apiServerRuntimeStatus,
                    subtitle: _apiServerRuntimeDetails(runtimeState),
                    child: _ApiServerStatusLight(
                      key: const ValueKey('api-server-runtime-status'),
                      state: apiServerVisualState,
                      label: switch (apiServerVisualState) {
                        _ApiServerVisualState.loading => context.l10n.readingRuntimeStatus,
                        _ApiServerVisualState.running => context.l10n.apiServerRunning,
                        _ApiServerVisualState.stopped => context.l10n.apiServerStopped,
                        _ApiServerVisualState.failed => context.l10n.apiServerFailed,
                      },
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.listenAddress,
                    child: _HostPortControl(
                      hostController: _apiHostController,
                      portController: _apiPortController,
                      hostKey: const ValueKey('api-host-input'),
                      portKey: const ValueKey('api-port-input'),
                      enabled: !kIsWeb,
                    ),
                  ),
                  if (!kIsWeb)
                    SettingsItem(
                      title: context.l10n.apiToken,
                      child: _TextSettingControl(controller: _apiTokenController, obscureText: true),
                    ),
                  McpSettingsItem(
                    enabled: _startConfig?.mcpEnable ?? false,
                    readOnly: kIsWeb,
                    onChanged: (value) => setState(() => _startConfig?.mcpEnable = value),
                    onOpenAgentSetup: () => unawaited(_openMcpAgentSetup(runtimeState)),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.end,
                      children: [
                        if (kIsWeb)
                          AppTooltip(
                            message: context.l10n.webApiConfigReadOnlyHelp,
                            child: Padding(
                              key: const ValueKey('web-api-config-help'),
                              padding: const EdgeInsets.all(8),
                              child: Icon(Icons.help_outline, size: 17, color: palette.textMuted),
                            ),
                          ),
                        AppLoadingButton(
                          key: const ValueKey('toggle-api-server-button'),
                          onPressed: kIsWeb || runtimeState == null ? null : _toggleApiServer,
                          loading: _savingStartConfig,
                          icon: Icon(
                            kIsWeb || (runtimeState?.apiServerState.running ?? false)
                                ? Icons.stop_circle_outlined
                                : Icons.play_circle_outline,
                          ),
                          child: Text(
                            kIsWeb || (runtimeState?.apiServerState.running ?? false)
                                ? context.l10n.stopApiServer
                                : context.l10n.startApiServer,
                          ),
                        ),
                        AppLoadingButton(
                          key: const ValueKey('save-api-config-button'),
                          onPressed: kIsWeb || runtimeState == null || !apiConfigDirty ? null : _saveApiServerConfig,
                          loading: _savingStartConfig,
                          icon: const Icon(Icons.save_outlined),
                          variant: AppLoadingButtonVariant.primary,
                          child: Text(context.l10n.save),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _SettingsBlock(
              title: context.l10n.network,
              child: _SettingsGroup(
                children: [
                  SettingsItem(
                    title: context.l10n.proxy,
                    child: AppChoiceSegmentedControl<String>(
                      value: _proxyMode,
                      buttonKeyPrefix: 'settings-choice',
                      options: [
                        AppChoiceOption(value: 'none', label: context.l10n.noProxy, icon: Icons.block_outlined),
                        AppChoiceOption(
                          value: 'system',
                          label: context.l10n.systemProxy,
                          icon: Icons.computer_outlined,
                        ),
                        AppChoiceOption(value: 'custom', label: context.l10n.customProxy, icon: Icons.tune_outlined),
                      ],
                      onChanged: (value) => _mutateConfig((next) {
                        next.proxy.enable = value != 'none';
                        next.proxy.system = value == 'system';
                      }),
                    ),
                  ),
                  if (_proxyMode == 'custom') ...[
                    SettingsItem(
                      title: context.l10n.proxyProtocol,
                      child: AppChoiceSegmentedControl<String>(
                        value: _proxyScheme,
                        buttonKeyPrefix: 'settings-choice',
                        options: const [
                          AppChoiceOption(value: 'http', label: 'HTTP', icon: Icons.http_outlined),
                          AppChoiceOption(value: 'https', label: 'HTTPS', icon: Icons.https_outlined),
                          AppChoiceOption(value: 'socks5', label: 'SOCKS5', icon: Icons.security_outlined),
                        ],
                        onChanged: (value) => _mutateConfig((next) => next.proxy.scheme = value),
                      ),
                    ),
                    SettingsItem(
                      title: context.l10n.server,
                      child: _HostPortControl(
                        hostController: _proxyHostController,
                        portController: _proxyPortController,
                        hostKey: const ValueKey('proxy-host-input'),
                        portKey: const ValueKey('proxy-port-input'),
                      ),
                    ),
                    SettingsItem(
                      title: context.l10n.username,
                      child: _TextSettingControl(controller: _proxyUserController),
                    ),
                    SettingsItem(
                      title: context.l10n.password,
                      child: _TextSettingControl(controller: _proxyPasswordController, obscureText: true),
                    ),
                  ],
                  SettingsItem(
                    title: context.l10n.githubMirrorEnable,
                    subtitle: context.l10n.githubMirrorDesc,
                    child: shad.Switch(
                      value: config.githubMirror.enabled,
                      onChanged: (value) => _mutateConfig((next) => next.githubMirror.enabled = value),
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.githubMirror,
                    child: SettingsListEditor(
                      entries: [
                        for (final entry in config.githubMirror.mirrors.indexed)
                          if (!entry.$2.isDeleted)
                            SettingsListEntry(
                              id: 'github-mirror-${entry.$1}',
                              title: entry.$2.url,
                              subtitle: entry.$2.type.name,
                            ),
                      ],
                      onAdd: () => unawaited(_editGithubMirror()),
                      onEdit: (visibleIndex) => unawaited(_editGithubMirrorAtVisibleIndex(visibleIndex)),
                      onDelete: (visibleIndex) => unawaited(_deleteGithubMirrorAtVisibleIndex(visibleIndex)),
                    ),
                  ),
                ],
              ),
            ),
            _SettingsBlock(
              title: context.l10n.developer,
              child: _SettingsGroup(
                children: [
                  SettingsItem(
                    title: context.l10n.webhookEnable,
                    subtitle: context.l10n.webhookDesc,
                    child: shad.Switch(
                      value: config.webhook.enable,
                      onChanged: (value) => _mutateConfig((next) => next.webhook.enable = value),
                    ),
                  ),
                  SettingsItem(
                    title: context.l10n.webhookPush,
                    subtitle: context.l10n.webhookPushDescription,
                    child: SettingsListEditor(
                      entries: [
                        for (final entry in config.webhook.urls.indexed)
                          SettingsListEntry(id: 'webhook-${entry.$1}', title: entry.$2),
                      ],
                      onAdd: () => unawaited(_editWebhook()),
                      onEdit: (index) => unawaited(_editWebhook(index)),
                      onDelete: _deleteWebhook,
                      addButtonKey: const ValueKey('add-webhook-button'),
                    ),
                  ),
                  if (Util.isDesktop()) ...[
                    SettingsItem(
                      title: context.l10n.scriptEnable,
                      subtitle: context.l10n.scriptDesc,
                      child: shad.Switch(
                        value: config.script.enable,
                        onChanged: (value) => _mutateConfig((next) => next.script.enable = value),
                      ),
                    ),
                    SettingsItem(
                      title: context.l10n.scriptExecution,
                      subtitle: context.l10n.scriptExecutionDescription,
                      child: SettingsListEditor(
                        entries: [
                          for (final entry in config.script.paths.indexed)
                            SettingsListEntry(id: 'script-${entry.$1}', title: entry.$2),
                        ],
                        onAdd: () => unawaited(_editScript()),
                        onEdit: (index) => unawaited(_editScript(index)),
                        onDelete: _deleteScript,
                        addButtonKey: const ValueKey('add-script-button'),
                      ),
                    ),
                  ],
                  SettingsItem(
                    title: context.l10n.logDirectory,
                    subtitle: _logDirectoryLabel,
                    child: shad.SecondaryButton(
                      onPressed: kIsWeb ? null : _openLogDirectory,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.folder_open_outlined),
                          const SizedBox(width: AppDesignTokens.space8),
                          Text(context.l10n.open),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
    }
  }

  void _syncConfig(DownloaderConfig config) {
    final signature = _signature(config);
    if (_loadedSignature == signature && _config != null) {
      return;
    }
    _loadedSignature = signature;
    _config = DownloaderConfig.fromJson(config.toJson());
    _syncingControllers = true;
    _downloadDirController.text = _config!.downloadDir;
    _appliedDownloadDir = _config!.downloadDir;
    _maxRunningController.text = _config!.maxRunning.clamp(1, 256).toString();
    _httpUserAgentController.text = _config!.protocolConfig.http.userAgent;
    _httpConnectionsController.text = _config!.protocolConfig.http.connections.clamp(1, 256).toString();
    _ftpConnectionsController.text = _config!.protocolConfig.ftp.connections.clamp(1, _ftpMaxConnections).toString();
    _hlsConnectionsController.text = _config!.protocolConfig.hls.segmentConnections.clamp(1, 256).toString();
    _hlsMaxRetriesController.text = _config!.protocolConfig.hls.maxRetries.clamp(0, 30).toString();
    _btListenPortController.text = _config!.protocolConfig.bt.listenPort.clamp(0, 65535).toString();
    _btSeedRatioController.text = _config!.protocolConfig.bt.seedRatio.toString();
    _btSeedTimeController.text = (_config!.protocolConfig.bt.seedTime ~/ 60).clamp(0, 100000000).toString();
    _ed2kListenPortController.text = _config!.protocolConfig.ed2k.listenPort.clamp(0, 65535).toString();
    _ed2kUdpPortController.text = _config!.protocolConfig.ed2k.udpPort.clamp(0, 65535).toString();
    _ed2kServerAddrController.text = _formatEd2kMultiline(_config!.protocolConfig.ed2k.serverAddr);
    _ed2kServerMetController.text = _formatEd2kMultiline(_config!.protocolConfig.ed2k.serverMet);
    _ed2kNodesDatController.text = _formatEd2kMultiline(_config!.protocolConfig.ed2k.nodesDat);
    final proxyAddress = _splitHostPort(_config!.proxy.host);
    _proxyHostController.text = proxyAddress.host;
    _proxyPortController.text = proxyAddress.port;
    _proxyUserController.text = _config!.proxy.usr;
    _proxyPasswordController.text = _config!.proxy.pwd;
    _customTrackersController.text = _config!.protocolConfig.bt.customTrackers.join('\n');
    _syncingControllers = false;
  }

  void _syncStartConfig(StartConfig config, {bool force = false}) {
    final signature = _startSignature(config);
    if (!force && _loadedStartSignature == signature && _startConfig != null) {
      return;
    }
    if (!force &&
        _startConfig != null &&
        _startConfig!.network == config.network &&
        _startConfig!.address == config.address &&
        _startConfig!.apiToken == config.apiToken) {
      _startConfig!.apiEnable = config.apiEnable;
      _startConfig!.mcpEnable = config.mcpEnable;
      _loadedStartSignature = signature;
      return;
    }
    _loadedStartSignature = signature;
    _startConfig = _copyStartConfig(config);
    _syncingStartControllers = true;
    if (config.network == 'tcp' && _looksLikeTcpAddress(_startConfig!.address)) {
      final apiAddress = _splitHostPort(_startConfig!.address);
      _apiHostController.text = apiAddress.host;
      _apiPortController.text = apiAddress.port;
    } else {
      _apiHostController.text = '127.0.0.1';
      _apiPortController.text = '9999';
    }
    _apiTokenController.text = _startConfig!.apiToken;
    _syncingStartControllers = false;
  }

  void _syncWebStartConfig(ApiServerConfig config, AppRuntimeState? runtimeState) {
    final webConfig = StartConfig()
      ..network = 'tcp'
      ..address = webApiDisplayAddress(_webApiUri(runtimeState))
      ..apiEnable = true
      ..mcpEnable = config.mcpEnable
      ..storage = ''
      ..storageDir = ''
      ..refreshInterval = 0
      ..apiToken = config.token;
    _syncStartConfig(webConfig);
  }

  void _scheduleTextSave() {
    if (_syncingControllers || _config == null) {
      return;
    }
    _textSaveTimer?.cancel();
    _textSaveTimer = Timer(const Duration(milliseconds: 650), () {
      _applyTextControllers(_config!);
      unawaited(_saveConfig());
    });
  }

  void _handleStartDraftChanged() {
    if (_syncingStartControllers || !mounted) return;
    setState(() {});
  }

  void _mutateConfig(void Function(DownloaderConfig config) mutation) {
    final config = _config;
    if (config == null) {
      return;
    }
    setState(() => mutation(config));
    unawaited(_saveConfig());
  }

  void _applyTextControllers(DownloaderConfig config) {
    final downloadDir = _downloadDirController.text.trim();
    final previousDownloadDir = _appliedDownloadDir;
    _appliedDownloadDir = downloadDir;
    if (previousDownloadDir != null && !path.equals(previousDownloadDir, downloadDir)) {
      rebaseBuiltinCategoryPaths(config, oldDir: previousDownloadDir, newDir: downloadDir);
    }
    config.downloadDir = downloadDir;
    config.maxRunning = _boundedInt(_maxRunningController, fallback: config.maxRunning, min: 1, max: 256);
    config.protocolConfig.http.userAgent = _httpUserAgentController.text.trim();
    config.protocolConfig.http.connections = _boundedInt(
      _httpConnectionsController,
      fallback: config.protocolConfig.http.connections,
      min: 1,
      max: 256,
    );
    config.protocolConfig.ftp.connections = _boundedInt(
      _ftpConnectionsController,
      fallback: config.protocolConfig.ftp.connections,
      min: 1,
      max: _ftpMaxConnections,
    );
    config.protocolConfig.hls.segmentConnections = _boundedInt(
      _hlsConnectionsController,
      fallback: config.protocolConfig.hls.segmentConnections,
      min: 1,
      max: 256,
    );
    config.protocolConfig.hls.maxRetries = _boundedInt(
      _hlsMaxRetriesController,
      fallback: config.protocolConfig.hls.maxRetries,
      min: 0,
      max: 30,
    );
    config.protocolConfig.bt.listenPort = _boundedInt(
      _btListenPortController,
      fallback: config.protocolConfig.bt.listenPort,
      min: 0,
      max: 65535,
    );
    config.protocolConfig.bt.seedRatio =
        (double.tryParse(_btSeedRatioController.text.trim()) ?? config.protocolConfig.bt.seedRatio)
            .clamp(0, double.infinity)
            .toDouble();
    final seedMinutes = _boundedInt(
      _btSeedTimeController,
      fallback: config.protocolConfig.bt.seedTime ~/ 60,
      min: 0,
      max: 100000000,
    );
    config.protocolConfig.bt.seedTime = seedMinutes * 60;
    config.protocolConfig.ed2k.listenPort = _boundedInt(
      _ed2kListenPortController,
      fallback: config.protocolConfig.ed2k.listenPort,
      min: 0,
      max: 65535,
    );
    config.protocolConfig.ed2k.udpPort = _boundedInt(
      _ed2kUdpPortController,
      fallback: config.protocolConfig.ed2k.udpPort,
      min: 0,
      max: 65535,
    );
    config.protocolConfig.ed2k.serverAddr = _lines(_ed2kServerAddrController.text).join(',');
    config.protocolConfig.ed2k.serverMet = _lines(_ed2kServerMetController.text).join(',');
    config.protocolConfig.ed2k.nodesDat = _lines(_ed2kNodesDatController.text).join(',');
    config.proxy.host = _joinHostPort(_proxyHostController.text, _proxyPortController.text);
    config.proxy.usr = _proxyUserController.text.trim();
    config.proxy.pwd = _proxyPasswordController.text;
    config.protocolConfig.bt.customTrackers = _lines(_customTrackersController.text);
  }

  void _applyStartControllers(StartConfig config) {
    config.network = 'tcp';
    config.address = _joinHostPort(_apiHostController.text, _apiPortController.text);
    config.apiToken = _apiTokenController.text.trim();
  }

  Future<bool> _saveConfig() async {
    final config = _config;
    if (config == null) {
      return false;
    }
    _applyTextControllers(config);
    final snapshot = DownloaderConfig.fromJson(config.toJson());
    _loadedSignature = _signature(snapshot);
    try {
      await ref.read(settingsControllerProvider.notifier).save(snapshot);
      // 静默模式与悬浮窗开关必须同步给原生入口：
      // 外链是先进原生 SilentGateActivity 的，Dart 层这时候还没起来。
      await _syncSilentModeToNative(snapshot);
      return true;
    } catch (error) {
      if (mounted) _toast(error.toString());
      return false;
    }
  }

  /// 把静默下载模式同步到原生，让外链入口能独立判断是否需要界面。
  Future<void> _syncSilentModeToNative(DownloaderConfig config) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final bridge = ref.read(systemBridgeProvider);
      final mode = config.extra.silentDownloadMode;
      await bridge.setSilentMode(
        mode == 'none' ? 'headless' : (mode == 'list' ? 'jump' : 'off'),
      );
      await bridge.setOverlayEnabled(_overlayEnabled);
      final port = _moduleInfo?['port'];
      final parsed = int.tryParse(port ?? '');
      if (parsed != null && parsed > 0) {
        await bridge.setModulePort(parsed);
      }
    } catch (_) {
      // 原生通道不可用时忽略，不影响保存本身。
    }
  }

  Future<void> _saveApiServerConfig() async {
    final config = _startConfig;
    final runtimeState = ref.read(appRuntimeControllerProvider).value;
    if (config == null || runtimeState == null || _savingStartConfig) {
      return;
    }
    final snapshot = _copyStartConfig(config);
    _applyStartControllers(snapshot);
    final validationMessage = await _validateStartConfig(snapshot);
    if (validationMessage != null) {
      if (mounted) _toast(validationMessage);
      return;
    }
    if (runtimeState.apiServerState.running && !await _confirmRestartApiServer()) {
      return;
    }
    setState(() => _savingStartConfig = true);
    try {
      final controller = ref.read(appRuntimeControllerProvider.notifier);
      if (runtimeState.apiServerState.running) {
        await controller.restartApiServer(snapshot);
      } else {
        await controller.saveApiServerConfig(snapshot);
      }
      _syncStartConfig(ref.read(appRuntimeControllerProvider).requireValue.startConfig, force: true);
      if (mounted) _toast(context.l10n.apiConfigSaved, type: AppToastType.success);
    } catch (error) {
      if (mounted) _toast(error.toString());
    } finally {
      if (mounted) setState(() => _savingStartConfig = false);
    }
  }

  Future<void> _toggleApiServer() async {
    final runtimeState = ref.read(appRuntimeControllerProvider).value;
    if (runtimeState == null || _savingStartConfig) return;
    if (runtimeState.apiServerState.running && !await _confirmDisableApiServer()) return;

    setState(() => _savingStartConfig = true);
    try {
      final controller = ref.read(appRuntimeControllerProvider.notifier);
      if (runtimeState.apiServerState.running) {
        await controller.stopApiServer();
      } else {
        await controller.startApiServer();
      }
    } catch (error) {
      if (mounted) _toast(error.toString());
    } finally {
      if (mounted) setState(() => _savingStartConfig = false);
    }
  }

  Future<bool> _confirmDisableApiServer() async {
    final overlay = const shad.DialogOverlayHandler().show<bool>(
      context: context,
      alignment: Alignment.center,
      barrierDismissable: false,
      builder: (dialogContext) => shad.AlertDialog(
        key: const ValueKey('disable-api-server-dialog'),
        title: Text(dialogContext.l10n.stopListening),
        content: Text(dialogContext.l10n.disableApiServerConfirm),
        actions: [
          shad.SecondaryButton(
            key: const ValueKey('cancel-disable-api-server-button'),
            onPressed: () => shad.closeOverlay(dialogContext, false),
            child: Text(dialogContext.l10n.cancel),
          ),
          shad.DestructiveButton(
            key: const ValueKey('confirm-disable-api-server-button'),
            onPressed: () => shad.closeOverlay(dialogContext, true),
            child: Text(dialogContext.l10n.confirm),
          ),
        ],
      ),
    );
    return await overlay.future ?? false;
  }

  Future<bool> _confirmRestartApiServer() async {
    final overlay = const shad.DialogOverlayHandler().show<bool>(
      context: context,
      alignment: Alignment.center,
      barrierDismissable: false,
      builder: (dialogContext) => shad.AlertDialog(
        key: const ValueKey('restart-api-server-dialog'),
        title: Text(dialogContext.l10n.saveAndRestartApiServer),
        content: Text(dialogContext.l10n.restartApiServerConfirm),
        actions: [
          shad.SecondaryButton(
            key: const ValueKey('cancel-restart-api-server-button'),
            onPressed: () => shad.closeOverlay(dialogContext, false),
            child: Text(dialogContext.l10n.cancel),
          ),
          shad.PrimaryButton(
            key: const ValueKey('confirm-restart-api-server-button'),
            onPressed: () => shad.closeOverlay(dialogContext, true),
            child: Text(dialogContext.l10n.saveAndRestartApiServer),
          ),
        ],
      ),
    );
    return await overlay.future ?? false;
  }

  Future<String?> _validateStartConfig(StartConfig candidate) async {
    final l10n = context.l10n;
    final address = _splitHostPort(candidate.address);
    if (address.host.isEmpty) return l10n.serverRequired;
    final port = int.tryParse(address.port);
    if (port == null || port < 0 || port > 65535) return l10n.portRangeError;

    return null;
  }

  Future<void> _runAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) _toast(error.toString());
    }
  }

  Future<void> _setDefaultBtClient(bool enabled) async {
    try {
      enabled ? registerDefaultTorrentClient() : unregisterDefaultTorrentClient();
      _mutateConfig((config) => config.extra.defaultBtClient = enabled);
    } catch (error) {
      if (mounted) _toast(error.toString());
    }
  }

  Future<void> _setBackgroundLocationKeepAlive(bool enabled) async {
    if (enabled && !await LocationKeepAlive.requestPermission()) {
      if (mounted) _toast(context.l10n.backgroundLocationPermissionRequired);
      return;
    }
    _mutateConfig((config) => config.extra.backgroundLocationKeepAlive = enabled);
    await LocationKeepAliveCoordinator.instance.reconcile(enabled: enabled);
  }

  Future<void> _setBackgroundContinuedProcessing(bool enabled) async {
    if (enabled && !await ContinuedProcessing.isSupported()) {
      if (mounted) {
        _toast(context.l10n.backgroundContinuedProcessingUnsupported);
      }
      return;
    }

    final applied = await ContinuedProcessing.setEnabled(enabled);

    if (enabled && !applied) {
      if (mounted) {
        _toast(context.l10n.backgroundContinuedProcessingUnsupported);
      }
      return;
    }

    _mutateConfig((config) => config.extra.backgroundContinuedProcessing = enabled);
  }

  List<String> _lines(String text) {
    return text.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
  }

  String _formatEd2kMultiline(String value) {
    return value.split(RegExp(r'[,\r\n]+')).map((entry) => entry.trim()).where((entry) => entry.isNotEmpty).join('\n');
  }

  String _categoryName(DownloadCategory category) {
    if (category.name.isNotEmpty) {
      return category.name;
    }
    return switch (category.nameKey) {
      'categoryMusic' => context.l10n.categoryMusic,
      'categoryVideo' => context.l10n.categoryVideo,
      'categoryDocument' => context.l10n.categoryDocument,
      'categoryProgram' => context.l10n.categoryProgram,
      _ => context.l10n.downloadCategories,
    };
  }

  Future<void> _editDownloadCategory([DownloadCategory? category]) async {
    final draft = await showDownloadCategoryDialog(
      context,
      category: category,
      initialName: category == null ? '' : _categoryName(category),
      initialPath: _downloadDirController.text.trim(),
      categories: _config?.categories ?? const [],
      displayName: _categoryName,
    );
    if (draft == null || !mounted) return;

    _mutateConfig((config) {
      final categories = List<DownloadCategory>.from(config.categories);
      if (category == null) {
        categories.add(DownloadCategory(name: draft.name, path: draft.path, extensions: draft.extensions));
      } else {
        final index = categories.indexOf(category);
        if (index < 0) return;
        final nameChanged = draft.name != _categoryName(category);
        category
          ..name = draft.name
          ..path = draft.path
          ..extensions = draft.extensions
          ..isDeleted = false;
        if (nameChanged) category.nameKey = null;
      }
      config.categories = categories;
    });
  }

  Future<void> _deleteDownloadCategory(DownloadCategory category) async {
    final confirmed = await showDeleteDownloadCategoryDialog(context, _categoryName(category));
    if (!confirmed || !mounted) return;
    _mutateConfig((config) {
      if (category.isBuiltIn) {
        category.isDeleted = true;
        return;
      }
      config.categories = List<DownloadCategory>.from(config.categories)..remove(category);
    });
  }

  List<GithubMirror> get _visibleGithubMirrors =>
      _config?.githubMirror.mirrors.where((mirror) => !mirror.isDeleted).toList(growable: false) ?? const [];

  Future<void> _editGithubMirror([GithubMirror? mirror]) async {
    final draft = await showGithubMirrorDialog(context, mirror: mirror);
    if (draft == null || !mounted) return;
    _mutateConfig((config) {
      final mirrors = List<GithubMirror>.from(config.githubMirror.mirrors);
      if (mirror == null) {
        mirrors.add(GithubMirror(type: draft.type, url: draft.url));
      } else {
        final index = mirrors.indexOf(mirror);
        if (index < 0) return;
        mirrors[index] = GithubMirror(type: draft.type, url: draft.url, isBuiltIn: mirror.isBuiltIn, isDeleted: false);
      }
      config.githubMirror.mirrors = mirrors;
    });
  }

  Future<void> _editGithubMirrorAtVisibleIndex(int index) async {
    final mirrors = _visibleGithubMirrors;
    if (index < 0 || index >= mirrors.length) return;
    await _editGithubMirror(mirrors[index]);
  }

  Future<void> _deleteGithubMirrorAtVisibleIndex(int index) async {
    final mirrors = _visibleGithubMirrors;
    if (index < 0 || index >= mirrors.length) return;
    final mirror = mirrors[index];
    if (!await showDeleteSettingsEntryDialog(context, mirror.url) || !mounted) return;
    _mutateConfig((config) {
      if (mirror.isBuiltIn) {
        mirror.isDeleted = true;
      } else {
        config.githubMirror.mirrors = List<GithubMirror>.from(config.githubMirror.mirrors)..remove(mirror);
      }
    });
  }

  Future<void> _editWebhook([int? index]) async {
    final urls = _config?.webhook.urls ?? const [];
    if (index != null && (index < 0 || index >= urls.length)) return;
    final value = await showTextSettingDialog(
      context,
      title: index == null ? context.l10n.addWebhook : context.l10n.editWebhook,
      fieldLabel: context.l10n.webhookUrlHint,
      initialValue: index == null ? '' : urls[index],
      requireHttpUrl: true,
      onTest: (url) => ref.read(settingsControllerProvider.notifier).testWebhook(url),
    );
    if (value == null || !mounted) return;
    _mutateConfig((config) {
      final next = List<String>.from(config.webhook.urls);
      if (index == null) {
        next.add(value);
      } else {
        next[index] = value;
      }
      config.webhook.urls = next;
    });
  }

  void _deleteWebhook(int index) {
    _mutateConfig((config) {
      if (index < 0 || index >= config.webhook.urls.length) return;
      config.webhook.urls = List<String>.from(config.webhook.urls)..removeAt(index);
    });
  }

  Future<void> _editScript([int? index]) async {
    final paths = _config?.script.paths ?? const [];
    if (index != null && (index < 0 || index >= paths.length)) return;
    final value = await showTextSettingDialog(
      context,
      title: index == null ? context.l10n.addScript : context.l10n.editScript,
      fieldLabel: context.l10n.scriptPath,
      initialValue: index == null ? '' : paths[index],
      pickFile: true,
    );
    if (value == null || !mounted) return;
    _mutateConfig((config) {
      final next = List<String>.from(config.script.paths);
      if (index == null) {
        next.add(value);
      } else {
        next[index] = value;
      }
      config.script.paths = next;
    });
  }

  void _deleteScript(int index) {
    _mutateConfig((config) {
      if (index < 0 || index >= config.script.paths.length) return;
      config.script.paths = List<String>.from(config.script.paths)..removeAt(index);
    });
  }

  Future<void> _updateTrackers() async {
    final config = _config;
    if (config == null) return;
    await _runAction(() async {
      if (!await _saveConfig()) return;
      try {
        await ref.read(appRuntimeControllerProvider.notifier).updateTrackers();
      } finally {
        if (mounted) await ref.read(settingsControllerProvider.notifier).reload(showLoading: false);
      }
    });
  }

  String _signature(DownloaderConfig config) {
    return config.toJson().toString();
  }

  String _startSignature(StartConfig config) {
    return '${config.apiEnable}|${config.mcpEnable}|${config.network}|${config.address}|${config.apiToken}';
  }

  String _startDraftSignature() {
    final address = _joinHostPort(_apiHostController.text, _apiPortController.text);
    return '${_startConfig?.apiEnable ?? false}|${_startConfig?.mcpEnable ?? false}|tcp|$address|${_apiTokenController.text.trim()}';
  }

  StartConfig _copyStartConfig(StartConfig config) {
    return StartConfig()
      ..network = config.network
      ..address = config.address
      ..apiEnable = config.apiEnable
      ..mcpEnable = config.mcpEnable
      ..storage = config.storage
      ..storageDir = config.storageDir
      ..refreshInterval = config.refreshInterval
      ..apiToken = config.apiToken
      ..webViewRpcConfig = config.webViewRpcConfig;
  }

  String get _proxyMode {
    final proxy = _config?.proxy;
    if (proxy == null || !proxy.enable) return 'none';
    return proxy.system ? 'system' : 'custom';
  }

  String get _proxyScheme {
    final scheme = _config?.proxy.scheme;
    return switch (scheme) {
      'https' || 'socks5' => scheme!,
      _ => 'http',
    };
  }

  String get _versionLabel {
    try {
      return appVersion;
    } catch (_) {
      return '-';
    }
  }

  String get _logDirectoryLabel {
    try {
      return logsDir();
    } catch (_) {
      return context.l10n.logDirectoryUnavailable;
    }
  }

  void _openLogDirectory() {
    try {
      unawaited(launchUrl(Uri.file(logsDir()), mode: LaunchMode.externalApplication));
    } catch (error) {
      _toast(error.toString());
    }
  }

  Future<void> _openBrowserExtension(Uri uri) async {
    await _openExternalUri(uri);
  }

  Future<void> _openExternalUri(Uri uri) async {
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        _toast(context.l10n.unableOpenExternalLink);
      }
    } catch (error) {
      if (mounted) _toast(error.toString());
    }
  }

  Future<void> _openMcpAgentSetup(AppRuntimeState? runtimeState) async {
    final mcpRunning = kIsWeb
        ? (_startConfig?.mcpEnable ?? false)
        : runtimeState?.apiServerState.running == true && runtimeState?.apiServerState.mcpEnabled == true;
    await showMcpAgentSetupDialog(
      context,
      endpoint: _mcpEndpoint(runtimeState),
      apiToken: _apiTokenController.text.trim(),
      mcpRunning: mcpRunning,
      allowManualApiTokenTemplate: kIsWeb,
    );
  }

  String _mcpEndpoint(AppRuntimeState? runtimeState) {
    if (kIsWeb) {
      return webMcpEndpoint(_webApiUri(runtimeState));
    }

    final apiState = runtimeState?.apiServerState;
    final address = apiState != null && apiState.running && apiState.network == 'tcp'
        ? apiState.runningAddress()
        : _joinHostPort(_apiHostController.text, _apiPortController.text);
    final parts = _splitHostPort(address);
    var host = parts.host;
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    if (host == '0.0.0.0' || host == '::') {
      host = host == '::' ? '::1' : '127.0.0.1';
    }
    final port = int.tryParse(parts.port);
    return Uri(scheme: 'http', host: host, port: port, path: '/mcp').toString();
  }

  bool _looksLikeTcpAddress(String address) {
    final separator = address.lastIndexOf(':');
    if (separator <= 0 || separator == address.length - 1) {
      return false;
    }
    return int.tryParse(address.substring(separator + 1)) != null;
  }

  ({String host, String port}) _splitHostPort(String address) {
    final value = address.trim();
    if (value.isEmpty) return (host: '', port: '');

    // Bracketed IPv6 addresses keep their internal colons, for example [::1]:9999.
    if (value.startsWith('[')) {
      final closingBracket = value.indexOf(']');
      if (closingBracket > 0 && closingBracket + 1 < value.length && value[closingBracket + 1] == ':') {
        return (host: value.substring(0, closingBracket + 1), port: value.substring(closingBracket + 2));
      }
    }

    final separator = value.lastIndexOf(':');
    if (separator <= 0 || separator == value.length - 1) {
      return (host: value, port: '');
    }
    return (host: value.substring(0, separator), port: value.substring(separator + 1));
  }

  String _joinHostPort(String hostText, String portText) {
    final host = hostText.trim();
    final port = portText.trim();
    if (host.isEmpty && port.isEmpty) return '';
    if (port.isEmpty) return host;
    return '$host:$port';
  }

  int _boundedInt(TextEditingController controller, {required int fallback, required int min, required int max}) {
    final value = int.tryParse(controller.text.trim());
    return (value ?? fallback).clamp(min, max).toInt();
  }

  String _sectionTitle(_SettingsSection section) {
    return switch (section) {
      _SettingsSection.basic => context.l10n.basicSettings,
      _SettingsSection.downloads => context.l10n.downloadSettings,
      _SettingsSection.advanced => context.l10n.advancedSettings,
    };
  }

  String? _apiServerRuntimeDetails(AppRuntimeState? runtimeState) {
    if (runtimeState == null) return null;
    if (kIsWeb) {
      final apiUri = _webApiUri(runtimeState);
      return '${apiUri.scheme}://${webApiDisplayAddress(apiUri)}';
    }
    final apiState = runtimeState.apiServerState;
    final details = <String>[];
    if (apiState.running) {
      details.add('http://${apiState.runningAddress()}');
    }
    if (apiState.lastError.isNotEmpty) {
      details.add(apiState.lastError);
    } else if (apiState.pendingApply) {
      details.add(context.l10n.apiConfigPendingApply);
    }
    return details.isEmpty ? null : details.join('\n');
  }

  Uri _webApiUri(AppRuntimeState? runtimeState) {
    final address = runtimeState?.startConfig.address ?? '';
    return Uri.parse(normalizeWebApiBaseUrl(address, Uri.base));
  }

  _ApiServerVisualState _apiServerVisualState(AppRuntimeState? runtimeState) {
    if (runtimeState == null) return _ApiServerVisualState.loading;
    if (kIsWeb) return _ApiServerVisualState.running;
    final apiState = runtimeState.apiServerState;
    if (apiState.running) return _ApiServerVisualState.running;
    if (apiState.lastError.isNotEmpty) return _ApiServerVisualState.failed;
    return _ApiServerVisualState.stopped;
  }

  String _languageValue(DownloaderConfig config) {
    final locale = supportedLocaleFromConfig(config.extra.locale);
    return locale == null ? 'system' : localeConfigValue(locale);
  }

  void _toast(String message, {AppToastType type = AppToastType.error}) {
    showAppToast(context, message, type: type);
  }
}

enum _ApiServerVisualState { loading, running, stopped, failed }

class _ApiServerStatusLight extends StatefulWidget {
  const _ApiServerStatusLight({super.key, required this.state, required this.label});

  final _ApiServerVisualState state;
  final String label;

  @override
  State<_ApiServerStatusLight> createState() => _ApiServerStatusLightState();
}

class _ApiServerStatusLightState extends State<_ApiServerStatusLight> with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  bool _disableAnimations = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400), value: 0.35);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _syncPulseAnimation();
  }

  @override
  void didUpdateWidget(covariant _ApiServerStatusLight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _syncPulseAnimation();
  }

  void _syncPulseAnimation() {
    final shouldPulse =
        !_disableAnimations &&
        (widget.state == _ApiServerVisualState.running || widget.state == _ApiServerVisualState.loading);
    if (shouldPulse) {
      if (!_pulseController.isAnimating) _pulseController.repeat(reverse: true);
      return;
    }
    _pulseController
      ..stop()
      ..value = switch (widget.state) {
        _ApiServerVisualState.running => 0.55,
        _ApiServerVisualState.loading => 0.3,
        _ApiServerVisualState.failed => 0.5,
        _ApiServerVisualState.stopped => 0,
      };
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = switch (widget.state) {
      _ApiServerVisualState.running => palette.success,
      _ApiServerVisualState.failed => palette.error,
      _ApiServerVisualState.loading || _ApiServerVisualState.stopped => palette.textMuted,
    };
    final labelColor = widget.state == _ApiServerVisualState.stopped ? palette.textSecondary : color;
    return Semantics(
      label: widget.label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              final pulse = Curves.easeInOut.transform(_pulseController.value);
              final glowSize = switch (widget.state) {
                _ApiServerVisualState.running => 12.0 + pulse * 8,
                _ApiServerVisualState.loading => 10.0 + pulse * 5,
                _ApiServerVisualState.failed => 16.0,
                _ApiServerVisualState.stopped => 10.0,
              };
              final glowAlpha = switch (widget.state) {
                _ApiServerVisualState.running => 0.08 + pulse * 0.12,
                _ApiServerVisualState.loading => 0.05 + pulse * 0.06,
                _ApiServerVisualState.failed => 0.13,
                _ApiServerVisualState.stopped => 0.08,
              };
              final glowShadow = switch (widget.state) {
                _ApiServerVisualState.running => [
                  BoxShadow(
                    color: color.withValues(alpha: 0.18 + pulse * 0.2),
                    blurRadius: 4 + pulse * 8,
                    spreadRadius: pulse * 1.5,
                  ),
                ],
                _ApiServerVisualState.failed => [
                  BoxShadow(color: color.withValues(alpha: 0.28), blurRadius: 7, spreadRadius: 0.5),
                ],
                _ApiServerVisualState.loading || _ApiServerVisualState.stopped => const <BoxShadow>[],
              };
              return SizedBox.square(
                dimension: 24,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      key: const ValueKey('api-server-status-glow'),
                      width: glowSize,
                      height: glowSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color.withValues(alpha: glowAlpha),
                        boxShadow: glowShadow,
                      ),
                    ),
                    child!,
                  ],
                ),
              );
            },
            child: AnimatedContainer(
              key: const ValueKey('api-server-status-dot'),
              duration: const Duration(milliseconds: 300),
              width: widget.state == _ApiServerVisualState.loading ? 6 : 8,
              height: widget.state == _ApiServerVisualState.loading ? 6 : 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.state == _ApiServerVisualState.stopped ? color.withValues(alpha: 0.72) : color,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            widget.label,
            style: TextStyle(color: labelColor, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    // iOS 液态玻璃分组卡片：模糊背板 + 竖向染色 + 高光 + 发丝描边。
    return SkiaLiquidGlass(
      radius: 14,
      blurSigma: 20,
      padding: EdgeInsets.zero,
      outlineColor: palette.border,
      outlineWidth: 1,
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        itemCount: children.length,
        separatorBuilder: (_, _) =>
            Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 12), color: palette.border),
        itemBuilder: (context, index) => children[index],
      ),
    );
  }
}

class _SettingsSectionStack extends StatelessWidget {
  const _SettingsSectionStack({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0) const SizedBox(height: 18),
          children[index],
        ],
      ],
    );
  }
}

class _SettingsBlock extends StatelessWidget {
  const _SettingsBlock({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
            title,
            style: TextStyle(color: palette.textSecondary, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
        child,
      ],
    );
  }
}

class _TextSettingControl extends StatelessWidget {
  const _TextSettingControl({
    required this.controller,
    this.fieldKey,
    this.hintText,
    this.minLines = 1,
    this.obscureText = false,
  });

  final TextEditingController controller;
  final Key? fieldKey;
  final String? hintText;
  final int minLines;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= Breakpoints.mobile;
    return SizedBox(
      width: desktop ? AppDesignTokens.settingsFormControlWidth : double.infinity,
      child: AppTextField(
        key: fieldKey,
        controller: controller,
        hintText: hintText,
        keyboardType: minLines > 1 ? TextInputType.multiline : null,
        obscureText: obscureText,
        minLines: minLines,
        maxLines: minLines == 1 ? 1 : minLines,
      ),
    );
  }
}

class _NumberSettingControl extends StatelessWidget {
  const _NumberSettingControl({
    required this.controller,
    required this.min,
    this.fieldKey,
    this.max,
    this.step = 1,
    this.decimalPlaces = 0,
  });

  final TextEditingController controller;
  final num min;
  final Key? fieldKey;
  final num? max;
  final double step;
  final int decimalPlaces;

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= Breakpoints.mobile;
    return SizedBox(
      width: desktop ? AppDesignTokens.settingsNumberControlWidth : double.infinity,
      child: AppNumberInput(
        fieldKey: fieldKey,
        controller: controller,
        min: min,
        max: max,
        step: step,
        decimalPlaces: decimalPlaces,
      ),
    );
  }
}

class _HostPortControl extends StatelessWidget {
  const _HostPortControl({
    required this.hostController,
    required this.portController,
    required this.hostKey,
    required this.portKey,
    this.enabled = true,
  });

  final TextEditingController hostController;
  final TextEditingController portController;
  final Key hostKey;
  final Key portKey;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= Breakpoints.mobile;
    return SizedBox(
      width: desktop ? AppDesignTokens.settingsFormControlWidth : double.infinity,
      child: Row(
        children: [
          Expanded(
            child: AppTextField(
              key: hostKey,
              controller: hostController,
              hintText: context.l10n.server,
              enabled: enabled,
            ),
          ),
          const SizedBox(width: AppDesignTokens.space8),
          SizedBox(
            width: AppDesignTokens.settingsNumberControlWidth,
            child: AppNumberInput(
              fieldKey: portKey,
              controller: portController,
              min: 0,
              max: 65535,
              step: 1,
              decimalPlaces: 0,
              hintText: context.l10n.port,
              enabled: enabled,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExternalTextLink extends StatefulWidget {
  const _ExternalTextLink({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  State<_ExternalTextLink> createState() => _ExternalTextLinkState();
}

class _ExternalTextLinkState extends State<_ExternalTextLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = _hovered ? palette.brandProgress : palette.brand;
    return Semantics(
      link: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      decoration: TextDecoration.underline,
                      decorationColor: color,
                      decorationThickness: _hovered ? 1.5 : 1,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Icon(Icons.open_in_new, size: 13, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BrowserExtensionLinks extends StatelessWidget {
  const _BrowserExtensionLinks({required this.onOpen});

  static final _links = <({String label, Uri uri})>[
    (
      label: 'Chrome',
      uri: Uri.parse('https://chromewebstore.google.com/detail/gopeed/mijpgljlfcapndmchhjffkpckknofcnd'),
    ),
    (
      label: 'Edge',
      uri: Uri.parse('https://microsoftedge.microsoft.com/addons/detail/dkajnckekendchdleoaenoophcobooce'),
    ),
    (label: 'Firefox', uri: Uri.parse('https://addons.mozilla.org/firefox/addon/gopeed-extension/')),
  ];

  final ValueChanged<Uri> onOpen;

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= Breakpoints.mobile;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: desktop ? WrapAlignment.end : WrapAlignment.start,
      children: [
        for (final link in _links)
          shad.SecondaryButton(
            key: ValueKey('browser-extension-${link.label.toLowerCase()}'),
            onPressed: () => onOpen(link.uri),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.open_in_new, size: 15),
                const SizedBox(width: AppDesignTokens.space8),
                Flexible(child: Text(link.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
      ],
    );
  }
}

class _UpdateActionControl extends ConsumerWidget {
  const _UpdateActionControl({required this.platform});

  final AppPlatformState? platform;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = platform?.updateStatus ?? AppUpdateStatus.idle;
    final latest = platform?.latestVersion;
    final checking = status == AppUpdateStatus.checking;

    Future<void> handlePressed() async {
      var nextVersion = latest;
      if (status != AppUpdateStatus.available || nextVersion == null) {
        nextVersion = await ref.read(appPlatformControllerProvider.notifier).checkForUpdate();
      }
      if (!context.mounted || nextVersion == null) return;
      await showAppUpdateDialog(
        context,
        versionInfo: nextVersion,
        onUpdate: ref.read(appPlatformControllerProvider.notifier).startUpdate,
      );
    }

    return _UpdateActionButton(
      available: status == AppUpdateStatus.available,
      checking: checking,
      onPressed: () => unawaited(handlePressed()),
    );
  }
}

class _UpdateActionButton extends StatelessWidget {
  const _UpdateActionButton({required this.available, required this.checking, required this.onPressed});

  final bool available;
  final bool checking;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return AppLoadingButton(
      key: const ValueKey('check-app-update-button'),
      onPressed: onPressed,
      loading: checking,
      icon: Icon(available ? Icons.system_update_alt_outlined : Icons.refresh, size: 17),
      variant: available ? AppLoadingButtonVariant.brand : AppLoadingButtonVariant.secondary,
      child: Text(available ? context.l10n.updateVersion : context.l10n.checkForUpdates),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.settings_outlined, size: 32, color: palette.error),
            const SizedBox(height: 12),
            Text(
              context.l10n.unableLoadSettings,
              style: TextStyle(color: palette.textPrimary, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.textSecondary),
            ),
            const SizedBox(height: 16),
            shad.SecondaryButton(onPressed: onRetry, child: Text(context.l10n.retry)),
          ],
        ),
      ),
    );
  }
}

/// The highest number of parallel FTP logins offered, the same limit as on the create task page. FTP servers
/// usually allow only a few logins per user.
const _ftpMaxConnections = 32;
