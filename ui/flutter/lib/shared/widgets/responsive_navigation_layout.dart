import 'package:flutter/material.dart' show Theme, Brightness;
import 'package:flutter/widgets.dart';

import '../../core/utils/breakpoints.dart';
import '../theme/app_palette.dart';
import 'secondary_navigation_pane.dart';
import 'app_swipe_tabs.dart';

class ResponsiveNavigationItem<T> {
  const ResponsiveNavigationItem({required this.value, required this.label, this.icon, this.count});

  final T value;
  final String label;
  final IconData? icon;
  final int? count;
}

class ResponsiveNavigationLayout<T> extends StatelessWidget {
  const ResponsiveNavigationLayout({
    super.key,
    required this.items,
    required this.selectedValue,
    required this.onSelected,
    required this.child,
    required this.desktopTitle,
    this.desktopFooter,
    this.mobileHeader,
    this.mobileBreakpoint = Breakpoints.mobile,
  });

  final List<ResponsiveNavigationItem<T>> items;
  final T selectedValue;
  final ValueChanged<T> onSelected;
  final Widget child;
  final String desktopTitle;
  final Widget? desktopFooter;
  final Widget? mobileHeader;
  final double mobileBreakpoint;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final mobile = width < mobileBreakpoint;
    if (!mobile) {
      return Row(
        children: [
          SecondaryNavigationPane<T>(
            title: desktopTitle,
            items: items
                .map(
                  (item) => SecondaryNavigationPaneItem<T>(
                    value: item.value,
                    label: item.label,
                    icon: item.icon,
                    trailing: item.count?.toString(),
                  ),
                )
                .toList(),
            selectedValue: selectedValue,
            onSelected: onSelected,
            footer: desktopFooter,
          ),
          Expanded(child: child),
        ],
      );
    }

    return Column(
      children: [
        ?mobileHeader,
        _MobileNavigationTabs<T>(
          items: items,
          selectedValue: selectedValue,
          onSelected: onSelected,
          reserveTopSafeArea: mobileHeader == null,
        ),
        Expanded(
          child: AppSwipeTabs<T>(
            values: items.map((item) => item.value).toList(growable: false),
            selectedValue: selectedValue,
            onSelected: onSelected,
            child: child,
          ),
        ),
      ],
    );
  }
}

/// 任务列表顶部的「下载中 / 已完成 / 失败」分段器。
///
/// 还原 beta.6 的形态：外层一整颗胶囊（描边 + 极浅底），
/// 选中项是嵌在内侧的白色胶囊（自身也带描边），未选中项纯文字。
class _MobileNavigationTabs<T> extends StatelessWidget {
  const _MobileNavigationTabs({
    required this.items,
    required this.selectedValue,
    required this.onSelected,
    required this.reserveTopSafeArea,
  });

  final List<ResponsiveNavigationItem<T>> items;
  final T selectedValue;
  final ValueChanged<T> onSelected;
  final bool reserveTopSafeArea;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const pill = BorderRadius.all(Radius.circular(999));

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: SafeArea(
        top: reserveTopSafeArea,
        bottom: false,
        // beta.6：整条胶囊铺满左右（左右留 16），三项等分，不滚动。
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: isDark ? palette.surfaceSoft : const Color(0xFFF7F8FA),
              borderRadius: pill,
              // 用户指定：这一栏要黑色线包边（iOS 液态玻璃的分段器就是深色描边）
              border: Border.all(
                color: isDark ? const Color(0xFFEDF1F5).withValues(alpha: 0.62) : const Color(0xFF11161D),
                width: 1.6,
              ),
            ),
            child: Row(
              children: [
                for (final item in items)
                  Expanded(
                    child: _MobileNavigationTab<T>(
                      item: item,
                      active: item.value == selectedValue,
                      onTap: () => onSelected(item.value),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileNavigationTab<T> extends StatelessWidget {
  const _MobileNavigationTab({required this.item, required this.active, required this.onTap});

  final ResponsiveNavigationItem<T> item;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = item.count == null ? item.label : '${item.label} · ${item.count}';
    const pill = BorderRadius.all(Radius.circular(999));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? (isDark ? palette.cardBg : const Color(0xFFFFFFFF))
              : const Color(0x00000000),
          borderRadius: pill,
          border: active
              ? Border.all(
                  color: isDark ? const Color(0xFFEDF1F5).withValues(alpha: 0.55) : const Color(0xFF11161D),
                  width: 1.6,
                )
              : null,
          boxShadow: active
              ? [
                  BoxShadow(
                    color: const Color(0xFF101828).withValues(alpha: isDark ? 0.30 : 0.06),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: active ? palette.textPrimary : palette.textSecondary,
            fontSize: 13.5,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            letterSpacing: -0.01,
          ),
        ),
      ),
    );
  }
}
