/// 成员管理的数据装配：列表、增删改、排序。
///
/// 老的 `MemberAvatar` 只画"首字 + 稳定配色"，看不出预置头像。这个文件把
/// 头像库（`AvatarLibrary.ids`）里的语义名映射到实际图标与配色，供成员页与
/// 选择器共用。**放在 feature 层而不是 domain**：图标来自 Material，domain 不能碰。
library;

import 'package:flutter/material.dart';

import '../../data/db/app_database.dart' hide Member, Task, Checkin, Slot;
import '../../domain/model/checkin_state.dart';
import '../../domain/model/local_date.dart';
import '../../domain/model/member.dart';
import '../../domain/stats/stats.dart';

/// 一个头像选项长什么样。
final class AvatarOption {
  const AvatarOption({
    required this.id,
    required this.label,
    required this.icon,
    required this.bg,
    required this.fg,
  });

  /// 存进 `member.avatarId` 的语义 id（与 `AvatarLibrary.ids` 一致）。
  final String id;

  /// 给无障碍朗读用的人话名字。
  final String label;

  final IconData icon;
  final Color bg;
  final Color fg;
}

/// 预置头像库：名字 → 图标 + 配色。
///
/// 色板刻意避开"太有攻击性"的红与纯灰：这是家人列表，不是告警中心。
abstract final class MemberAvatars {
  static const List<AvatarOption> all = [
    AvatarOption(
      id: 'grandpa',
      label: '爷爷',
      icon: Icons.elderly,
      bg: Color(0xFFE3EEE7),
      fg: Color(0xFF3F6B52),
    ),
    AvatarOption(
      id: 'grandma',
      label: '奶奶',
      icon: Icons.elderly_woman,
      bg: Color(0xFFF3E8EF),
      fg: Color(0xFF7A4A63),
    ),
    AvatarOption(
      id: 'dad',
      label: '爸爸',
      icon: Icons.man,
      bg: Color(0xFFE3EAF3),
      fg: Color(0xFF3C567A),
    ),
    AvatarOption(
      id: 'mom',
      label: '妈妈',
      icon: Icons.woman,
      bg: Color(0xFFF6E9E4),
      fg: Color(0xFF86503C),
    ),
    AvatarOption(
      id: 'boy',
      label: '男孩',
      icon: Icons.boy,
      bg: Color(0xFFE6F0F0),
      fg: Color(0xFF3D6A6A),
    ),
    AvatarOption(
      id: 'girl',
      label: '女孩',
      icon: Icons.girl,
      bg: Color(0xFFF7E8EC),
      fg: Color(0xFF8A4A5C),
    ),
    AvatarOption(
      id: 'baby',
      label: '宝宝',
      icon: Icons.child_care,
      bg: Color(0xFFFBF0DE),
      fg: Color(0xFF8A6A32),
    ),
    AvatarOption(
      id: 'me',
      label: '我自己',
      icon: Icons.person,
      bg: Color(0xFFE8E6F2),
      fg: Color(0xFF524D7C),
    ),
    AvatarOption(
      id: 'cat',
      label: '猫',
      icon: Icons.pets,
      bg: Color(0xFFF0EDE4),
      fg: Color(0xFF6E6650),
    ),
    AvatarOption(
      id: 'dog',
      label: '狗',
      icon: Icons.cruelty_free,
      bg: Color(0xFFEDEAE0),
      fg: Color(0xFF6A6249),
    ),
    AvatarOption(
      id: 'flower',
      label: '花',
      icon: Icons.local_florist,
      bg: Color(0xFFE9F2E1),
      fg: Color(0xFF4E7040),
    ),
    AvatarOption(
      id: 'ball',
      label: '球',
      icon: Icons.sports_soccer,
      bg: Color(0xFFE4EEF7),
      fg: Color(0xFF3A5F80),
    ),
  ];

  static final Map<String, AvatarOption> _byId = {
    for (final a in all) a.id: a,
  };

  /// 按 id 找；未知 id 返回 null（调用方回落到"首字色块"）。
  static AvatarOption? find(String? id) =>
      id == null ? null : _byId[id];

  /// 名字首字兜底用的 8 色板。与 `AvatarLibrary.colorIndexFor` 配套。
  static const List<Color> fallbackPalette = [
    Color(0xFFE3EEE7),
    Color(0xFFE3EAF3),
    Color(0xFFF6E9E4),
    Color(0xFFE8E6F2),
    Color(0xFFFBF0DE),
    Color(0xFFE6F0F0),
    Color(0xFFF3E8EF),
    Color(0xFFEDEAE0),
  ];

  /// 名字首字兜底头像的底色。
  static Color fallbackColor(Member m) =>
      fallbackPalette[m.avatarColorIndex % fallbackPalette.length];

  /// 头像上的前景色（图标色 / 首字色）。
  static Color fallbackForeground(Member m) {
    final bg = fallbackColor(m);
    // HSL 亮度压到投巧范围，保证浅底上能看清。
    final hsl = HSLColor.fromColor(bg);
    return hsl
        .withLightness((hsl.lightness - 0.35).clamp(0.0, 1.0))
        .withSaturation((hsl.saturation + 0.15).clamp(0.0, 1.0))
        .toColor();
  }
}

/// 列表里的一行：成员 + 他有几个活着的打卡项。
final class MemberSummary {
  const MemberSummary({required this.member, required this.taskCount});

  final Member member;

  /// 未删除、未归档的项目数。
  final int taskCount;

  String get taskCountLabel => taskCount == 0 ? '还没安排打卡项' : '$taskCount 项';
}

/// 成员页装配器 + 写操作。
///
/// 所有写操作后都要重排提醒：成员名会进通知文案（"爷爷的降压药"），
/// 改了名字不重排，明天响的还是旧名字。重排本身由外部注入——
/// 这样成员页不直接依赖排程器，测试也不用伪造整条通知链。
final class MemberService {
  MemberService({required this.db, this.onDataChanged});

  final AppDatabase db;

  /// 写完之后要做的事（生产环境传 `scheduler.reschedule(dataChanged)`）。
  final Future<void> Function()? onDataChanged;

  Future<List<MemberSummary>> list() async {
    final members = await db.listMembers();
    final tasks = await db.listAllTasks();
    final live = tasks.where((t) => t.isLive).toList(growable: false);
    return [
      for (final m in members)
        MemberSummary(
          member: m,
          taskCount: live.where((t) => t.memberId == m.id).length,
        ),
    ];
  }

  Future<Member?> find(String id) => db.findMember(id);

  /// 新增。id 由调用方给（便于测试），排序由数据库追加到末尾。
  Future<void> create(Member m) async {
    await db.insertMember(m, nowMs: m.createdAtMs);
    await _afterWrite();
  }

  /// 改名 / 换头像 / 改排序。
  Future<void> update(Member m, {required int nowMs}) async {
    await db.updateMember(m, nowMs: nowMs);
    await _afterWrite();
  }

  /// 软删除。历史记录留在日历里，`member_id` 不断链。
  Future<void> remove(String id, {required int nowMs}) async {
    await db.deleteMember(id, nowMs: nowMs);
    await _afterWrite();
  }

  /// 按 id 顺序重写 sortOrder。
  Future<void> reorder(List<String> orderedIds, {required int nowMs}) async {
    await db.reorderMembers(orderedIds, nowMs: nowMs);
    await _afterWrite();
  }

  /// 列表里上移/下移一位，返回新顺序。
  ///
  /// 上移/下移按钮比拖拽更可靠：老人手上的拖拽经常"拖了一半又弹回去"，
  /// 而且拖拽在长列表里很难精确落位。拖拽只作为额外手势保留。
  static List<String> moved(List<String> ids, int from, int to) {
    if (from == to ||
        from < 0 ||
        to < 0 ||
        from >= ids.length ||
        to >= ids.length) {
      return List<String>.of(ids);
    }
    final next = List<String>.of(ids);
    final item = next.removeAt(from);
    next.insert(to, item);
    return next;
  }

  /// 某个成员的本月统计（明细页头部）。
  ///
  /// 分母只算**这个成员**的槽位；未来日期本该排的也算进去不太好看，
  /// 所以按月内"截至今天"截断——和首页/日历的口径一致：没到的日子不背锅。
  Future<StatsSummary> monthStats(
    String memberId, {
    required LocalDate today,
  }) async {
    final first = LocalDate(today.year, today.month, 1);
    final last = first.lastDayOfMonth;
    final slots = await db.slotsBetween(first, last);
    final records = await db.checkinsBetween(first, last);

    final myTasks = {
      for (final t in await db.listTasksOfMember(memberId)) t.id,
    };
    final bySlot = <String, CheckinState>{
      for (final r in records) '${r.taskId}|${r.date}|${r.slotIndex}': r.state,
    };

    final entries = <StatsEntry>[
      for (final s in slots)
        if (myTasks.contains(s.taskId) && !s.date.isAfter(today))
          StatsEntry(s.date, bySlot['${s.taskId}|${s.date}|${s.slotIndex}']),
    ];
    return Stats.summarize(entries);
  }

  /// 成员名的一句话统计，"3 个打卡项 · 本月完成 89%"。
  static String headline(MemberSummary summary, StatsSummary stats) {
    if (stats.expected == 0) {
      return summary.taskCount == 0 ? '还没安排打卡项' : '本月还没有记录';
    }
    return '${summary.taskCount} 个打卡项 · 本月完成 ${stats.percent(stats.completionRate)}';
  }

  Future<void> _afterWrite() async {
    final hook = onDataChanged;
    if (hook != null) {
      await hook();
    }
  }
}
