import 'package:flutter/material.dart';

import '../../domain/model/member.dart';
import '../../ui/icon/task_icons.dart';
import '../home/today_page.dart' show MemberAvatar;
import 'task_draft.dart';

/// 新建流程的第 2 步：基本信息（ui-spec §2.2）。
///
/// 只有「叫它」「谁做」是必填，其余一律不强校验——这是需求里反复强调的
/// "别在录入环节拦住用户"。所以这里没有任何 `validator`，只在保存时
/// 由 [TaskDraft.blockReason] 统一说明缺什么。
class InfoStepPage extends StatefulWidget {
  const InfoStepPage({
    required this.draft,
    required this.members,
    required this.onChanged,
    super.key,
  });

  final TaskDraft draft;
  final List<Member> members;

  /// 任一字段变化（页面用它驱动"保存"按钮的高亮）。
  final VoidCallback onChanged;

  @override
  State<InfoStepPage> createState() => _InfoStepPageState();
}

class _InfoStepPageState extends State<InfoStepPage> {
  late final TextEditingController _name = TextEditingController(
    text: widget.draft.name,
  );
  late final TextEditingController _note = TextEditingController(
    text: widget.draft.note,
  );

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  void _touch() {
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draft = widget.draft;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        // ---- 叫它 ----
        _FieldRow(
          label: '叫它',
          child: TextField(
            controller: _name,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              hintText: '比如「降压药」「跳绳」',
              isDense: true,
              border: InputBorder.none,
              hintStyle: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            style: theme.textTheme.bodyLarge,
            onChanged: (v) {
              draft.name = v;
              _touch();
            },
          ),
        ),
        const Divider(height: 1),

        // ---- 谁做 ----
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '谁做',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in widget.members)
                    _MemberChip(
                      member: m,
                      selected: draft.memberId == m.id,
                      onTap: () {
                        draft.memberId = m.id;
                        _touch();
                      },
                    ),
                ],
              ),
              if (widget.members.isEmpty)
                Text(
                  '还没有成员，先去「成员」里加一个',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),

        // ---- 图标 ----
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '图标',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final id in TaskIcons.pickerOrder)
                    _IconChoice(
                      iconId: id,
                      selected: draft.iconId == id,
                      onTap: () {
                        draft.iconId = id;
                        _touch();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // ---- 说一句 ----
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '说一句',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: 4),
              // 措辞刻意区分"事前说明"和"事后备注"：
              // 这句话是给打卡的人看的提醒，不是打卡以后写的心得。
              Text(
                '给打卡的人看的一句话，比如「白色药片 2 粒，饭后半小时」',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              TextField(
                controller: _note,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: '可以不填',
                  isDense: true,
                  border: InputBorder.none,
                ),
                onChanged: (v) {
                  draft.note = v;
                  _touch();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 「左边小标签 + 右边内容」的一行，用横线分隔（表单风格）。
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _MemberChip extends StatelessWidget {
  const _MemberChip({
    required this.member,
    required this.selected,
    required this.onTap,
  });

  final Member member;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 5, 14, 5),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer.withValues(alpha: 0.6)
              : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 1.4,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MemberAvatar(member: member, size: 26),
            const SizedBox(width: 8),
            Text(
              member.name,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconChoice extends StatelessWidget {
  const _IconChoice({
    required this.iconId,
    required this.selected,
    required this.onTap,
  });

  final String iconId;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 1.6,
          ),
        ),
        child: TaskIconBadge(iconId: iconId, size: 36, selected: selected),
      ),
    );
  }
}
