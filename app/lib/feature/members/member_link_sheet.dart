import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/sync/sync_api.dart';
import '../../data/sync/sync_service.dart';
import '../../domain/model/member.dart';

/// 「发打卡链接」弹窗。
///
/// ## 为什么是弹窗，不是独立页面
///
/// 这个动作的全过程只有三秒：点一下 → 链接出来 → 复制/分享 → 关掉。
/// 做成页面要进出两次，而且用户会在"链接生成成功但没记住"之后按返回，
/// 于是链接就没了 —— 服务端存的是哈希，再也找不回来。
/// 弹窗关掉就等于放弃，语义更诚实。
///
/// ## 链接只显示一次
///
/// 服务端 `members.web_token_hash` 只有哈希，**明文 token 只在响应里出现
/// 这一次**。所以这里绝不能"存下来下次再显示"：存下来的那份和哈希对不上，
/// 表现是"链接打不开"，而且完全没有办法自我诊断。
/// 重新生成会顶掉旧的（一个成员最多一条有效链接），这一点必须在界面上说清楚。
class MemberLinkSheet extends StatefulWidget {
  const MemberLinkSheet({required this.sync, required this.member, super.key});

  final SyncService sync;
  final Member member;

  @override
  State<MemberLinkSheet> createState() => _MemberLinkSheetState();
}

enum _Phase { loading, ready, error, unpaired }

class _MemberLinkSheetState extends State<MemberLinkSheet> {
  _Phase _phase = _Phase.loading;
  String? _url;
  String? _message;

  @override
  void initState() {
    super.initState();
    _create();
  }

  Future<void> _create() async {
    setState(() {
      _phase = _Phase.loading;
      _message = null;
    });
    try {
      final r = await widget.sync.createMemberLink(widget.member.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _url = r.url;
        _phase = _Phase.ready;
      });
    } on SyncNotPairedException {
      if (!mounted) {
        return;
      }
      setState(() {
        _phase = _Phase.unpaired;
        _message = '还没有同步过，链接需要服务端生成。先去「设置 → 同步」配对吧。';
      });
    } on SyncAuthException catch (e) {
      if (!mounted) {
        return;
      }
      // 401/403：设备凭据失效。重新生成链接不会有任何帮助，得重新配对。
      setState(() {
        _phase = _Phase.unpaired;
        _message =
            '这台设备的同步凭据失效了（${e.statusCode}）。'
            '去「设置 → 同步」重新配对之后再来。';
      });
    } on TransportException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _phase = _Phase.error;
        _message = '连不上服务：${e.message}';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _phase = _Phase.error;
        _message = '生成失败了：$e';
      });
    }
  }

  Future<void> _copy() async {
    final url = _url;
    if (url == null) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('链接已复制，粘贴到微信里发给他')));
  }

  Future<void> _share() async {
    final url = _url;
    if (url == null) {
      return;
    }
    await SharePlus.instance.share(
      ShareParams(
        text: '${widget.member.name}，这是你的打卡链接，点开就能打卡：\n$url',
        subject: '打卡链接',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('给${widget.member.name}发打卡链接'),
      content: switch (_phase) {
        _Phase.loading => const Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 14),
            Text('正在生成…'),
          ],
        ),
        _Phase.ready => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('把链接发给他，他在手机浏览器里点开就能打卡：', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              // 可选中：有人习惯长按自己复制。链接很长，这里只显示两行。
              child: SelectableText(
                _url ?? '',
                maxLines: 2,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '这个链接只显示这一次，关掉就再也看不到了。'
              '重新生成会让旧的失效。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        _Phase.error || _Phase.unpaired => Text(
          _message ?? '出错了',
          style: theme.textTheme.bodyMedium,
        ),
      },
      actions: switch (_phase) {
        _Phase.ready => [
          TextButton(onPressed: _copy, child: const Text('复制')),
          FilledButton(onPressed: _share, child: const Text('分享')),
        ],
        _Phase.error || _Phase.unpaired => [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
          if (_phase == _Phase.error)
            FilledButton(onPressed: _create, child: const Text('再试一次')),
        ],
        _Phase.loading => [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      },
    );
  }
}
