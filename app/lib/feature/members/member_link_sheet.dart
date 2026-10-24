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
///
/// ## 为什么"作废"也放在这个弹窗里
///
/// 因为它是"我刚发出去的那条链接"的后续。单独做一个入口的话，用户要先想到
/// "去别处作废"，而那时屏幕上已经没有链接了，他得靠记忆确认废的是哪一条。
/// 更实际的是：没生成过链接的成员点那个入口只会得到 `revoked: false`，白跑一趟。
///
/// 完整的状态机与逐句文案见 `docs/member-link-management.zh_CN.md`。
class MemberLinkSheet extends StatefulWidget {
  const MemberLinkSheet({required this.sync, required this.member, super.key});

  final SyncService sync;
  final Member member;

  @override
  State<MemberLinkSheet> createState() => _MemberLinkSheetState();
}

enum _Phase {
  loading,
  ready,

  /// 二次确认通过了，请求飞出去了。
  ///
  /// 单独一个状态而不是复用 [loading]：`loading` 的文案是"正在生成…"、
  /// 按钮是「取消」。作废**不能取消**（请求已经发出去了），按钮必须全关。
  revoking,

  /// 真的废掉了一条。
  revoked,

  /// 服务端说"本来就没有有效链接"（`revoked: false`）。
  ///
  /// 和 [revoked] 分成两个枚举值，而不是一个值 + `bool _revokedSomething`：
  /// 用 bool 的话 `switch` 里每个分支都得额外读一下这个字段才知道该显示哪句
  /// 文案，漏一个分支就是"本来没链接"也被人说成"已作废"。枚举是穷举的，
  /// `switch` 少一个分支编译器直接报错。
  revokedNothing,

  /// 作废失败。**链接可能还在**，给「再试一次」。
  revokeFailed,

  error,
  unpaired,
}

class _MemberLinkSheetState extends State<MemberLinkSheet> {
  _Phase _phase = _Phase.loading;
  String? _url;
  String? _message;

  /// `revokeFailed` 态里给不给「再试一次」。
  ///
  /// 401/403 不给：鉴权层就拒了，重试同一个失效凭据不会有别的结果，
  /// 而按钮在那里会让人一直点。连不上 / 5xx 要给：那些是真的可能好了。
  bool _canRetryRevoke = true;

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

  /// 作废前的二次确认。
  ///
  /// 嵌套在链接弹窗之上。`barrierDismissible: false` 有两个理由：
  /// 1. 破坏性操作，点外面就"什么也不做"，这个"安全"是假的；
  /// 2. 更糟的是**点遮罩会关掉下面那层** —— 老人连点两下很常见，
  ///    第二下落在链接弹窗的遮罩上，屏幕上的 URL 就再也拿不回来了。
  Future<void> _confirmRevoke() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('作废${widget.member.name}的打卡链接？'),
        content: const Text(
          '作废之后，这条链接就永远打不开了，没法恢复。\n'
          '已经打开过这条链接的手机，会马上退出登录。\n'
          '已经打过的卡都在，一条不少。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('再想想'),
          ),
          // 不带危险色：项目惯例是危险色只出现在**入口**上（即 ready 态
          // 那个「作废这个链接」）。
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('作废'),
          ),
        ],
      ),
    );
    if (!(ok ?? false) || !mounted) {
      return;
    }
    await _revoke();
  }

  Future<void> _revoke() async {
    setState(() {
      _phase = _Phase.revoking;
      _message = null;
    });
    try {
      final revoked = await widget.sync.revokeMemberLink(widget.member.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _phase = revoked ? _Phase.revoked : _Phase.revokedNothing;
        // 终态不再显示 URL：服务端哈希已经清了，留在屏幕上等于暗示它还能用。
        _url = null;
      });
    } on SyncNotPairedException {
      _failRevoke('还没有同步过，没法作废。先去「设置 → 同步」配对吧。');
    } on SyncAuthException catch (e) {
      // 鉴权层就拒了，重试一万次也一样 —— 和 `_create` 里同一个判断。
      _failRevoke(
        '这台设备的同步凭据失效了（${e.statusCode}），作废没做成。'
        '去「设置 → 同步」重新配对之后再来。',
        canRetry: false,
      );
    } on TransportException catch (e) {
      _failRevoke('连不上服务：${e.message}。链接可能还没作废。');
    } on SyncHttpException catch (e) {
      // 404 = 这个成员在服务端已经不存在了（比如别的设备删掉并同步过）。
      // 他的链接也随之不可能再用 —— 这是**成功**，不是失败。
      // 这是唯一能从 HTTP 错误里推出"目的已达成"的分支。
      if (e.statusCode == 404) {
        if (!mounted) {
          return;
        }
        setState(() {
          _phase = _Phase.revokedNothing;
          _url = null;
        });
        return;
      }
      _failRevoke('服务端说：${e.message}。链接可能还没作废。');
    } catch (e) {
      _failRevoke('作废失败了：$e。链接可能还没作废。');
    }
  }

  /// 进失败态。
  ///
  /// 话术里的「可能」不能去掉：超时和连不上**无法区分**"请求没到服务端"和
  /// "服务端处理完了但响应没回来"。说"没作废"会让用户白折腾一遍，
  /// 说"已作废"会让用户以为安全了、而泄露的链接还能用。
  ///
  /// `_url` 一律保留：请求可能根本没发出去，用户还需要这条链接。
  void _failRevoke(String message, {bool canRetry = true}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _phase = _Phase.revokeFailed;
      _message = message;
      _canRetryRevoke = canRetry;
    });
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

  /// 只读展示链接的框。ready 与 revokeFailed 共用同一份样式。
  Widget _urlBox(ThemeData theme) {
    return Container(
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
    );
  }

  Widget _hint(ThemeData theme, String text) {
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(switch (_phase) {
        _Phase.revoked => '链接已作废',
        _Phase.revokedNothing => '没有链接可作废',
        _Phase.revokeFailed => '没作废成',
        _ => '给${widget.member.name}发打卡链接',
      }),
      // 逐值穷举，**不用 `||` 模式**：或模式在新加枚举值时不触发穷举检查，
      // 等于白拿一层保护。
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
        _Phase.revoking => const Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 14),
            Text('正在作废…'),
          ],
        ),
        _Phase.ready => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('把链接发给他，他在手机浏览器里点开就能打卡：', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            _urlBox(theme),
            const SizedBox(height: 12),
            _hint(
              theme,
              '这个链接只显示这一次，关掉就再也看不到了。'
              '重新生成会让旧的失效。',
            ),
            const SizedBox(height: 6),
            // 没有这一句，用户不知道那个按钮是干什么的，也不知道
            // "我已经把链接发出去了"是不是还有救。
            _hint(
              theme,
              '链接发给过别人（或者转发到群里）的话，'
              '可以用下面的「作废这个链接」马上关掉它。',
            ),
          ],
        ),
        // 真废掉了。不再显示链接本身。
        _Phase.revoked => Text(
          '${widget.member.name}的打卡链接已经作废，旧链接打不开了。\n'
          '他要用，得找你要一个新链接。',
          style: theme.textTheme.bodyMedium,
        ),
        // 本来就没有。**不说"已作废"**：那会让人以为"刚才有人废过一次"，
        // 于是开始怀疑家里其他人；也会让人以为"泄露的那条我已经关掉了"，
        // 而实际泄露的可能属于另一个成员。
        _Phase.revokedNothing => Text(
          '${widget.member.name}现在没有有效的打卡链接，不用作废。\n'
          '他要打卡的话，找你要一个新链接就行。',
          style: theme.textTheme.bodyMedium,
        ),
        _Phase.revokeFailed => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_message ?? '作废失败了', style: theme.textTheme.bodyMedium),
            if (_url != null) ...[
              const SizedBox(height: 10),
              _hint(theme, '确认之前，这条链接还是可以发的：'),
              const SizedBox(height: 8),
              _urlBox(theme),
            ],
          ],
        ),
        _Phase.error || _Phase.unpaired => Text(
          _message ?? '出错了',
          style: theme.textTheme.bodyMedium,
        ),
      },
      actions: switch (_phase) {
        _Phase.loading => [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
        // 请求已经飞出去，一个按钮都不给。给「取消」只会让人以为作废被撤销了。
        _Phase.revoking => const <Widget>[],
        // 终态：只有「知道了」。不给「重新生成一个」—— 用户刚意识到链接泄露，
        // 该做的是先止血，不是马上再造一条可能再次泄露的。
        _Phase.revoked || _Phase.revokedNothing => [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
        _Phase.ready => [
          TextButton(
            onPressed: _confirmRevoke,
            style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
            child: const Text('作废这个链接'),
          ),
          TextButton(onPressed: _copy, child: const Text('复制')),
          FilledButton(onPressed: _share, child: const Text('分享')),
        ],
        _Phase.revokeFailed => [
          if (_url != null) TextButton(onPressed: _copy, child: const Text('复制')),
          if (_canRetryRevoke)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          // 不能重试时把「知道了」升成主按钮：它是唯一出口，
          // 留个次要样式会让人以为还有别的路。
          if (_canRetryRevoke)
            FilledButton(onPressed: _revoke, child: const Text('再试一次'))
          else
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
        ],
        _Phase.error => [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
          FilledButton(onPressed: _create, child: const Text('再试一次')),
        ],
        _Phase.unpaired => [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      },
    );
  }
}
