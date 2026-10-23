import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../app/app_boot.dart';
import '../../app/uuid.dart';
import '../../data/db/app_database.dart' hide Member, Task, Checkin, Slot;
import '../../domain/model/checkin.dart';
import '../../domain/model/checkin_row.dart';
import '../../domain/model/checkin_state.dart';
import '../../domain/model/local_date.dart';
import '../../domain/model/member.dart';
import '../../domain/model/task.dart';
import '../../domain/model/task_status.dart';
import '../../domain/notification/window_policy.dart';
import '../task_edit/task_edit_page.dart';
import 'checkin_sheets.dart';
import 'today_page.dart';
import 'today_service.dart';

/// 首页的状态容器。
///
/// 用 StatefulWidget + 显式 `_load` 而不是 Riverpod 的 AsyncNotifier：
/// 首页的数据是"一屏快照"，每次操作后整体重读一次最省心也最不容易错。
/// 复杂度留给真正需要细粒度刷新的地方（P2 的日历）。
class HomeScreen extends StatefulWidget {
  const HomeScreen({required this.services, super.key});

  final AppServices services;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  late final TodayService _service = TodayService(widget.services.db);

  TodayView _view = TodayView.empty;
  HomeLayout _layout = HomeLayout.timeline;
  List<Member> _members = const [];
  bool _loading = true;
  LocalDate _lastKnownDay = LocalDate.fromDateTime(clock.now());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restoreLayout());
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    final today = LocalDate.fromDateTime(clock.now());
    if (today == _lastKnownDay) {
      // 没跨天也要重算一遍：此刻的"迟 N 分钟"变了。
      unawaited(_load(silent: true));
      return;
    }
    _lastKnownDay = today;
    unawaited(
      widget.services.scheduler.reschedule(
        trigger: RescheduleTrigger.resumed,
      ),
    );
    unawaited(_load());
  }

  /// 记住用户选的排法（ui-spec §1："记住选择"）。
  Future<void> _restoreLayout() async {
    final raw = await widget.services.db.getSetting('home.layout');
    if (!mounted || raw == null) {
      return;
    }
    final parsed = HomeLayout.values
        .where((e) => e.name == raw)
        .firstOrNull;
    if (parsed != null) {
      setState(() => _layout = parsed);
    }
  }

  Future<void> _setLayout(HomeLayout layout) async {
    setState(() => _layout = layout);
    await widget.services.db.setSetting(
      'home.layout',
      layout.name,
      nowMs: clock.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() => _loading = true);
    }
    try {
      final view = await _service.load();
      if (!mounted) {
        return;
      }
      // 成员列表随首页一起读：新建表单要用它做"谁做"的选择，
      // 单独再查一次只会多一次往返，还得自己处理两者不同步。
      final members = await widget.services.db.listMembers();
      if (!mounted) {
        return;
      }
      setState(() {
        _view = view;
        _members = members;
        _lastKnownDay = view.date ?? _lastKnownDay;
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  /// 点某一行。
  ///
  /// 四条分支，每条都有明确的"为什么"：
  /// - 已结案 + 点圆圈 → 撤销（ui-spec："点已完成的勾 = 撤销"）
  /// - 已过时间 + 点圆圈 → 弹两个出口，**绝不直接打卡**（避免把"没做"记成"做了"）
  /// - 未到时间 + 点圆圈 → 直接记为准时
  /// - 点整行文字 → 详情（P1 先什么都不做，P2 接详情页）
  Future<void> _onTapRow(CheckinRow row, {required bool tappedCircle}) async {
    if (!tappedCircle) {
      return;
    }

    final today = _view.date ?? LocalDate.fromDateTime(clock.now());
    final now = _view.now;
    final visual = now == null
        ? CheckinVisual.pending
        : row.visual(today, now);

    switch (visual) {
      case CheckinVisual.doneOnTime:
      case CheckinVisual.doneMakeup:
      case CheckinVisual.skipped:
        final ok = await _service.undo(row: row, today: today);
        if (!mounted) {
          return;
        }
        if (!ok) {
          _toast('超过 30 天，不能再改了');
          return;
        }
        await _afterChange();
        return;

      case CheckinVisual.overdue:
        final choice = await showOverdueSheet(context, row);
        if (choice == null || !mounted) {
          return;
        }
        await _persist(row, choice);
        return;

      case CheckinVisual.pending:
        await _persist(row, CheckinChoice.done);
        if (!mounted) {
          return;
        }
        // 打完卡立刻给个"记一句"的入口（ui-spec：浮出后 3 秒收起）。
        final note = await showNoteSheet(context, row);
        if (note != null && note.trim().isNotEmpty) {
          await _attachNote(row, note.trim());
        }
        return;
    }
  }

  Future<void> _persist(CheckinRow row, CheckinChoice choice) async {
    final now = clock.now();
    final state = switch (choice) {
      CheckinChoice.done => CheckinState.done,
      CheckinChoice.makeup => CheckinState.makeup,
      CheckinChoice.skipped => CheckinState.skipped,
    };

    await widget.services.db.upsertCheckin(
      CheckinRecord(
        id: newId(),
        taskId: row.task.id,
        date: row.date,
        slotIndex: row.slotIndex,
        state: state,
        doneAtMs: now.millisecondsSinceEpoch,
        dueAtMinuteOfDay: row.dueMinuteOfDay,
        note: row.record?.note,
        photoPath: row.record?.photoPath,
      ),
      nowMs: now.millisecondsSinceEpoch,
    );

    // 打完卡立刻静音：不等下一次全量重排，否则用户刚点完就听见提醒响。
    unawaited(
      widget.services.scheduler.cancelForCheckin(
        taskId: row.task.id,
        date: row.date,
        slotIndex: row.slotIndex,
      ),
    );

    await _afterChange();
  }

  Future<void> _attachNote(CheckinRow row, String note) async {
    final existing = row.record;
    if (existing == null) {
      return;
    }
    final now = clock.now();
    await widget.services.db.upsertCheckin(
      CheckinRecord(
        id: existing.id,
        taskId: existing.taskId,
        date: existing.date,
        slotIndex: existing.slotIndex,
        state: existing.state,
        doneAtMs: existing.doneAtMs,
        dueAtMinuteOfDay: existing.dueAtMinuteOfDay,
        note: note,
        photoPath: existing.photoPath,
      ),
      nowMs: now.millisecondsSinceEpoch,
    );
    await _load(silent: true);
  }

  /// 数据变了之后：重读首页 + 重排提醒（trigger = dataChanged）。
  Future<void> _afterChange() async {
    await _load(silent: true);
    unawaited(
      widget.services.scheduler.reschedule(
        trigger: RescheduleTrigger.dataChanged,
      ),
    );
  }

  /// 新建打卡项（ui-spec §2 三步式）。
  Future<void> _newTask() async {
    if (_members.isEmpty) {
      _toast('先加一个成员，才能给他安排打卡');
      return;
    }
    final created = await Navigator.of(context).push<Task>(
      MaterialPageRoute(
        builder: (_) => TaskEditPage(
          members: _members,
          onSave: _saveTask,
        ),
      ),
    );
    if (created == null || !mounted) {
      return;
    }
    await _afterChange();
    if (mounted) {
      _toast('已加上「${created.name}」');
    }
  }

  /// 表单里点「创建 / 保存」时落到库里的动作。
  ///
  /// 新建走 insert，编辑走 update——用 [Task.createdAtMs] 是否等于
  /// `updatedAtMs` 判断不可靠，所以这里直接查一次库看有没有这行。
  Future<void> _saveTask(Task task) async {
    final nowMs = clock.now().millisecondsSinceEpoch;
    final existing = await widget.services.db.findTask(task.id);
    if (existing == null) {
      await widget.services.db.insertTask(task, nowMs: nowMs);
    } else {
      await widget.services.db.updateTask(task, nowMs: nowMs);
    }
    // 规则变了，槽位要重算；数据变了也顺带把提醒重排一次
    // （在 _afterChange 里做，这里只保证落库）。
    if (task.status != TaskStatus.active) {
      await widget.services.db.setTaskStatus(
        task.id,
        task.status,
        nowMs: nowMs,
      );
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return TodayPage(
      view: _view,
      layout: _layout,
      onLayoutChanged: (l) => unawaited(_setLayout(l)),
      onTapRow: (row, {required tappedCircle}) =>
          unawaited(_onTapRow(row, tappedCircle: tappedCircle)),
      onNewTask: () => unawaited(_newTask()),
      onRefresh: () async {
        await _load(silent: true);
        await widget.services.scheduler.reschedule(
          trigger: RescheduleTrigger.dataChanged,
        );
      },
      loading: _loading,
    );
  }
}

/// 把 [AppDatabase] 的打卡写入包装成"幂等 + 已完成优先"。
///
/// 直接复用 DAO 的同名方法，这里只是给 UI 一个不依赖 drift 的入口。
extension CheckinWriter on AppDatabase {
  Future<void> saveCheckin(CheckinRecord c) async {
    await upsertCheckin(c, nowMs: clock.now().millisecondsSinceEpoch);
  }
}
