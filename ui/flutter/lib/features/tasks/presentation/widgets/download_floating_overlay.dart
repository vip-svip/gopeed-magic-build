import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:flutter/material.dart' as material;

import '../../../../app/application/app_runtime_controller.dart';
import '../../../../features/tasks/application/task_list_navigation.dart';
import '../../../../features/tasks/application/tasks_controller.dart';
import '../../../../shared/theme/app_palette.dart';
import '../../../../shared/widgets/app_tooltip.dart';
import '../../domain/task_record.dart';

/// 应用内下载浮窗。
///
/// 按用户要求做的极简形态：
/// * **只有一行**，高度 40，不折叠不展开，没有进度条、没有速度、没有百分比。
/// * 只显示【文件名】+【取消】+【下载】三个元素。
/// * 左右 edge-to-edge 贴边铺满，不是居中小方块。
/// * 材质用 prism_ui 液态玻璃，真实折射下方列表。
class DownloadFloatingOverlay extends ConsumerWidget {
  const DownloadFloatingOverlay({super.key});

  /// 浮窗自身高度。
  static const double barHeight = 40;

  /// 浮窗需要让出的底部空间（含底栏 + 安全区 + 间距）。
  static double reservedBottom(BuildContext context) =>
      barHeight + MediaQuery.paddingOf(context).bottom + 84;

  prism.LiquidGlassStyle _style(BuildContext context) {
    final palette = AppPalette.of(context);
    final scheme = prism.ColorScheme.fromSeed(
      seedColor: palette.brand,
      brightness: material.Theme.of(context).brightness,
    );
    final isDark = material.Theme.of(context).brightness == Brightness.dark;
    final base = prism.LiquidGlassStyle.regular(scheme);
    return prism.LiquidGlassStyle(
      tint: isDark ? const Color(0x9920262E) : const Color(0x93E7EDF5),
      contrast: base.contrast,
      blur: base.blur,
      haze: base.haze,
      hazeBlur: base.hazeBlur,
      refraction: base.refraction,
      bevel: base.bevel,
      saturation: base.saturation,
      brightness: base.brightness,
      rim: base.rim,
      rimWidth: base.rimWidth,
      rimTail: base.rimTail,
      rimFocus: base.rimFocus,
      rimAdded: base.rimAdded,
      hairline: base.hairline,
      hairlineSide: base.hairlineSide,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);

    final runtime = ref.watch(appRuntimeControllerProvider).value;
    final extra = runtime?.downloaderConfig.extra;
    // 无界面模式只发系统通知，绝不能再叠一个 App 内浮窗（用户反馈"静默还弹窗"）。
    // 放在 App 内的浮窗只在用户明确选择了浮窗样式时出现。
    final wantOverlay = extra == null
        ? true
        : (!extra.silentHeadless && extra.showsInAppProgress);
    if (!wantOverlay) return const SizedBox.shrink();

    final state = ref.watch(tasksControllerProvider).value;
    if (state == null) return const SizedBox.shrink();

    final active = state.tasks
        .where((task) => !task.isGroup && task.status == TaskStatus.downloading)
        .toList(growable: false);
    if (active.isEmpty) return const SizedBox.shrink();

    final task = active.first;
    final more = active.length - 1;

    return Padding(
      padding: EdgeInsets.fromLTRB(10, 0, 10, reservedBottom(context) - 44),
      child: prism.LiquidGlass(
        style: _style(context),
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        shadows: [
          BoxShadow(
            color: const Color(0xFF000000).withValues(alpha: 0.14),
            blurRadius: 16,
            offset: const Offset(0, 5),
          ),
        ],
        child: SizedBox(
          height: barHeight,
          child: Row(
            children: [
              const SizedBox(width: 11),
              Icon(Icons.downloading_rounded, size: 15, color: palette.brand),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  more > 0 ? '${task.name} 等 ${active.length} 项' : task.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              _OverlayAction(
                icon: Icons.close_rounded,
                tooltip: '取消',
                color: palette.textMuted,
                onTap: () => ref.read(tasksControllerProvider.notifier).deleteSelected([task.id], force: true),
              ),
              _OverlayAction(
                icon: Icons.file_download_outlined,
                tooltip: '下载',
                color: palette.brand,
                onTap: () {
                  ref.read(taskListNavigationProvider.notifier).showDownloading();
                  GoRouter.of(context).go('/');
                },
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverlayAction extends StatelessWidget {
  const _OverlayAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AppTooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 9),
          child: Icon(icon, size: 17, color: color),
        ),
      ),
    );
  }
}
