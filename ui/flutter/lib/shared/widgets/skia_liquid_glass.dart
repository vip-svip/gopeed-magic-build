import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Skia 自绘的液态玻璃（Liquid Glass）。
///
/// 参考 chen08209/prism 的材质分层，但**完全不依赖任何 shader 资源**：
/// 所有效果由 Skia 的 saveLayer / 高斯模糊 / 渐变与路径绘制完成，
/// 因此在任何 Flutter 版本、任何设备上都能出图，也不会出现
/// shader 缺失导致的"整块变白/变灰"。
///
/// 绘制顺序（与 prism 的物理分层一致）：
/// 1. 先按圆角裁剪 —— 这是之前"整页被模糊"的根因：
///    BackdropFilter 若不被裁剪，会把整个屏幕的背板一起模糊。
/// 2. 背景高斯模糊（Skia ImageFilter.blur）。
/// 3. 玻璃染色：竖向渐变模拟玻璃厚度带来的明暗差。
/// 4. 斜向 rim light：左上亮、右下弱，模拟棱镜边缘的反光。
/// 5. 顶部镜面高光带 + 底部内侧阴影，做出曲面厚度。
class SkiaLiquidGlass extends StatelessWidget {
  const SkiaLiquidGlass({
    super.key,
    required this.child,
    this.radius = 28,
    this.blurSigma = 16,
    this.tintColor,
    this.shadows = const <BoxShadow>[],
    this.padding = EdgeInsets.zero,
    this.rimStrength = 1.0,
    this.showSpecular = true,
  });

  final Widget child;
  final double radius;

  /// 背景模糊强度（Skia sigma）。
  final double blurSigma;

  /// 玻璃染色的基色；不传则按主题自动选冷调。
  final Color? tintColor;

  final List<BoxShadow> shadows;
  final EdgeInsets padding;

  /// 边缘反光强度倍率。
  final double rimStrength;

  /// 是否绘制顶部镜面高光。
  final bool showSpecular;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final br = BorderRadius.all(Radius.circular(radius));
    final tint = tintColor ?? (isDark ? const Color(0xFF1E242C) : const Color(0xFFF1F4F9));

    // 玻璃本体：裁剪 → 模糊 → 染色。
    Widget glass = ClipRRect(
      borderRadius: br,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: blurSigma,
          sigmaY: blurSigma,
          tileMode: TileMode.clamp,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: br,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                tint.withValues(alpha: isDark ? 0.74 : 0.86),
                tint.withValues(alpha: isDark ? 0.54 : 0.64),
              ],
            ),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );

    // 高光与边缘：画在玻璃之上。
    glass = CustomPaint(
      foregroundPainter: _GlassEdgePainter(
        borderRadius: br,
        isDark: isDark,
        rimStrength: rimStrength,
        showSpecular: showSpecular,
      ),
      child: glass,
    );

    if (shadows.isNotEmpty) {
      glass = DecoratedBox(
        decoration: BoxDecoration(borderRadius: br, boxShadow: shadows),
        child: glass,
      );
    }
    return glass;
  }
}

class _GlassEdgePainter extends CustomPainter {
  const _GlassEdgePainter({
    required this.borderRadius,
    required this.isDark,
    required this.rimStrength,
    required this.showSpecular,
  });

  final BorderRadius borderRadius;
  final bool isDark;
  final double rimStrength;
  final bool showSpecular;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final rrect = borderRadius.toRRect(rect);

    canvas.save();
    canvas.clipRRect(rrect);

    // 顶部镜面高光带（曲面受光）。
    if (showSpecular) {
      final hlRect = Rect.fromLTWH(0, 0, size.width, size.height * 0.46);
      canvas.drawRect(
        hlRect,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(0, 0),
            Offset(0, hlRect.height),
            [
              Colors.white.withValues(alpha: isDark ? 0.17 : 0.52),
              Colors.white.withValues(alpha: 0.0),
            ],
          ),
      );
    }

    // 底部内阴影（玻璃厚度）。
    final botRect = Rect.fromLTWH(0, size.height * 0.58, size.width, size.height * 0.42);
    canvas.drawRect(
      botRect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, botRect.top),
          Offset(0, size.height),
          [
            const Color(0x00000000),
            const Color(0xFF0B1A2B).withValues(alpha: isDark ? 0.26 : 0.11),
          ],
        ),
    );

    canvas.restore();

    // 斜向 rim light：左上强、右下弱。
    canvas.drawRRect(
      rrect.deflate(0.7),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = ui.Gradient.linear(
          rect.topLeft,
          rect.bottomRight,
          [
            Colors.white.withValues(alpha: (isDark ? 0.42 : 0.95) * rimStrength),
            Colors.white.withValues(alpha: 0.0),
            Colors.white.withValues(alpha: (isDark ? 0.10 : 0.28) * rimStrength),
          ],
          [0.0, 0.55, 1.0],
        ),
    );

    // 外圈极细描边，让玻璃与背景分离。
    canvas.drawRRect(
      rrect.deflate(0.35),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = (isDark ? Colors.white : const Color(0xFF8E9AA8)).withValues(alpha: isDark ? 0.10 : 0.16),
    );
  }

  @override
  bool shouldRepaint(_GlassEdgePainter old) =>
      old.isDark != isDark ||
      old.rimStrength != rimStrength ||
      old.showSpecular != showSpecular ||
      old.borderRadius != borderRadius;
}
