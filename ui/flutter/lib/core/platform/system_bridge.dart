import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../util/util.dart';

final systemBridgeProvider = Provider<SystemBridge>((ref) => SystemBridge());

/// 应用安装形态诊断结果（来自原生真实读取，不是猜测）。
class AppInstallInfo {
  const AppInstallInfo({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.sourceDir,
    required this.dataDir,
    required this.isSystemApp,
    required this.isRooted,
    required this.sdkInt,
  });

  final String packageName;
  final String versionName;
  final int versionCode;
  final String sourceDir;
  final String dataDir;
  final bool isSystemApp;
  final bool isRooted;
  final int sdkInt;

  factory AppInstallInfo.fromMap(Map<Object?, Object?> m) => AppInstallInfo(
    packageName: (m['packageName'] as String?) ?? '',
    versionName: (m['versionName'] as String?) ?? '',
    versionCode: (m['versionCode'] as num?)?.toInt() ?? 0,
    sourceDir: (m['sourceDir'] as String?) ?? '',
    dataDir: (m['dataDir'] as String?) ?? '',
    isSystemApp: (m['isSystemApp'] as bool?) ?? false,
    isRooted: (m['isRooted'] as bool?) ?? false,
    sdkInt: (m['sdkInt'] as num?)?.toInt() ?? 0,
  );
}

/// root 执行结果，退出码与输出都来自真实进程。
class RootExecResult {
  const RootExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  factory RootExecResult.fromMap(Map<Object?, Object?> m) => RootExecResult(
    exitCode: (m['exitCode'] as num?)?.toInt() ?? -1,
    stdout: (m['stdout'] as String?) ?? '',
    stderr: (m['stderr'] as String?) ?? '',
  );
}

/// Android 系统能力桥（对应原生 SystemBridge.kt）。
///
/// 非 Android 平台一律返回明确的“不支持”，调用方据此隐藏或降级，
/// 绝不假装成功。
class SystemBridge {
  static const MethodChannel _channel = MethodChannel('gopeed.com/system');

  bool get isSupported => Util.isAndroid();

  Future<bool> isSystemApp() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('isSystemApp') ?? false;
    } on PlatformException catch (e) {
      debugPrint('isSystemApp failed: ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> hideFromRecents(bool hide) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('hideFromRecents', {'hide': hide}) ?? false;
    } on PlatformException catch (e) {
      debugPrint('hideFromRecents failed: ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> moveTaskToBack() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('moveTaskToBack') ?? false;
    } on PlatformException catch (e) {
      debugPrint('moveTaskToBack failed: ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> hasRoot() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('hasRoot') ?? false;
    } on PlatformException catch (e) {
      debugPrint('hasRoot failed: ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<RootExecResult> rootExec(String cmd) async {
    if (!isSupported) {
      return const RootExecResult(exitCode: -1, stdout: '', stderr: '仅 Android 支持');
    }
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>('rootExec', {'cmd': cmd});
      return RootExecResult.fromMap(r ?? const {});
    } on PlatformException catch (e) {
      return RootExecResult(exitCode: -1, stdout: '', stderr: e.message ?? '执行失败');
    } on MissingPluginException {
      return const RootExecResult(exitCode: -1, stdout: '', stderr: '原生通道缺失');
    }
  }

  Future<AppInstallInfo?> appInfo() async {
    if (!isSupported) return null;
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>('appInfo');
      return r == null ? null : AppInstallInfo.fromMap(r);
    } on PlatformException catch (e) {
      debugPrint('appInfo failed: ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> requestIgnoreBattery() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('requestIgnoreBattery') ?? false;
    } on PlatformException catch (e) {
      debugPrint('requestIgnoreBattery failed: ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  // ---------------- 系统级悬浮窗 ----------------

  /// 是否持有「显示在其他应用上层」权限。
  Future<bool> hasOverlayPermission() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('hasOverlayPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 跳系统设置页申请悬浮窗权限。
  Future<bool> requestOverlayPermission() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('requestOverlayPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 显示系统级悬浮窗（独立于 App 界面，退到后台也在）。
  Future<bool> showOverlay({required String url, required String name}) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('showOverlay', {
            'url': url,
            'name': name,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> hideOverlay() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('hideOverlay') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  // ---------------- 静默下载：同步给原生入口 ----------------

  /// 把静默模式同步给原生。原生 SilentGateActivity 靠它决定
  /// 是「完全不进 App」还是「进任务列表」。
  Future<void> setSilentMode(String mode) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<bool>('setSilentMode', {'mode': mode});
    } on PlatformException {
      // 老版本原生没有该通道，忽略。
    } on MissingPluginException {
      // 同上。
    }
  }

  /// 悬浮窗开关同步给原生，静默下载时据此决定弹窗还是只发通知。
  Future<void> setOverlayEnabled(bool enabled) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<bool>('setOverlayEnabled', {'enabled': enabled});
    } on PlatformException {
      // ignore
    } on MissingPluginException {
      // ignore
    }
  }

  /// 退出时最小化：原生记录后，返回键/关闭行为改为退后台而不结束进程。
  Future<void> setMinimizeOnExit(bool enabled) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<bool>('setMinimizeOnExit', {'enabled': enabled});
    } on PlatformException {
      // ignore
    } on MissingPluginException {
      // ignore
    }
  }

  /// 开机自动运行：写开机广播开关，由原生侧落实。
  Future<void> setAutoStart(bool enabled) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<bool>('setAutoStart', {'enabled': enabled});
    } on PlatformException {
      // ignore
    } on MissingPluginException {
      // ignore
    }
  }

  /// 读取原生已保存的开关状态（用于启动时回填，避免界面与真实状态不一致）。
  Future<Map<String, bool>> readSystemPrefs() async {
    if (!isSupported) return const {};
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>('readSystemPrefs');
      if (r == null) return const {};
      return {
        for (final e in r.entries) '${e.key}': e.value == true,
      };
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  /// 把模块端口告诉原生，静默投递任务时直接打 127.0.0.1:port。
  Future<void> setModulePort(int port) async {
    if (!isSupported || port <= 0) return;
    try {
      await _channel.invokeMethod<int>('setModulePort', {'port': port});
    } on PlatformException {
      // ignore
    } on MissingPluginException {
      // ignore
    }
  }
}
