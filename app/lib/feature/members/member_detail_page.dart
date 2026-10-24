import 'package:flutter/material.dart';

import '../../data/sync/sync_service.dart';
import '../../domain/model/local_date.dart';
import '../../domain/model/member.dart';
import '../../domain/stats/stats.dart';
import 'member_avatar.dart';
import 'member_edit_page.dart';
import 'member_link_sheet.dart';
import 'member_service.dart';
import '../../app/test_clock.dart';

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
    this.sync,
    super.key,
  });

  final MemberService service;
  final String memberId;

  /// 点「他的打卡项」时回调；null 时该项置灰（详情页也能独立存在）。
  final ValueChanged<Member>? onOpenTasks;

  /// 同步服务。为 null 时「生成打卡链接」会说明"还没配对"。
  ///
  /// 做成可空而不是 required：详情页在 Widget 测试里被单独构造过很多次，
  /// 为了一个新功能让所有测试都去造一个 SyncService 不划算，而且那些测试
  /// 本来就不关心同步。
  final SyncService? sync;

  @override
  State<MemberDetailPage> createState() => _MemberDetailPageState();
}

class _MemberDetailPageState extends State<MemberDetailPage> {
  Member? _member;
  MemberSummary? _summary;
  StatsSummary? _stats;
  bool _dirty = false;
  bool _loading = true;

  /// 配没配对。只影响「生成打卡链接」的副标题文案。
  ///
  /// **必须是异步问出来的**：`widget.sync != null` 只说明"装配时给了服务"，
  /// 而 `AppServices.sync` 是永远存在的（没配对时它只是什么都不做）。
  /// 第一版就写成了 `widget.sync != null`，结果是**没配对的人看到
  /// "让成员自己在手机浏览器里打"**，点进去才被拒 —— 先给希望再拒绝。
  ///
  /// `null` = 还没问完。这时副标题留空，不先显示一句话再改掉。
  bool? _paired;

  @override
  void initState() {
    super.initState();
    _load();
    _loadPaired();
  }

  Future<void> _loadPaired() async {
    final sync = widget.sync;
    if (sync == null) {
      if (mounted) setState(() => _paired = false);
      return;
    }
    final paired = await sync.isPaired();
    if (mounted) setState(() => _paired = paired);
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
    final today = LocalDate.fromDateTime(appNow());
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
      await widget.service.remove(m.id, nowMs: appNow().millisecondsSinceEpoch);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _openLinkSheet() async {
    final m = _member;
    if (m == null) {
      return;
    }
    final sync = widget.sync;
    if (sync == null) {
      // 装配时没给 SyncService（只可能出现在测试里）：明确说一句，
      // 而不是弹一个空弹窗或者什么都不发生。
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('同步还没启用，没法生成链接')));
      return;
    }
    await showDialog<void>(
      context: context,
      // 点遮罩不关。
      //
      // 加「作废这个链接」之前，误触遮罩只是"白点了一次"；现在代价变了：
      // 用户想"先复制，再去作废"却先把弹窗关掉，URL 就再也拿不回来了
      // （服务端只存哈希），只能重新生成 —— 而重新生成会把**他本来不想废的
      // 那条也顶掉**。为了一个误触，赔上两条链接。
      barrierDismissible: false,
      builder: (_) => MemberLinkSheet(sync: sync, member: m),
    );
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
                  ListTile(
                    leading: const Icon(Icons.link),
                    title: const Text('生成打卡链接'),
                    subtitle: Text(switch (_paired) {
                      true => '让成员自己在手机浏览器里打',
                      false => '需要先在「设置 → 同步」里配对',
                      // 还没问完（读 settings 表是异步的）：留空。
                      // 先显示一句再改掉，比晚半拍出现更让人困惑。
                      null => '',
                    }),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    // 没配对时**不置灰**，而是点进去说明原因。
                    // 置灰在这里是有害的：老人只会看到一行灰字，不知道自己
                    // 该做什么；而真正的原因（要先配对）在另一个页面里。
                    enabled: !_loading,
                    onTap: _loading ? null : _openLinkSheet,
                  ),
                  const SizedBox(height: 12),
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
