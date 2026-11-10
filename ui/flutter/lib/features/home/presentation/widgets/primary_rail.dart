import 'package:go_router/go_router.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart';

import '../../../../core/window/app_window_chrome.dart';
import '../../../../shared/theme/app_design_tokens.dart';
import '../../../../shared/theme/app_palette.dart';
import '../../../../shared/widgets/app_tooltip.dart';
import '../../../../shared/widgets/gopeed_app_mark.dart';
import '../../../../shared/widgets/skia_liquid_glass.dart';
import '../../../../l10n/l10n.dart';

enum RailSection { tasks, extensions, settings }

/// prism_ui 的液态玻璃染色。
///
/// 玻璃本身靠 shader 做折射，但纯白 tint 在浅色页面上会失去材质感，
/// 所以浅色用偏冷灰蓝、深色用石板灰，并把 rim/hairline 保留成镜面高光边。
prism.LiquidGlassStyle _glassStyle(BuildContext context, {bool pill = true}) {
  final palette = AppPalette.of(context);
  final scheme = prism.ColorScheme.fromSeed(
    seedColor: palette.brand,
    brightness: material.Theme.of(context).brightness,
  );
  final isDark = scheme.brightness == Brightness.dark;
  final base = pill ? prism.LiquidGlassStyle.pill(scheme) : prism.LiquidGlassStyle.regular(scheme);
  return prism.LiquidGlassStyle(
    tint: isDark
        ? const Color(0x9920262E)
        : Color(pill ? 0x93E7EDF5 : 0x8FF2F5F9),
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

/// 桌面端左侧栏：整块 prism 液态玻璃面板，浮在内容之上。
class PrimaryRail extends StatelessWidget {
  const PrimaryRail({super.key, this.activeSection = RailSection.tasks});

  final RailSection activeSection;

  @override
  Widget build(BuildContext context) {
    final isDark = material.Theme.of(context).brightness == Brightness.dark;
    final topInset = AppWindowChrome.reservesHeaderInset ? AppDesignTokens.windowHeaderHeight : 0.0;

    return SizedBox(
      width: AppDesignTokens.railWidth,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: prism.LiquidGlass(
          style: _glassStyle(context, pill: false),
          borderRadius: const BorderRadius.all(Radius.circular(22)),
          shadows: [
            BoxShadow(
              color: (isDark ? const Color(0xFF000000) : const Color(0xFF64748B)).withValues(alpha: isDark ? 0.42 : 0.16),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
          child: Padding(
            padding: EdgeInsets.only(top: topInset + 6, bottom: 10),
            child: Column(
              children: [
                SizedBox(
                  height: AppDesignTokens.contentHeaderHeight,
                  child: Center(
                    child: AppTooltip(
                      message: context.l10n.task,
                      child: Semantics(
                        label: context.l10n.task,
                        button: true,
                        child: GhostButton(
                          key: const ValueKey('primary-rail-home-button'),
                          density: ButtonDensity.icon,
                          onPressed: () => context.go('/'),
                          child: const ExcludeSemantics(child: GopeedAppMark(key: ValueKey('primary-rail-app-mark'))),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppDesignTokens.space8),
                _RailItem(
                  key: const ValueKey('primary-rail-tasks-item'),
                  icon: Icons.download_rounded,
                  label: context.l10n.task,
                  active: activeSection == RailSection.tasks,
                  onTap: () => context.go('/'),
                ),
                const SizedBox(height: 18),
                _RailItem(
                  icon: Icons.extension_outlined,
                  label: context.l10n.extensions,
                  active: activeSection == RailSection.extensions,
                  onTap: () => context.go('/extensions'),
                ),
                const SizedBox(height: 18),
                _RailItem(
                  icon: Icons.settings_outlined,
                  label: context.l10n.setting,
                  active: activeSection == RailSection.settings,
                  onTap: () => context.go('/settings'),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({super.key, required this.icon, required this.label, required this.onTap, this.active = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final isDark = material.Theme.of(context).brightness == Brightness.dark;
    final iconColor = active ? palette.textPrimary : palette.textMuted;

    return AppTooltip(
      message: label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              height: 34,
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                color: active
                    ? const Color(0xFFFFFFFF).withValues(alpha: isDark ? 0.16 : 0.92)
                    : const Color(0x00000000),
                border: active
                    ? Border.all(color: const Color(0xFFFFFFFF).withValues(alpha: isDark ? 0.22 : 1), width: 1)
                    : null,
              ),
              child: Center(child: Icon(icon, size: 18, color: iconColor)),
            ),
          ),
        ),
      ),
    );
  }
}

/// 移动端底部 Tab：Skia 自绘的液态玻璃胶囊。
///
/// 与旧实现的关键差别：
/// 1. 玻璃由 Skia 直接绘制（裁剪 → 模糊 → 染色 → rim light → 镜面高光），
///    不依赖任何 shader 资源，因此不会出现"玻璃画不出来只剩一块白底"。
/// 2. 移植 prism 的选中态：一条会滑动的白色高亮胶囊，而不是原地淡入淡出。
/// 3. 移植 prism 的点击手感：按下缩放 + 图标下压 + 回弹曲线 + 触感反馈。
class PrimaryBottomNavigation extends StatelessWidget {
  const PrimaryBottomNavigation({super.key, this.activeSection = RailSection.tasks});

  final RailSection activeSection;

  /// 玻璃胶囊自身高度（不含安全区与悬浮外边距）。
  static const double barHeight = 64;

  /// 内容需要额外让出的底部空间。
  static double reservedHeight(BuildContext context) => barHeight + MediaQuery.paddingOf(context).bottom + 26;

  static const List<RailSection> _order = [
    RailSection.tasks,
    RailSection.extensions,
    RailSection.settings,
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = material.Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final index = _order.indexOf(activeSection).clamp(0, _order.length - 1);

    final items = <_NavSpec>[
      _NavSpec(Icons.download_rounded, context.l10n.task, () => context.go('/')),
      _NavSpec(Icons.extension_outlined, context.l10n.extensions, () => context.go('/extensions')),
      _NavSpec(Icons.settings_outlined, context.l10n.setting, () => context.go('/settings')),
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, bottomInset + 10),
      child: SkiaLiquidGlass(
        radius: 30,
        blurSigma: 18,
        rimStrength: 1.0,
        tintColor: isDark ? const Color(0xFF1C232B) : const Color(0xFFEFF3F9),
        shadows: [
          BoxShadow(
            color: (isDark ? const Color(0xFF000000) : const Color(0xFF4B5A6B)).withValues(alpha: isDark ? 0.45 : 0.20),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
        child: SizedBox(
          height: barHeight,
          child: _SlidingTabRow(
            items: items,
            selectedIndex: index,
            // 选中胶囊的内边距，滑动指示器按它计算宽度与位移。
            innerPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          ),
        ),
      ),
    );
  }
}

class _NavSpec {
  const _NavSpec(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// 等分三格 + 会滑动的选中胶囊。
class _SlidingTabRow extends StatelessWidget {
  const _SlidingTabRow({
    required this.items,
    required this.selectedIndex,
    required this.innerPadding,
  });

  final List<_NavSpec> items;
  final int selectedIndex;
  final EdgeInsets innerPadding;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final isDark = material.Theme.of(context).brightness == Brightness.dark;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - innerPadding.horizontal;
        final height = constraints.maxHeight - innerPadding.vertical;
        final slot = width / items.length;

        return Padding(
          padding: innerPadding,
          child: Stack(
            children: [
              // 滑动高亮胶囊：prism 的选中态是一条会移动的白色胶囊。
              AnimatedPositioned(
                duration: const Duration(milliseconds: 340),
                curve: Curves.easeOutBack,
                left: slot * selectedIndex,
                top: 0,
                width: slot,
                height: height,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.all(Radius.circular(22)),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: isDark
                            ? [
                                const Color(0xFFFFFFFF).withValues(alpha: 0.26),
                                const Color(0xFFFFFFFF).withValues(alpha: 0.10),
                              ]
                            : [
                                const Color(0xFFFFFFFF),
                                const Color(0xFFFFFFFF).withValues(alpha: 0.82),
                              ],
                      ),
                      border: Border.all(
                        color: const Color(0xFFFFFFFF).withValues(alpha: isDark ? 0.32 : 1),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: palette.brand.withValues(alpha: isDark ? 0.30 : 0.18),
                          blurRadius: 12,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: _BottomNavItem(
                        icon: items[i].icon,
                        label: items[i].label,
                        active: i == selectedIndex,
                        onTap: items[i].onTap,
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 让滚动内容延伸到玻璃条下方（否则玻璃没有内容可折射）。
class BottomNavInset extends StatelessWidget {
  const BottomNavInset({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final extra = PrimaryBottomNavigation.reservedHeight(context);
    return MediaQuery(
      data: mq.copyWith(
        padding: mq.padding.copyWith(bottom: mq.padding.bottom + extra),
        viewPadding: mq.viewPadding.copyWith(bottom: mq.viewPadding.bottom + extra),
      ),
      child: child,
    );
  }
}

class _BottomNavItem extends StatefulWidget {
  const _BottomNavItem({required this.icon, required this.label, required this.onTap, this.active = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  State<_BottomNavItem> createState() => _BottomNavItemState();
}

/// 底部 Tab 项：移植 prism 的按压手感。
///
/// - 按下：整项缩到 0.92，图标再往下压一点，像真的被手指按住
/// - 松手：easeOutBack 弹回，略微过冲后回位
/// - 切换：图标与文字用 easeOutBack 过渡，选中图标上浮并放大
/// - 触感：selectionClick，和 prism 的 Tab 一致
class _BottomNavItemState extends State<_BottomNavItem> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final isDark = material.Theme.of(context).brightness == Brightness.dark;
    final idle = isDark ? palette.textMuted : const Color(0xFF5C6976);
    final active = widget.active;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: () {
          HapticFeedback.selectionClick();
          widget.onTap();
        },
        child: AnimatedScale(
          duration: Duration(milliseconds: _pressed ? 90 : 280),
          curve: _pressed ? Curves.easeOut : Curves.easeOutBack,
          scale: _pressed ? 0.92 : 1.0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedSlide(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutBack,
                offset: Offset(0, active ? -0.06 : 0),
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutBack,
                  scale: _pressed ? 0.88 : (active ? 1.1 : 1.0),
                  child: Icon(widget.icon, size: 20, color: active ? palette.brand : idle),
                ),
              ),
              const SizedBox(height: 3),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 220),
                style: TextStyle(
                  color: active ? palette.brand : idle,
                  fontSize: 10.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
                child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
