import 'package:flutter/material.dart';

import '../../domain/model/course.dart';
import '../../domain/model/local_date.dart';
import '../../domain/model/local_time.dart';
import '../../domain/model/repeat_rule.dart';
import 'task_draft.dart';

/// 新建流程的第 3 步：什么时候做（ui-spec §2.3 + §2.4）。
///
/// 三个 Tab **共用一份状态**（`draft.timePoints` + `draft.repeat` + `draft.course`）。
/// Tab 只换编辑方式，不换数据结构——所以从「一天几次」切到「自己定时刻」
/// 不会丢任何东西，反过来也一样。
class TimeStepPage extends StatefulWidget {
  const TimeStepPage({
    required this.draft,
    required this.onChanged,
    super.key,
  });

  final TaskDraft draft;
  final VoidCallback onChanged;

  @override
  State<TimeStepPage> createState() => _TimeStepPageState();
}

class _TimeStepPageState extends State<TimeStepPage> {
  TaskDraft get draft => widget.draft;

  void _touch() {
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _TabBar(
          current: draft.timeTab,
          onChanged: (t) {
            // 「一天几次」若当前只有 1 个时刻，补一个更符合"几次"的语义？
            // 不补——空手替用户加一条时间会让人困惑"这条哪来的"。
            // Tab 只切视图，用户不加时间就不加。
            draft.timeTab = t;
            _touch();
          },
        ),
        const SizedBox(height: 16),
        _TimeEditor(draft: draft, onChanged: _touch),
        const SizedBox(height: 16),
        _ExpandableCard(
          title: '更多规则',
          subtitle: _repeatSummary(),
          expanded: draft.repeatExpanded,
          onToggle: () {
            draft.repeatExpanded = !draft.repeatExpanded;
            _touch();
          },
          child: _RepeatEditor(draft: draft, onChanged: _touch),
        ),
        const SizedBox(height: 12),
        _ExpandableCard(
          title: '高级',
          subtitle: '间隔提醒、疗程',
          expanded: draft.advancedExpanded,
          onToggle: () {
            draft.advancedExpanded = !draft.advancedExpanded;
            _touch();
          },
          child: Column(
            children: [
              _IntervalEditor(draft: draft, onChanged: _touch),
              const Divider(height: 28),
              _CourseEditor(draft: draft, onChanged: _touch),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SwitchListTile.adaptive(
          value: draft.reminderEnabled,
          onChanged: (v) {
            draft.reminderEnabled = v;
            _touch();
          },
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          title: Text('到点提醒我', style: theme.textTheme.bodyLarge),
          subtitle: Text(
            '15 分钟没打卡会再催一次',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  String _repeatSummary() {
    if (draft.repeat.isEveryDay && !draft.hasIntervalRule) {
      return '每周几、每隔几小时';
    }
    final parts = <String>[];
    if (!draft.repeat.isEveryDay) {
      parts.add(draft.describeRepeat());
    }
    if (draft.hasIntervalRule) {
      parts.add('另加间隔提醒');
    }
    return parts.join(' · ');
  }
}

// ---------------------------------------------------------------------------
// Tab 条
// ---------------------------------------------------------------------------

class _TabBar extends StatelessWidget {
  const _TabBar({required this.current, required this.onChanged});

  final TimeTab current;
  final ValueChanged<TimeTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          for (final t in TimeTab.values)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(t),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: t == current ? scheme.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    t.labelZh,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: t == current
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: t == current
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 时刻编辑区（三个 Tab 的正文）
// ---------------------------------------------------------------------------

class _TimeEditor extends StatelessWidget {
  const _TimeEditor({required this.draft, required this.onChanged});

  final TaskDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return switch (draft.timeTab) {
      TimeTab.once => _OnceEditor(draft: draft, onChanged: onChanged),
      TimeTab.several => _SeveralEditor(draft: draft, onChanged: onChanged),
      TimeTab.custom => _CustomEditor(draft: draft, onChanged: onChanged),
    };
  }
}

/// 「每天一次」：一个时间轮。
class _OnceEditor extends StatelessWidget {
  const _OnceEditor({required this.draft, required this.onChanged});

  final TaskDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = draft.timePoints.first;
    return _Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: Text('每天做一次', style: theme.textTheme.bodyMedium),
        trailing: _TimeButton(
          time: t,
          onPicked: (v) {
            draft.setPointAt(0, v);
            onChanged();
          },
        ),
      ),
    );
  }
}

/// 「一天几次」：「跟三餐走」开关 + N 个时间行。
class _SeveralEditor extends StatelessWidget {
  const _SeveralEditor({required this.draft, required this.onChanged});

  final TaskDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return _Card(
      child: Column(
        children: [
          SwitchListTile.adaptive(
            value: draft.followMeals,
            onChanged: (v) {
              draft.setFollowMeals(v);
              onChanged();
            },
            contentPadding: const EdgeInsets.only(left: 16, right: 8),
            title: Text('跟三餐走', style: theme.textTheme.bodyMedium),
            subtitle: Text(
              '按吃饭时间自动定，饭前饭后可调',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (draft.followMeals)
            _MealPanel(draft: draft, onChanged: onChanged)
          else
            _PointList(draft: draft, onChanged: onChanged, allowAdd: true),
        ],
      ),
    );
  }
}

/// 跟三餐：三行"餐名 + 钟点"，加一个偏移选择。
class _MealPanel extends StatelessWidget {
  const _MealPanel({required this.draft, required this.onChanged});

  final TaskDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      children: [
        for (final a in MealAnchor.values)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 12, 2),
            child: Row(
              children: [
                Checkbox(
                  value: draft.mealSelection.contains(a),
                  onChanged: (v) {
                    draft.toggleMeal(a, v ?? false);
                    onChanged();
                  },
                  visualDensity: VisualDensity.compact,
                ),
                Expanded(
                  child: Text(_mealName(a), style: theme.textTheme.bodyMedium),
                ),
                Text(
                  draft.mealTimeOf(a).toString(),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  tooltip: '改${_mealName(a)}时间',
                  onPressed: () async {
                    final picked = await _pickTime(
                      context,
                      draft.mealTimeOf(a),
                    );
                    if (picked == null) {
                      return;
                    }
                    draft.setMealTime(a, picked);
                    onChanged();
                  },
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: Row(
            children: [
              Text('时间', style: theme.textTheme.bodySmall),
              const SizedBox(width: 10),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  children: [
                    for (final off in const [-30, 0, 15, 30, 60])
                      ChoiceChip(
                        label: Text(_offsetLabel(off)),
                        selected: draft.followMealOffsetMinutes == off,
                        onSelected: (_) {
                          draft.setFollowMealOffset(off);
                          onChanged();
                        },
                        visualDensity: VisualDensity.compact,
                        labelStyle: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _mealName(MealAnchor a) => switch (a) {
    MealAnchor.breakfast => '早饭',
    MealAnchor.lunch => '午饭',
    MealAnchor.dinner => '晚饭',
  };

  static String _offsetLabel(int off) {
    if (off == 0) {
      return '准点';
    }
    return off > 0 ? '饭后 $off 分' : '饭前 ${-off} 分';
  }
}

/// 「自己定时刻」：可增删的时间行。
class _CustomEditor extends StatelessWidget {
  const _CustomEditor({required this.draft, required this.onChanged});

  final TaskDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Card(
      child: Column(
        children: [
          _PointList(draft: draft, onChanged: onChanged, allowAdd: false),
          if (draft.canAddPoint)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 6),
                child: TextButton.icon(
                  onPressed: () {
                    draft.addPoint();
                    onChanged();
                  },
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加时间'),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '一天最多 $maxPointsPerDay 次',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 时间行列表（「一天几次」和「自己定时刻」共用）。
class _PointList extends StatelessWidget {
  const _PointList({
    required this.draft,
    required this.onChanged,
    required this.allowAdd,
  });

  final TaskDraft draft;
  final VoidCallback onChanged;

  /// 「一天几次」里也允许加，但列表本身不画"添加"按钮（由父级决定位置）。
  final bool allowAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final points = draft.timePoints;

    return Column(
      children: [
        for (var i = 0; i < points.length; i++)
          Padding(
            padding: EdgeInsets.fromLTRB(16, i == 0 ? 10 : 2, 8, 2),
            child: Row(
              children: [
                Text('第 ${i + 1} 次', style: theme.textTheme.bodyMedium),
                const Spacer(),
                _TimeButton(
                  time: points[i],
                  onPicked: (v) {
                    draft.setPointAt(i, v);
                    onChanged();
                  },
                ),
                if (draft.canRemovePoint)
                  IconButton(
                    tooltip: '删掉这次',
                    icon: const Icon(Icons.remove_circle_outline, size: 19),
                    onPressed: () {
                      draft.removePointAt(i);
                      onChanged();
                    },
                  )
                else
                  const SizedBox(width: 40),
              ],
            ),
          ),
        if (allowAdd && draft.canAddPoint)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 4),
              child: TextButton.icon(
                onPressed: () {
                  draft.addPoint();
                  onChanged();
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('再加一次'),
              ),
            ),
          ),
      ],
    );
  }
}

/// 可点的时间文字，点了开时间轮。
class _TimeButton extends StatelessWidget {
  const _TimeButton({required this.time, required this.onPicked});

  final LocalTime time;
  final ValueChanged<LocalTime> onPicked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return TextButton(
      onPressed: () async {
        final picked = await _pickTime(context, time);
        if (picked != null) {
          onPicked(picked);
        }
      },
      style: TextButton.styleFrom(
        foregroundColor: scheme.primary,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        time.toString(),
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
          // 等宽数字：时间在列表里上下对齐，不然 7:30 和 12:30 的冒号错位。
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 更多规则
// ---------------------------------------------------------------------------

class _RepeatEditor extends StatelessWidget {
  const _RepeatEditor({required this.draft, required this.onChanged});

  final TaskDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final r = draft.repeat;
    final weekdays = r.weekdays ?? const <int>{};

    void setRepeat(RepeatRule next) {
      draft.repeat = next;
      onChanged();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Text('哪天做', style: theme.textTheme.bodyMedium),
        ),
        Wrap(
          spacing: 6,
          children: [
            for (var wd = 1; wd <= 7; wd++)
              _WeekdayDot(
                label: const ['一', '二', '三', '四', '五', '六', '日'][wd - 1],
                selected: weekdays.isEmpty || weekdays.contains(wd),
                onTap: () {
                  final next = {...weekdays};
                  if (next.isEmpty) {
                    // 从"不限"点一下 → 变成只选这一天
                    next.add(wd);
                  } else if (!next.remove(wd)) {
                    next.add(wd);
                  }
                  // 全选等于不限，存 null 更省事也更好读
                  setRepeat(
                    next.length == 7
                        ? RepeatRule(
                            everyNDays: r.everyNDays,
                            anchor: r.anchor,
                            parity: r.parity,
                            monthDays: r.monthDays,
                          )
                        : RepeatRule(
                            weekdays: next,
                            everyNDays: r.everyNDays,
                            anchor: r.anchor,
                            parity: r.parity,
                            monthDays: r.monthDays,
                          ),
                  );
                },
              ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          children: [
            ActionChip(
              label: const Text('每天'),
              onPressed: () => setRepeat(RepeatRule.daily),
              visualDensity: VisualDensity.compact,
              labelStyle: theme.textTheme.bodySmall,
            ),
            for (final p in ParityFilter.values)
              ActionChip(
                label: Text(switch (p) {
                  ParityFilter.workdays => '工作日',
                  ParityFilter.weekends => '周末',
                  ParityFilter.oddWeeks => '单周',
                  ParityFilter.evenWeeks => '双周',
                }),
                onPressed: () => setRepeat(
                  RepeatRule(
                    parity: p,
                    everyNDays: r.everyNDays,
                    anchor: r.anchor,
                    monthDays: r.monthDays,
                  ),
                ),
                visualDensity: VisualDensity.compact,
                labelStyle: theme.textTheme.bodySmall,
              ),
          ],
        ),
        if (!r.isSatisfiable)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              '这几条规则凑不到一起，永远不会提醒',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
        const SizedBox(height: 8),
        _StepperRow(
          label: '每',
          suffix: '天一次',
          value: r.everyNDays ?? 0,
          min: 0,
          max: 60,
          zeroHint: '不按间隔',
          onChanged: (v) => setRepeat(
            RepeatRule(
              weekdays: r.weekdays,
              everyNDays: v == 0 ? null : v,
              anchor: v == 0 ? null : LocalDate.today(),
              parity: r.parity,
              monthDays: r.monthDays,
            ),
          ),
        ),
      ],
    );
  }
}

class _WeekdayDot extends StatelessWidget {
  const _WeekdayDot({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? scheme.primary : Colors.transparent,
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 间隔提醒（"每 2 小时，从 9:00 到 21:00"）。
class _IntervalEditor extends StatelessWidget {
  const _IntervalEditor({required this.draft, required this.onChanged});

  final TaskDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('另加间隔提醒', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 2),
        Text(
          '在上面那些时刻之外，再加一串固定间隔的提醒',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        _StepperRow(
          label: '每',
          suffix: '小时一次',
          value: draft.intervalEveryMinutes == 0
              ? 0
              : (draft.intervalEveryMinutes / 60).round(),
          min: 0,
          max: 12,
          zeroHint: '不用这个规则',
          onChanged: (v) {
            draft.intervalEveryMinutes = v * 60;
            onChanged();
          },
        ),
        if (draft.intervalEveryMinutes > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Text('从', style: theme.textTheme.bodySmall),
                const SizedBox(width: 6),
                _TimeButton(
                  time: draft.intervalFrom ?? _fallbackNine,
                  onPicked: (v) {
                    draft.intervalFrom = v;
                    onChanged();
                  },
                ),
                Text('到', style: theme.textTheme.bodySmall),
                const SizedBox(width: 6),
                _TimeButton(
                  time: draft.intervalTo ?? TimeDefaults.evening,
                  onPicked: (v) {
                    draft.intervalTo = v;
                    onChanged();
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// `LocalTime` 的公开构造是 factory（非 const），所以只能写成 getter。
LocalTime get _fallbackNine => LocalTime(9, 0);

/// 疗程（ui-spec §2.4）。
class _CourseEditor extends StatelessWidget {
  const _CourseEditor({required this.draft, required this.onChanged});

  final TaskDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final course = draft.course;
    final limited = !course.isOpenEnded;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('做多久', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            ChoiceChip(
              label: const Text('一直做'),
              selected: !limited,
              onSelected: (_) {
                draft.course = Course.none;
                onChanged();
              },
              visualDensity: VisualDensity.compact,
              labelStyle: theme.textTheme.bodySmall,
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('做一段时间'),
              selected: limited,
              onSelected: (_) {
                if (limited) {
                  return;
                }
                draft.course = Course.days(LocalDate.today(), 7);
                onChanged();
              },
              visualDensity: VisualDensity.compact,
              labelStyle: theme.textTheme.bodySmall,
            ),
          ],
        ),
        if (limited) ...[
          const SizedBox(height: 8),
          _StepperRow(
            label: '连着做',
            suffix: '天',
            value: course.totalDays ?? course.daysRemaining(course.start!)! + 1,
            min: 1,
            max: 365,
            zeroHint: '',
            onChanged: (v) {
              draft.course = Course.days(course.start ?? LocalDate.today(), v);
              onChanged();
            },
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '到 ${course.end!.month}/${course.end!.day} 结束，'
              '到期自动归档，记录都留着',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 小零件
// ---------------------------------------------------------------------------

/// 数字步进器：`- [N] +`。0 就是"不用这条规则"，用 [zeroHint] 说清楚。
class _StepperRow extends StatelessWidget {
  const _StepperRow({
    required this.label,
    required this.suffix,
    required this.value,
    required this.min,
    required this.max,
    required this.zeroHint,
    required this.onChanged,
  });

  final String label;
  final String suffix;
  final int value;
  final int min;
  final int max;
  final String zeroHint;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        const SizedBox(width: 6),
        IconButton(
          onPressed: value > min ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove_circle_outline, size: 20),
          visualDensity: VisualDensity.compact,
        ),
        SizedBox(
          width: 34,
          child: Text(
            value == 0 && zeroHint.isNotEmpty ? '—' : '$value',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        IconButton(
          onPressed: value < max ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add_circle_outline, size: 20),
          visualDensity: VisualDensity.compact,
        ),
        Flexible(
          child: Text(
            value == 0 && zeroHint.isNotEmpty ? zeroHint : suffix,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 用 Material 而不是 Container 上色：里面有 ListTile / SwitchListTile，
    // 它们把水波纹画在最近的 Material 上，中间夹一层有色 DecoratedBox
    // 会把水波纹盖掉（框架会当场 assert 提醒）。
    return Material(
      color: scheme.surfaceContainerLowest,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: child,
    );
  }
}

class _ExpandableCard extends StatelessWidget {
  const _ExpandableCard({
    required this.title,
    required this.subtitle,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Card(
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  Text(title, style: theme.textTheme.bodyLarge),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.chevron_right,
                    size: 20,
                    color: theme.colorScheme.outline,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: child,
            ),
        ],
      ),
    );
  }
}

Future<LocalTime?> _pickTime(BuildContext context, LocalTime initial) async {
  final picked = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(alwaysUse24HourFormat: true),
      child: child!,
    ),
  );
  if (picked == null) {
    return null;
  }
  return LocalTime(picked.hour, picked.minute);
}
