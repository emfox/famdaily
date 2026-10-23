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
import '../../app/test_clock.dart';

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
    this.initialMemberId,
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

  /// 新建时预先选好的成员（"上次给谁建过"）。
  ///
  /// 单成员场景由页面自己兜底，这里主要解决多成员时每次都要手点的问题。
  /// 传进来的 id 若已不在 [members] 里（成员被删了），当作没传——
  /// 调用方不必自己校验。
  final String? initialMemberId;

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
    // "谁做"的默认值，按可信度从高到低：
    //   1. 编辑：保持原项目的成员，不要因为"上次给别人建过"就换人
    //   2. 只有一个成员：直接选上，不必出这道只有唯一答案的选择题
    //   3. 上次建过项目的那个人：家里常连着给同一个人建好几项
    // 传入的 id 可能已经失效（成员被删），所以统一用 members 校验一遍。
    if (_draft.memberId == null && widget.initialTask == null) {
      final candidate = widget.members.length == 1
          ? widget.members.single.id
          : widget.initialMemberId;
      if (candidate != null && widget.members.any((m) => m.id == candidate)) {
        _draft.memberId = candidate;
      }
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
    final nowMs = appNow().millisecondsSinceEpoch;
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
    } catch (e) {
      // 写库失败绝不能把用户按在这一页——他只会以为"点了没反应"，
      // 然后一直点，每点一次就多一条记录。报错，然后让他能重试或退出。
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('没存上：$e')));
      }
      return;
    }

    if (!mounted) {
      return;
    }
    // 成功就退出，返回 `true`（存没存成）。
    //
    // 这里**必须**回 bool，不能回 Task：调用方是 push<bool>。曾经新建走
    // push<Task> + 这里 pop(true)，路由类型对不上，页面根本不关，
    // 但库里的记录一条不少地插进去了——用户看到的就是"点了没反应，
    // 回主页却多出一堆"。
    Navigator.of(context).pop(true);
  }

  /// 顶栏的保存/创建按钮。
  ///
  /// 文字**恒定**为「创建」/「保存」：按钮的名字说明它做什么，
  /// 不该拿来当提示牌。缺什么由页面上的字段提示和底栏那行来说。
  Widget _saveButton() {
    if (_saving) {
      return const FilledButton(
        onPressed: null,
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return FilledButton(
      onPressed: _draft.canSave ? _save : null,
      child: Text(_isEditing ? '保存' : '创建'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      // canPop 恒为 false：返回键自己接管。
      //
      // 之前是"第 2/3 步按返回直接问『还没保存』"，可顶栏那个 ‹ 明明是
      // 回上一步——同一个"返回"，两个入口给你两个结果，用户没法建立预期。
      // 现在的口径：**返回 = 退一层**，退到第 1 步了再按才问要不要放弃。
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) async {
        if (didPop) {
          return;
        }
        if (_step > 0) {
          setState(() => _step -= 1);
          return;
        }
        // 第 1 步：模板都没选，什么都没填，直接退，不必问。
        Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          leadingWidth: 64,
          leading: _step == 0
              ? CloseButton(onPressed: () => Navigator.of(context).pop())
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
              if (_step > 0) ...[
                if (_draft.blocker != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '还差：${_draft.blocker!.hint}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                Text(
                  '第 ${_step + 1} / 3 步',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
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
                  : _saveButton(),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(child: _body()),
            // 缺项只在顶栏说一次。底栏再重复一遍是噪音——
            // 同一句话隔半个屏幕出现两次，读起来像是两个不同的问题。
            _PreviewBar(draft: _draft, memberName: _memberName),
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
}

/// 置底固定的自然语言预览（ui-spec §2.3：「预览：爷爷 · 降压药 …」）。
///
/// 它不是装饰：三层时间规则 × 疗程有太多组合，用户很难在控件之间脑补出
/// 最终效果。这句复述是从 `buildTimeRule()` 真展开出来的，改了哪里立刻能看出。
class _PreviewBar extends StatelessWidget {
  const _PreviewBar({required this.draft, required this.memberName});

  final TaskDraft draft;
  final String? memberName;

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
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            draft.buildPreview(memberName: memberName),
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
        ],
      ),
    );
  }
}
