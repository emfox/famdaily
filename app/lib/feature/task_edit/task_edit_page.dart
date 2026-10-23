import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../app/uuid.dart';
import '../../domain/model/member.dart';
import '../../domain/model/task.dart';
import '../../domain/model/task_status.dart';
import '../../domain/template/task_template.dart';
import 'info_step_page.dart';
import 'task_draft.dart';
import 'template_step_page.dart';
import 'time_step_page.dart';

/// 新建打卡项的三步式二级页（ui-spec §2）。
///
/// 保存在**顶栏**而不是页尾：用户可能在任意一步就想保存（模板和时间
/// 都已经默认给好了），逼着走完三步是无谓的摩擦。
/// 顶栏文案随步数变（保存 / 下一步），但语义只有"能存就存、不能存就说原因"。
///
/// P2 编辑现有项目时复用同一个页面：[TaskEditPage.edit] 直接跳到第 2 步，
/// 可以按「‹」回看第 1、3 步。
class TaskEditPage extends StatefulWidget {
  const TaskEditPage({
    required this.members,
    required this.onSave,
    this.initialTemplate,
    this.initialTask,
    super.key,
  }) : assert(
         initialTemplate == null || initialTask == null,
         '新建和编辑不能同时给初值',
       );

  /// 编辑已有项目。
  factory TaskEditPage.edit({
    required Task task,
    required List<Member> members,
    required Future<void> Function(Task task) onSave,
    Key? key,
  }) => TaskEditPage(
    members: members,
    onSave: onSave,
    initialTask: task,
    key: key,
  );

  final List<Member> members;
  final Future<void> Function(Task task) onSave;

  /// 从某个模板直接进第 2 步（首页空状态点「从模板开始」时用）。
  final TaskTemplate? initialTemplate;

  /// 编辑模式的原项目。
  final Task? initialTask;

  @override
  State<TaskEditPage> createState() => _TaskEditPageState();
}

class _TaskEditPageState extends State<TaskEditPage> {
  static const _stepTitles = ['选模板', '基本信息', '什么时候做'];

  late final TaskDraft _draft;
  late int _step;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final task = widget.initialTask;
    final tpl = widget.initialTemplate;
    if (task != null) {
      _draft = TaskDraft.fromTask(task);
      _step = 1;
    } else if (tpl != null && !tpl.isBlank) {
      _draft = TaskDraft.fromTemplate(tpl);
      _step = 1;
    } else {
      _draft = TaskDraft.fromTemplate(TaskTemplate.blank);
      _step = 0;
    }
    // 单成员时不问"谁做"——只有一个答案的选择题不必出题。
    if (_draft.memberId == null && widget.members.length == 1) {
      _draft.memberId = widget.members.single.id;
    }
  }

  bool get _isEditing => widget.initialTask != null;

  String? get _memberName =>
      widget.members.where((m) => m.id == _draft.memberId).firstOrNull?.name;

  Future<void> _save() async {
    if (!_draft.canSave || _saving) {
      return;
    }
    setState(() => _saving = true);
    final nowMs = clock.now().millisecondsSinceEpoch;
    final existing = widget.initialTask;
    final task = existing == null
        ? _draft.toTask(
            id: newId(),
            memberId: _draft.memberId!,
            nowMs: nowMs,
            sortOrder: nowMs,
          )
        : Task(
            // 编辑：保留原本的 id / 创建时间 / 排序，只换规则与内容。
            id: existing.id,
            memberId: _draft.memberId!,
            name: _draft.name.trim(),
            note: _draft.note.trim().isEmpty ? null : _draft.note.trim(),
            iconId: _draft.iconId,
            repeat: _draft.repeat,
            time: _draft.buildTimeRule(),
            course: _draft.course,
            status: existing.status.isLive
                ? TaskStatus.active
                : existing.status,
            reminderEnabled: _draft.reminderEnabled,
            sortOrder: existing.sortOrder,
            createdAtMs: existing.createdAtMs,
            updatedAtMs: nowMs,
          );

    try {
      await widget.onSave(task);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canSave = _draft.canSave;

    return PopScope(
      // 有未保存的输入时先问一句，避免误触返回键丢掉三步的成果。
      canPop: _step == 0 || _isEditing,
      onPopInvokedWithResult: (bool didPop, Object? _) async {
        if (didPop) {
          return;
        }
        // 回调拿到的 context 不是 State.context，lint 要求用回调参数自己的
        // mounted 判断（这个 context 是 PopScope 所在元素，语义正确）。
        final leave = await _confirmDiscard();
        if (!leave || !context.mounted) {
          return;
        }
        Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          leadingWidth: 64,
          leading: _step == 0
              ? const CloseButton()
              : IconButton(
                  icon: const Icon(Icons.chevron_left),
                  tooltip: '上一步',
                  onPressed: () => setState(() => _step -= 1),
                ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _stepTitles[_step],
                style: theme.textTheme.titleMedium,
              ),
              if (_step > 0)
                Text(
                  '第 ${_step + 1} / 3 步',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
            ],
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _step < 2
                  ? TextButton(
                      onPressed: () => setState(() => _step += 1),
                      child: const Text('下一步'),
                    )
                  : FilledButton(
                      onPressed: canSave && !_saving ? _save : null,
                      child: Text(_isEditing ? '保存' : '创建'),
                    ),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(child: _body()),
            _PreviewBar(
              draft: _draft,
              memberName: _memberName,
              blockingReason: _step == 2 ? _draft.blockReason : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    switch (_step) {
      case 0:
        return TemplateStepPage(
          selected: _draft.templateId.isEmpty ? null : _draft.templateId,
          onSelected: (t) {
            setState(() {
              _draft.applyTemplate(t);
              _step = 1;
            });
          },
          onPickBlank: () {
            setState(() {
              _draft.applyTemplate(TaskTemplate.blank);
              _step = 1;
            });
          },
        );
      case 1:
        return InfoStepPage(
          draft: _draft,
          members: widget.members,
          onChanged: () => setState(() {}),
        );
      default:
        return TimeStepPage(
          draft: _draft,
          onChanged: () => setState(() {}),
        );
    }
  }

  Future<bool> _confirmDiscard() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('还没保存'),
        content: const Text('现在退出去，刚填的内容就没了。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('接着填'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('不要了'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

/// 置底固定的自然语言预览（ui-spec §2.3：「预览：爷爷 · 降压药 …」）。
///
/// 它不是装饰：三层时间规则 × 疗程有太多组合，用户很难在控件之间脑补出
/// 最终效果。这句复述是从 `buildTimeRule()` 真展开出来的，改了哪里立刻能看出。
class _PreviewBar extends StatelessWidget {
  const _PreviewBar({
    required this.draft,
    required this.memberName,
    required this.blockingReason,
  });

  final TaskDraft draft;
  final String? memberName;

  /// 非空时在预览上方红字提示"还差什么"，替代"保存按钮莫名灰着"。
  final String? blockingReason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        20,
        10,
        20,
        10 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '预览',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.outline,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            draft.buildPreview(memberName: memberName),
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
          if (blockingReason != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.info_outline, size: 14, color: scheme.error),
                const SizedBox(width: 6),
                Text(
                  blockingReason!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
