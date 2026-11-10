import 'package:flutter/material.dart';

/// 液态玻璃需要「有东西可折射」的背景。
///
/// 纯色背板上的玻璃只会模糊出一片死色，所以这里铺一层极光渐层：
/// 三个大半径径向光斑（与 iOS 26 壁纸同思路：蓝 / 紫 / 绿），
/// 再叠一层竖向明暗，让玻璃的竖向染色与 rim light 有明暗差可抓。
class AppAuroraBackdrop extends StatelessWidget {
  const AppAuroraBackdrop({super.key, this.child, this.baseColor});

  final Widget? child;

  /// 底板色；不传则透明（叠在已有背景之上）。
  final Color? baseColor;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: baseColor,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [
                  Color(0xFF0B0F16),
                  Color(0xFF101725),
                  Color(0xFF0A0E14),
                ]
              : const [
                  Color(0xFFF2F6FB),
                  Color(0xFFF7F4FB),
                  Color(0xFFF1F6F3),
                ],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      child: Stack(
        children: [
          // 左上蓝色光斑
          Positioned(
            left: -120,
            top: -160,
            child: _Blob(
              size: 420,
              color: const Color(0xFF0A84FF).withValues(alpha: isDark ? 0.30 : 0.16),
            ),
          ),
          // 右上紫色光斑
          Positioned(
            right: -140,
            top: -120,
            child: _Blob(
              size: 400,
              color: const Color(0xFFBF5AF2).withValues(alpha: isDark ? 0.24 : 0.13),
            ),
          ),
          // 底部绿色光斑
          Positioned(
            left: 40,
            bottom: -200,
            child: _Blob(
              size: 460,
              color: const Color(0xFF30D158).withValues(alpha: isDark ? 0.18 : 0.10),
            ),
          ),
          if (child != null) Positioned.fill(child: child!),
        ],
      ),
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
            stops: const [0.0, 1.0],
          ),
        ),
      ),
    );
  }
}
