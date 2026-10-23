import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../domain/model/local_date.dart';
import '../../domain/model/member.dart';
import '../../domain/stats/stats.dart';
import 'member_avatar.dart';
import 'member_edit_page.dart';
import 'member_service.dart';

/// 成员详情（ui-spec §5.3）。
///
/// 只放三件事：他是谁、他有哪些活、"我不想要这个成员了"。
/// 「他的统计」直接内联成本月完成率，不跳独立页——点进来只为看一眼数字，
/// 再点一次跳转就是多余的。
class MemberDetailPage extends StatefulWidget {
  const MemberDetailPage({
    required this.service,
    required this.memberId,
    this.onOpenTasks,
    super.key,
  });

  final MemberService service;
  final String memberId;

  /// 点「他的打卡项」时回调；null 时该项置灰（详情页也能独立存在）。
  final ValueChanged<Member>? onOpenTasks;

  @override
  State<MemberDetailPage> createState() => _MemberDetailPageState();
}

class _MemberDetailPageState extends State<MemberDetailPage> {
  Member? _member;
  MemberSummary? _summary;
  StatsSummary? _stats;
  bool _dirty = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final member = await widget.service.find(widget.memberId);
    if (!mounted) {
      return;
    }
    if (member == null || member.isDeleted) {
      // 被别处删掉了（比如返回栈里还有一个旧页面）：直接退，别画空壳。
      Navigator.of(context).pop(_dirty);
      return;
    }
    final today = LocalDate.fromDateTime(clock.now());
    final rows = await widget.service.list();
    final mine = rows.where((r) => r.member.id == member.id).firstOrNull;
    final stats = await widget.service.monthStats(member.id, today: today);
    if (!mounted) {
      return;
    }
    setState(() {
      _member = member;
      _summary = mine;
      _stats = stats;
      _loading = false;
    });
  }

  Future<void> _edit() async {
    final m = _member;
    if (m == null) {
      return;
    }
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => MemberEditPage(service: widget.service, initial: m),
      ),
    );
    if (saved ?? false) {
      _dirty = true;
      await _load();
    }
  }

  Future<void> _delete() async {
    final m = _member;
    if (m == null) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${m.name}？'),
        content: const Text(
          '他的打卡记录会留在日历里，翻回去还能看到。\n'
          '只是以后不再出现在首页和新建项目里。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('再想想'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok ?? false) {
      await widget.service.remove(
        m.id,
        nowMs: clock.now().millisecondsSinceEpoch,
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = _member;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          Navigator.of(context).pop(_dirty);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text(''),
          actions: [
            IconButton(
              tooltip: '改名字 / 换头像',
              onPressed: _loading ? null : _edit,
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
        body: _loading || m == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  Center(child: MemberAvatar(member: m, size: 84)),
                  const SizedBox(height: 14),
                  Text(
                    m.name,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 6),
                  if (_summary != null && _stats != null)
                    Text(
                      MemberService.headline(_summary!, _stats!),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(height: 28),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.checklist_rtl),
                    title: const Text('他的打卡项'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _summary?.taskCountLabel ?? '',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const Icon(Icons.chevron_right, size: 18),
                      ],
                    ),
                    // 打卡项列表页还没做，先置灰——比点进去空页面诚实。
                    enabled: widget.onOpenTasks != null,
                    onTap: widget.onOpenTasks == null
                        ? null
                        : () => widget.onOpenTasks!(m),
                  ),
                  const ListTile(
                    leading: Icon(Icons.link),
                    title: Text('生成打卡链接'),
                    subtitle: Text('让成员自己在手机上打，下一版'),
                    trailing: Icon(Icons.chevron_right, size: 18),
                    enabled: false,
                  ),                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(
                      Icons.delete_outline,
                      color: theme.colorScheme.error,
                    ),
                    title: Text(
                      '删除这个成员',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                    onTap: _delete,
                  ),
                ],
              ),
      ),
    );
  }
}
