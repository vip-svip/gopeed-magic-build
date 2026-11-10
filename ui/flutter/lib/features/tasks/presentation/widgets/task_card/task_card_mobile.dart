import 'package:flutter/material.dart' show Colors, Icons;
import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shad;

import '../../../../../core/window/app_window_chrome.dart';
import '../../../../../shared/theme/app_design_tokens.dart';
import '../../../../../shared/theme/app_palette.dart';
import '../../../domain/task_record.dart';
import '../task_progress_bar.dart';
import 'task_card_parts.dart';

class TaskCardMobile extends StatefulWidget {
  const TaskCardMobile({
    super.key,
    required this.task,
    this.expanded = false,
    required this.selected,
    required this.batchMode,
    required this.selectedInBatch,
    required this.onPressed,
    required this.onToggleBatch,
    this.onPause,
    this.onResume,
    this.onDelete,
    this.onOpen,
    this.onReveal,
    this.listeningForUpdate = false,
  });

  final TaskRecord task;
  final bool expanded;
  final bool selected;
  final bool batchMode;
  final bool selectedInBatch;
  final VoidCallback onPressed;
  final VoidCallback onToggleBatch;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onDelete;
  final VoidCallback? onOpen;
  final VoidCallback? onReveal;
  final bool listeningForUpdate;

  @override
  State<TaskCardMobile> createState() => _TaskCardMobileState();
}

class _TaskCardMobileState extends State<TaskCardMobile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final isDark = shad.Theme.of(context).brightness == Brightness.dark;
    final borderColor = isDark ? palette.border : palette.border.withValues(alpha: 0.6);
    final baseColor = isDark ? palette.cardBg : palette.cardBg.withValues(alpha: 0.92);
    final hoverColor = palette.taskCardHoverBg;
    final radius = BorderRadius.circular(AppDesignTokens.controlRadius);
    final task = widget.task;
    final fillColor = taskCardFillColor(palette, task.status, isDark);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        onDoubleTap: !widget.batchMode && !task.isGroup && task.status == TaskStatus.completed ? widget.onOpen : null,
        child: Container(
          key: const ValueKey('task-card-mobile-surface'),
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: widget.selected
                ? [BoxShadow(color: palette.taskCardSelectedBorder, blurRadius: 0, spreadRadius: 1)]
                : null,
          ),
          child: ClipRRect(
            borderRadius: radius,
            clipBehavior: Clip.hardEdge,
            child: Stack(
              children: [
                // 液态玻璃基底：半透明竖向染色，让极光背景透上来形成材质感。
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: isDark
                            ? const [Color(0x5CFFFFFF), Color(0x24FFFFFF)]
                            : const [Color(0xE6FFFFFF), Color(0xB8FFFFFF)],
                      ),
                    ),
                  ),
                ),
                if (_hovered)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ColoredBox(key: const ValueKey('task-card-hover-surface'), color: hoverColor),
                    ),
                  ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        border: Border.all(color: _hovered ? palette.border : borderColor),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          AnimatedSize(
                            duration: const Duration(milliseconds: 160),
                            curve: Curves.easeOutCubic,
                            child: widget.batchMode
                                ? Padding(
                                    padding: const EdgeInsets.only(right: AppDesignTokens.checkboxLabelGap),
                                    child: shad.Checkbox(
                                      state: widget.selectedInBatch
                                          ? shad.CheckboxState.checked
                                          : shad.CheckboxState.unchecked,
                                      onChanged: (_) => widget.onToggleBatch(),
                                      borderColor: palette.border,
                                      backgroundColor: palette.cardBg,
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                          TaskCardIcon(task: task, expanded: widget.expanded),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              task.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                height: 1.1,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (widget.listeningForUpdate) ...[
                            const TaskUpdateListeningIndicator(),
                            const SizedBox(width: 6),
                          ],
                          if (!widget.batchMode) ..._buildActionButtons(task, palette, isDark),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (task.status != TaskStatus.completed) ...[
                        TaskProgressBar(
                          value: task.progress,
                          indeterminate: task.isIndeterminate,
                          trackColor: palette.brandTrack,
                          fillColor: fillColor,
                          highlightStartColor: fillColor,
                          highlightEndColor: fillColor,
                          shimmer: task.status == TaskStatus.downloading && !task.waiting,
                        ),
                        const SizedBox(height: 6),
                        TaskCardFooter(task: task, isError: task.status == TaskStatus.failed),
                      ] else ...[
                        if (!task.isGroup && widget.onOpen != null) ...[
                          _CompletedTypeAction(task: task, onPressed: widget.onOpen!),
                          const SizedBox(height: 6),
                        ],
                        TaskCardCompletedMeta(task: task),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildActionButtons(TaskRecord task, AppPalette palette, bool isDark) {
    final actions = task.isGroup && task.status != TaskStatus.completed
        ? [
            if (task.canPause) (Icons.pause, widget.onPause),
            if (task.canResume) (Icons.play_arrow, widget.onResume),
            (Icons.close, widget.onDelete),
          ]
        : switch (task.status) {
            TaskStatus.downloading => [(Icons.pause, widget.onPause), (Icons.close, widget.onDelete)],
            TaskStatus.paused => [(Icons.play_arrow, widget.onResume), (Icons.close, widget.onDelete)],
            TaskStatus.failed => [(Icons.refresh, widget.onResume), (Icons.delete_outline, widget.onDelete)],
            TaskStatus.completed => [
              if (AppWindowChrome.isDesktopWindow) (Icons.folder_open_outlined, widget.onReveal),
              (Icons.delete_outline, widget.onDelete),
            ],
          };

    return actions
        .map(
          (action) => TaskCardActionButton(
            icon: action.$1,
            color: palette.taskCardAction,
            onPressed: action.$2 ?? () {},
            hoverBackground: isDark ? palette.border : Colors.transparent,
            buttonSize: 20,
            iconSize: 13,
          ),
        )
        .toList(growable: false);
  }
}

/// 已完成任务的“按类型自动识别”操作：安装包 -> 安装，压缩包 -> 解压，
/// 其余（txt/图片/视频等）-> 打开。依据文件名扩展名判定。
class _CompletedTypeAction extends StatelessWidget {
  const _CompletedTypeAction({required this.task, required this.onPressed});

  final TaskRecord task;
  final VoidCallback onPressed;

  static String _ext(String name) {
    final i = name.lastIndexOf('.');
    if (i < 0 || i == name.length - 1) return '';
    return name.substring(i + 1).toLowerCase();
  }

  static (IconData, String) _describe(String ext) {
    switch (ext) {
      case 'apk':
      case 'apks':
      case 'xapk':
      case 'apkm':
        return (Icons.android, '安装');
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
      case 'xz':
      case 'bz2':
        return (Icons.unarchive_outlined, '解压');
      case 'txt':
      case 'md':
      case 'log':
      case 'json':
      case 'xml':
      case 'csv':
        return (Icons.description_outlined, '打开');
      case 'pdf':
        return (Icons.picture_as_pdf_outlined, '打开');
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
        return (Icons.image_outlined, '查看');
      case 'mp4':
      case 'mkv':
      case 'avi':
      case 'mov':
      case 'ts':
      case 'm3u8':
        return (Icons.play_circle_outline, '播放');
      case 'exe':
      case 'msi':
        return (Icons.terminal, '打开');
      default:
        return (Icons.open_in_new, '打开');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final (icon, label) = _describe(_ext(task.name));
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        key: const ValueKey('task-card-type-action'),
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: palette.cardBg,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: palette.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: palette.textPrimary),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(color: palette.textPrimary, fontSize: 11, height: 1.1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
