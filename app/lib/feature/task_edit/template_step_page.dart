import 'package:flutter/material.dart';

import '../../domain/model/local_date.dart';
import '../../domain/model/local_time.dart';
import '../../domain/model/time_rule.dart';
import '../../domain/template/task_template.dart';
import '../../ui/icon/task_icons.dart';

/// 新建流程的第 1 步：选模板（ui-spec §2.1）。
///
/// 设计取舍：**不强制**选模板。底部留了「都不是？自己起一个」，
/// 因为模板的价值是"少填三次时间"，不是"必须从模板开始"。
/// 一旦强制，用户给猫加水这种小事也得先在一屏图标里找一圈。
class TemplateStepPage extends StatelessWidget {
  const TemplateStepPage({
    required this.selected,
    required this.onSelected,
    required this.onPickBlank,
    super.key,
  });

  /// 当前选中的模板 id（空字符串 = 还没选 / 空白）。
  final String? selected;

  final ValueChanged<TaskTemplate> onSelected;
  final VoidCallback onPickBlank;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final picked = selected == null
        ? null
        : TemplateLibrary.byId(selected!) ?? TemplateLibrary.all.first;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        for (final group in TemplateGroup.values) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 10),
            child: Text(
              group.titleZh,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          _TemplateGrid(
            templates: TemplateLibrary.of(group),
            selectedId: selected,
            onSelected: onSelected,
          ),
        ],
        const SizedBox(height: 20),
        TextButton.icon(
          onPressed: onPickBlank,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('都不是？自己起一个'),
          style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
        ),
        if (picked != null) ...[
          const SizedBox(height: 8),
          _TemplateHint(template: picked),
        ],
      ],
    );
  }
}

/// 三列网格。用 `Wrap` 而不是 `GridView`：模板只有 12 个，
/// 而且外面已经是 `ListView`，嵌套滚动容器会抢手势。
class _TemplateGrid extends StatelessWidget {
  const _TemplateGrid({
    required this.templates,
    required this.selectedId,
    required this.onSelected,
  });

  final List<TaskTemplate> templates;
  final String? selectedId;
  final ValueChanged<TaskTemplate> onSelected;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 10.0;
        const columns = 3;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final t in templates)
              SizedBox(
                width: width,
                child: _TemplateTile(
                  template: t,
                  selected: t.id == selectedId,
                  onTap: () => onSelected(t),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _TemplateTile extends StatelessWidget {
  const _TemplateTile({
    required this.template,
    required this.selected,
    required this.onTap,
  });

  final TaskTemplate template;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Semantics(
      button: true,
      selected: selected,
      label: template.name,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primaryContainer.withValues(alpha: 0.55)
                : scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Column(
            children: [
              TaskIconBadge(iconId: template.iconId, size: 38),
              const SizedBox(height: 6),
              Text(
                template.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选中模板后的"它会带上什么"提示条（ui-spec：底部的说明块）。
///
/// 它存在的意义是**降低误选成本**：用户看到"一日三次、跟随三餐"就知道
/// 点下去会是什么，不用进去改一圈再发现不对。
class _TemplateHint extends StatelessWidget {
  const _TemplateHint({required this.template});

  final TaskTemplate template;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 这里只是"挑一天展开给人看"，不参与排程；日期无关的模板用哪一天都一样。
    final times = template.timeRule.timesOn(_referenceDay);
    final timeText = times.length == 1
        ? times.first.toString()
        : times.map(_hm).join(' / ');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '选中「${template.name}」会自动带上：',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          _HintRow(
            icon: Icons.schedule,
            text: template.timeRule is MealTimesRule
                ? '时间 跟随三餐（$timeText）'
                : '时间 $timeText',
          ),
          if (template.note != null)
            _HintRow(icon: Icons.sticky_note_2_outlined, text: '说明 ${template.note}'),
          _HintRow(
            icon: TaskIcons.iconOf(template.iconId),
            text: '图标（可换）',
          ),
        ],
      ),
    );
  }

  /// 展示用的参照日（2026-01-01，周四）。
  static final _referenceDay = LocalDate(2026, 1, 1);
}

class _HintRow extends StatelessWidget {
  const _HintRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 15, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _hm(LocalTime t) => '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
