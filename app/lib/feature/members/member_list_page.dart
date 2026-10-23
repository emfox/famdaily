import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../domain/model/member.dart';
import 'member_avatar.dart';
import 'member_detail_page.dart';
import 'member_edit_page.dart';
import 'member_service.dart';

/// 成员列表（ui-spec §5.1）。
///
/// 排序用上移/下移按钮而不是纯拖拽：拖拽在长列表里落位很不精确，
/// 老人手上更容易"拖一半弹回去"。拖拽手势一并保留，谁顺手用谁。
class MemberListPage extends StatefulWidget {
  const MemberListPage({required this.service, super.key});

  final MemberService service;

  @override
  State<MemberListPage> createState() => _MemberListPageState();
}

class _MemberListPageState extends State<MemberListPage> {
  List<MemberSummary>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await widget.service.list();
    if (!mounted) {
      return;
    }
    setState(() => _rows = rows);
  }

  Future<void> _openEdit([Member? initial]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            MemberEditPage(service: widget.service, initial: initial),
      ),
    );
    if (saved ?? false) {
      await _load();
    }
  }

  Future<void> _openDetail(Member m) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            MemberDetailPage(service: widget.service, memberId: m.id),
      ),
    );
    if (changed ?? false) {
      await _load();
    }
  }

  Future<void> _move(int from, int to) async {
    final rows = _rows;
    if (rows == null) {
      return;
    }
    final ids = rows.map((r) => r.member.id).toList(growable: false);
    await widget.service.reorder(
      MemberService.moved(ids, from, to),
      nowMs: clock.now().millisecondsSinceEpoch,
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _rows;

    return Scaffold(
      appBar: AppBar(
        title: Text('成员', style: theme.textTheme.headlineSmall),
        actions: [
          TextButton.icon(
            onPressed: () => _openEdit(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新增'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: rows == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                const _Intro(),
                for (var i = 0; i < rows.length; i++)
                  _MemberRow(
                    summary: rows[i],
                    isFirst: i == 0,
                    isLast: i == rows.length - 1,
                    onTap: () => _openDetail(rows[i].member),
                    onMoveUp: () => _move(i, i - 1),
                    onMoveDown: () => _move(i, i + 1),
                  ),
                if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(40),
                    child: Text(
                      '还没有成员。先加一个「我」，再加家里人。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Text(
        '成员不用登录、没有密码。\n他们只是一个名字和一个头像，'
        '用来说明「这件事给谁做」。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
          height: 1.6,
        ),
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.summary,
    required this.isFirst,
    required this.isLast,
    required this.onTap,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final MemberSummary summary;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = summary.member;

    return ListTile(
      onTap: onTap,
      leading: MemberAvatar(member: m, size: 40),
      title: Text(m.name, style: theme.textTheme.titleMedium),
      subtitle: Text(
        summary.taskCountLabel,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '上移',
            onPressed: isFirst ? null : onMoveUp,
            icon: const Icon(Icons.keyboard_arrow_up, size: 20),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            tooltip: '下移',
            onPressed: isLast ? null : onMoveDown,
            icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
