/// 项目图标库：把模板里那个 `iconId` 字符串落到具体图标与配色。
///
/// 为什么不存代码点（`IconData(0xe001)`）：Flutter 会把没用到的图标从字体里
/// tree-shake 掉，存裸 codePoint 会在 release 包里变成方块。存**语义 id**，
/// 由这张表唯一映射，加图标时两边一起改，不会漏。
///
/// 这一层依赖 Flutter（`IconData`），所以放在 `lib/ui/` 而不是 `domain/`——
/// domain 层必须零 Flutter 依赖，CI 有 grep 卡口（tech-stack §8）。
library;

import 'package:flutter/material.dart';

/// 图标 id → 图标 + 配色。
final class TaskIconSpec {
  const TaskIconSpec({
    required this.id,
    required this.icon,
    required this.tone,
  });

  final String id;
  final IconData icon;

  /// 语义色，实际颜色由 [TaskIcons.colorOf] 结合主题色阶算出。
  final IconTone tone;
}

/// 图标配色（ui-spec 表里写的是"绿 / 蓝 / 红 / 紫 / 橙 / 青"六种）。
enum IconTone { green, blue, red, purple, orange, cyan, neutral }

/// 图标库。
abstract final class TaskIcons {
  static const _specs = <String, TaskIconSpec>{
    // 健康
    'pill': TaskIconSpec(
      id: 'pill',
      icon: Icons.medication_outlined,
      tone: IconTone.green,
    ),
    'water': TaskIconSpec(
      id: 'water',
      icon: Icons.water_drop_outlined,
      tone: IconTone.blue,
    ),
    'stethoscope': TaskIconSpec(
      id: 'stethoscope',
      icon: Icons.monitor_heart_outlined,
      tone: IconTone.green,
    ),
    'drop': TaskIconSpec(
      id: 'drop',
      icon: Icons.bloodtype_outlined,
      tone: IconTone.red,
    ),
    'leaf': TaskIconSpec(
      id: 'leaf',
      icon: Icons.spa_outlined,
      tone: IconTone.green,
    ),
    'moon': TaskIconSpec(
      id: 'moon',
      icon: Icons.bedtime_outlined,
      tone: IconTone.purple,
    ),
    // 运动
    'rope': TaskIconSpec(
      id: 'rope',
      icon: Icons.sports_gymnastics,
      tone: IconTone.orange,
    ),
    'walk': TaskIconSpec(
      id: 'walk',
      icon: Icons.directions_walk,
      tone: IconTone.orange,
    ),
    'stretch': TaskIconSpec(
      id: 'stretch',
      icon: Icons.self_improvement,
      tone: IconTone.orange,
    ),
    // 学习 / 生活
    'book': TaskIconSpec(
      id: 'book',
      icon: Icons.menu_book_outlined,
      tone: IconTone.blue,
    ),
    'reading': TaskIconSpec(
      id: 'reading',
      icon: Icons.auto_stories_outlined,
      tone: IconTone.blue,
    ),
    'brush': TaskIconSpec(
      id: 'brush',
      icon: Icons.clean_hands_outlined,
      tone: IconTone.cyan,
    ),
    // 兜底
    'star': TaskIconSpec(
      id: 'star',
      icon: Icons.star_outline,
      tone: IconTone.neutral,
    ),
    'heart': TaskIconSpec(
      id: 'heart',
      icon: Icons.favorite_outline,
      tone: IconTone.red,
    ),
    'home': TaskIconSpec(
      id: 'home',
      icon: Icons.home_outlined,
      tone: IconTone.cyan,
    ),
    'music': TaskIconSpec(
      id: 'music',
      icon: Icons.music_note_outlined,
      tone: IconTone.purple,
    ),
    'paw': TaskIconSpec(
      id: 'paw',
      icon: Icons.pets_outlined,
      tone: IconTone.orange,
    ),
    'plant': TaskIconSpec(
      id: 'plant',
      icon: Icons.local_florist_outlined,
      tone: IconTone.green,
    ),
    'study': TaskIconSpec(
      id: 'study',
      icon: Icons.edit_outlined,
      tone: IconTone.blue,
    ),
    'sport': TaskIconSpec(
      id: 'sport',
      icon: Icons.fitness_center,
      tone: IconTone.orange,
    ),
  };

  /// 图标选择器里按顺序展示的 id（模板的 12 个在前，通用补充在后）。
  static const List<String> pickerOrder = [
    'pill',
    'water',
    'stethoscope',
    'drop',
    'leaf',
    'moon',
    'rope',
    'walk',
    'stretch',
    'book',
    'reading',
    'brush',
    'star',
    'heart',
    'home',
    'music',
    'paw',
    'plant',
    'study',
    'sport',
  ];

  /// 未知 id 退回 `star`——从备份里恢复的老数据不会因此崩。
  static TaskIconSpec resolve(String? id) =>
      _specs[id] ?? _specs['star']!;

  static IconData iconOf(String? id) => resolve(id).icon;

  static IconTone toneOf(String? id) => resolve(id).tone;

  /// 语义色 → 实际颜色。整体压低饱和度：图标只是"认得快"，不该抢标题的注意力。
  static Color colorOf(String? id, ColorScheme scheme) {
    final base = switch (toneOf(id)) {
      IconTone.green => scheme.primary,
      IconTone.blue => const Color(0xFF3F6FA8),
      IconTone.red => const Color(0xFFB4544E),
      IconTone.purple => const Color(0xFF6E5A96),
      IconTone.orange => const Color(0xFFA87242),
      IconTone.cyan => const Color(0xFF3E7F86),
      IconTone.neutral => scheme.outline,
    };
    return base;
  }

  /// 图标底色（浅）。
  static Color backgroundOf(String? id, ColorScheme scheme) {
    final base = colorOf(id, scheme);
    return Color.alphaBlend(base.withValues(alpha: 0.12), scheme.surface);
  }
}

/// 一个圆角方块图标（列表行、模板格、图标选择器共用）。
class TaskIconBadge extends StatelessWidget {
  const TaskIconBadge({
    required this.iconId,
    this.size = 36,
    this.selected = false,
    super.key,
  });

  final String? iconId;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: selected
            ? TaskIcons.colorOf(iconId, scheme).withValues(alpha: 0.22)
            : TaskIcons.backgroundOf(iconId, scheme),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(
        TaskIcons.iconOf(iconId),
        size: size * 0.54,
        color: TaskIcons.colorOf(iconId, scheme),
      ),
    );
  }
}
