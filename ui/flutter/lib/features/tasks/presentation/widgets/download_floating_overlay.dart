import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:flutter/material.dart' as material;

import '../../../../app/application/app_runtime_controller.dart';
import '../../../../features/tasks/application/task_list_navigation.dart';
import '../../../../features/tasks/application/tasks_controller.dart';
import '../../../../shared/theme/app_palette.dart';
import '../../domain/task_record.dart';

/// 应用内下载浮窗（液态玻璃）。
///
/// 按用户要求重做：
/// * **默认折叠**，折叠态只显示【文件名 + 大小 + 取消 + 下载】。
/// * 可展开：展开后才出现进度条与速度，用户不需要就不展开。
/// * **居中**：小尺寸对话框（宽 300，圆角 22），不铺满。
/// * **底部**：高度取屏幕 2/5，内容贴顶，同样默认折叠。
class DownloadFloatingOverlay extends ConsumerStatefulWidget {
  const DownloadFloatingOverlay({super.key});

  /// 折叠态高度（对话框形态）。
  static const double barHeight = 74;

  /// 底部形态占屏比例。
  static const double bottomRatio = 2 / 5;

  static double reservedBottom(BuildContext context) =>
      barHeight + MediaQuery.paddingOf(context).bottom + 84;

  @override
  ConsumerState<DownloadFloatingOverlay> createState() => _DownloadFloatingOverlayState();
}

class _DownloadFloatingOverlayState extends ConsumerState<DownloadFloatingOverlay> {
  bool _expanded = false;

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

  static String _humanSize(int bytes) {
    if (bytes <= 0) return '未知大小';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final runtime = ref.watch(appRuntimeControllerProvider).value;
    final extra = runtime?.downloaderConfig.extra;

    // 无界面模式绝不能叠任何 App 内浮窗（用户反馈「静默还弹窗」）。
    final wantOverlay = extra == null ? true : (!extra.silentHeadless && extra.showsInAppProgress);
    if (!wantOverlay) return const SizedBox.shrink();

    final state = ref.watch(tasksControllerProvider).value;
    if (state == null) return const SizedBox.shrink();

    final active = state.tasks
        .where((task) => !task.isGroup && task.status == TaskStatus.downloading)
        .toList(growable: false);
    if (active.isEmpty) return const SizedBox.shrink();

    final task = active.first;
    final isBottom = extra?.dialogPopsFromBottom ?? false;
    final media = MediaQuery.of(context);

    final card = prism.LiquidGlass(
      style: _style(context),
      borderRadius: BorderRadius.circular(isBottom ? 20 : 22),
      shadows: [
        BoxShadow(
          color: const Color(0xFF000000).withValues(alpha: 0.18),
          blurRadius: 22,
          offset: const Offset(0, 8),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---- 折叠态第一行：文件名 + 取消 + 下载 ----
            Row(
              children: [
                Icon(Icons.downloading_rounded, size: 15, color: palette.brand),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    active.length > 1 ? '${task.name} 等 ${active.length} 项' : task.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: palette.textPrimary,
                    ),
                  ),
                ),
                _btn(palette.textMuted, Icons.close_rounded, '取消',
                    () => ref.read(tasksControllerProvider.notifier).deleteSelected([task.id], force: true)),
                _btn(palette.brand, Icons.file_download_outlined, '下载', () {
                  ref.read(taskListNavigationProvider.notifier).showDownloading();
                  GoRouter.of(context).go('/');
                }),
              ],
            ),
            const SizedBox(height: 6),
            // ---- 折叠态第二行：大小 + 展开箭头 ----
            Row(
              children: [
                Text(
                  task.total ??
                      (task.totalBytes != null && task.totalBytes! > 0
                          ? _humanSize(task.totalBytes!)
                          : '未知大小'),
                  style: TextStyle(fontSize: 11, color: palette.textMuted),
                ),
                const Spacer(),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Icon(
                      _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                      size: 16,
                      color: palette.textMuted,
                    ),
                  ),
                ),
              ],
            ),
            // ---- 展开区：进度 + 速度 ----
            if (_expanded) ...[
              const SizedBox(height: 4),
              material.ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: material.LinearProgressIndicator(
                  value: ((task.progress ?? 0).clamp(0.0, 1.0)).toDouble(),
                  minHeight: 4,
                  backgroundColor: palette.border,
                  valueColor: material.AlwaysStoppedAnimation<Color>(palette.brand),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '${((task.progress ?? 0) * 100).toStringAsFixed(1)}%  ·  '
                '已下载 ${_humanSize(task.downloadedBytes ?? 0)}',
                style: TextStyle(fontSize: 10.5, color: palette.textMuted),
              ),
            ],
          ],
        ),
      ),
    );

    if (isBottom) {
      // 底部：占屏幕高度 2/5，内容贴顶，默认折叠。
      return Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.fromLTRB(14, 0, 14, media.padding.bottom + 8),
          child: SizedBox(
            width: double.infinity,
            height: media.size.height * DownloadFloatingOverlay.bottomRatio,
            child: Align(alignment: Alignment.topCenter, child: card),
          ),
        ),
      );
    }

    // 居中：小尺寸对话框，不铺满屏幕。
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: card,
      ),
    );
  }

  Widget _btn(Color color, IconData icon, String tip, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
        child: Icon(icon, size: 17, color: color),
      ),
    );
  }
}
