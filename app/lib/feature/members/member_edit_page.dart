import 'package:flutter/material.dart';

import '../../domain/model/member.dart';
import 'member_avatar.dart';
import 'member_service.dart';
import '../../app/test_clock.dart';

/// 新增 / 编辑成员（ui-spec §5.2）。
///
/// 只有两个字段：叫什么、选个头像。**故意没有别的**——成员是标签不是账号，
/// 不需要生日、关系、手机号。多一个字段就多一次"这玩意儿要填吗"的犹豫。
class MemberEditPage extends StatefulWidget {
  const MemberEditPage({required this.service, this.initial, super.key});

  final MemberService service;

  /// null = 新增。
  final Member? initial;

  @override
  State<MemberEditPage> createState() => _MemberEditPageState();
}

class _MemberEditPageState extends State<MemberEditPage> {
  late final TextEditingController _name;
  String? _avatarId;
  bool _avatarTouched = false;

  bool get _isEditing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial?.name ?? '');
    _avatarId = widget.initial?.avatarId;
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// 预览用：还没落库，先拼一个临时的成员对象给头像组件。
  Member get _preview => Member(
    id: widget.initial?.id ?? 'preview',
    name: _name.text.trim(),
    avatarId: _avatarId,
    sortOrder: widget.initial?.sortOrder ?? 0,
    createdAtMs: widget.initial?.createdAtMs ?? 0,
    updatedAtMs: 0,
  );

  bool get _canSave => _name.text.trim().isNotEmpty;

  Future<void> _save() async {
    final nowMs = appNow().millisecondsSinceEpoch;
    final name = _name.text.trim();
    final service = widget.service;

    if (_isEditing) {
      await service.update(
        widget.initial!.copyWith(name: name, avatarId: _avatarId),
        nowMs: nowMs,
      );
    } else {
      await service.create(
        Member(
          id: 'm${nowMs}_${_name.text.hashCode.abs()}',
          name: name,
          avatarId: _avatarId,
          sortOrder: 0,
          createdAtMs: nowMs,
          updatedAtMs: nowMs,
        ),
      );
    }
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        leadingWidth: 72,
        title: Text(_isEditing ? '改成员' : '新增成员'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _canSave ? _save : null,
              child: const Text('保存'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
        children: [
          Center(child: MemberAvatar(member: _preview, size: 76)),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            autofocus: !_isEditing,
            textAlign: TextAlign.center,
            textInputAction: TextInputAction.done,
            style: theme.textTheme.headlineSmall,
            decoration: const InputDecoration(
              hintText: '叫什么',
              border: InputBorder.none,
            ),
            onSubmitted: (_) {
              if (_canSave) {
                _save();
              }
            },
          ),
          const SizedBox(height: 8),
          const Divider(),
          const SizedBox(height: 16),
          Text(
            '选个头像',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '不选也行，会用名字的第一个字自动生成',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final option in MemberAvatars.all)
                _AvatarChoice(
                  selected: _avatarId == option.id,
                  bg: option.bg,
                  fg: option.fg,
                  icon: option.icon,
                  semanticLabel: option.label,
                  onTap: () => setState(() {
                    _avatarTouched = true;
                    _avatarId = option.id;
                  }),
                ),
              // 显式提供一个"用字"选项：选过图标之后想反悔，需要有条路。
              _AvatarChoice(
                selected: _avatarTouched && _avatarId == null,
                bg: MemberAvatars.fallbackColor(_preview),
                fg: MemberAvatars.fallbackForeground(_preview),
                semanticLabel: '用名字的第一个字',
                onTap: () => setState(() {
                  _avatarTouched = true;
                  _avatarId = null;
                }),
                child: Text(
                  _preview.initial,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: MemberAvatars.fallbackForeground(_preview),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AvatarChoice extends StatelessWidget {
  const _AvatarChoice({
    required this.selected,
    required this.bg,
    required this.fg,
    required this.semanticLabel,
    required this.onTap,
    this.icon,
    this.child,
  });

  final bool selected;
  final Color bg;
  final Color fg;
  final String semanticLabel;
  final VoidCallback onTap;
  final IconData? icon;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(16),
            border: selected
                ? Border.all(color: scheme.primary, width: 2.5)
                : Border.all(color: Colors.transparent, width: 2.5),
          ),
          alignment: Alignment.center,
          child: child ??
              Icon(icon, size: 28, color: fg),
        ),
      ),
    );
  }
}
