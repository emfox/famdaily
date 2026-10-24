import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/sync/sync_api.dart';
import '../../data/sync/sync_config.dart';
import '../../data/sync/sync_protocol.dart';
import '../../data/sync/sync_service.dart';

/// 同步设置页：配对、看状态、断开。
///
/// 三层信息，从上往下：
/// 1. **现在是什么状态**（未开启 / 刚刚同步 / 同步码失效）
/// 2. 我能做什么（配对、立刻同步、断开）
/// 3. 一屏讲清楚"这是什么、会出什么问题"（协议文档 §7 那几条）
///
/// 第 3 层不折叠、不放进"了解更多"：这套东西的已知缺陷里有"删除可能不生效"
/// 这种会让用户困惑的行为，藏起来等于骗人。
class SyncPage extends StatefulWidget {
  const SyncPage({
    required this.service,
    required this.config,
    required this.onPaired,
    this.apiFactory,
    super.key,
  });

  final SyncService service;
  final SyncConfigStore config;

  /// 配对成功后回调（外层据此刷新设置页那一行）。
  final Future<void> Function() onPaired;

  /// 造 API。测试里注入假传输，生产走默认实现。
  final SyncApi Function(Uri baseUrl)? apiFactory;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  SyncConfig? _cfg;
  SyncStatus _status = const SyncStatus();
  bool _loading = true;

  /// 正在用的假/真 API，断开时要 close 掉。
  SyncApi? _api;

  StreamSubscription<SyncStatus>? _sub;

  @override
  void initState() {
    super.initState();
    _status = widget.service.status;
    _sub = widget.service.stream.listen((s) {
      if (mounted) {
        setState(() => _status = s);
      }
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _api?.close();
    super.dispose();
  }

  SyncApi _newApi(Uri baseUrl) {
    final made = widget.apiFactory?.call(baseUrl) ??
        SyncApi(transport: HttpSyncTransport(), baseUrl: baseUrl);
    return made;
  }

  Future<void> _load() async {
    final cfg = await widget.config.load();
    if (!mounted) {
      return;
    }
    setState(() {
      _cfg = cfg;
      _loading = false;
    });
  }

  Future<void> _syncNow() async {
    await widget.service.syncNow(reason: 'manual');
    if (mounted) {
      await _load();
    }
  }

  Future<void> _openPairing() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PairPage(
          config: widget.config,
          service: widget.service,
          apiFactory: _newApi,
        ),
      ),
    );
    if (ok == true && mounted) {
      await _load();
      await widget.onPaired();
    }
  }

  Future<void> _disconnect() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('断开同步？'),
        content: const Text(
          '这台手机会忘掉同步码，**本机数据一条都不会删**。\n'
          '别的设备照常同步，想再加入要重新输一次同步码。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('算了'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (yes != true) {
      return;
    }
    await widget.config.clear(nowMs: DateTime.now().millisecondsSinceEpoch);
    widget.service.resetError();
    if (mounted) {
      await _load();
      await widget.onPaired();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cfg = _cfg;

    return Scaffold(
      appBar: AppBar(title: const Text('同步')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                _StatusCard(
                  configured: cfg != null,
                  status: _status,
                  familyId: cfg?.familyId,
                  onSync: _syncNow,
                  onRetry: () {
                    widget.service.resetError();
                    unawaited(_syncNow());
                  },
                ),
                if (cfg == null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    child: FilledButton.icon(
                      onPressed: () => unawaited(_openPairing()),
                      icon: const Icon(Icons.link),
                      label: const Text('输入同步码，和家人的手机连上'),
                    ),
                  )
                else ...[
                  const Divider(height: 24),
                  ListTile(
                    leading: const Icon(Icons.sync),
                    title: const Text('立刻同步一次'),
                    subtitle: const Text('平时会自动同步，这里只是手动催一下'),
                    enabled: !_status.isRunning,
                    onTap: _status.isRunning
                        ? null
                        : () => unawaited(_syncNow()),
                  ),
                  ListTile(
                    leading: const Icon(Icons.link_off),
                    title: const Text('断开同步'),
                    subtitle: const Text('只忘掉同步码，不删任何数据'),
                    onTap: () => unawaited(_disconnect()),
                  ),
                ],
                const Divider(height: 24),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text(
                    '同步怎么工作',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const _Explainer(),
              ],
            ),
    );
  }
}

/// 顶部那张状态卡。**未配平时不显示任何"红字"**，避免新用户第一眼就是警告。
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.configured,
    required this.status,
    required this.familyId,
    required this.onSync,
    required this.onRetry,
  });

  final bool configured;
  final SyncStatus status;
  final String? familyId;
  final Future<void> Function() onSync;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = status.outcome == SyncOutcome.failed;
    final scheme = theme.colorScheme;

    final (icon, title, detail) = switch (status.outcome) {
      _ when !configured => (
        Icons.cloud_off_outlined,
        '还没开启同步',
        '现在所有数据只在这台手机上。连上之后，家人的手机会看到同一份。',
      ),
      SyncOutcome.running => (
        Icons.sync,
        '正在同步…',
        '通常一两秒。网络不好时会自己重试。',
      ),
      SyncOutcome.failed => (
        Icons.error_outline,
        status.errorKind?.label ?? '同步失败',
        switch (status.errorKind) {
          SyncErrorKind.auth => '同步码已经不能用了，需要重新配一次对。',
          SyncErrorKind.protocol => '这台手机和服务端的版本对不上，先升级 App。',
          SyncErrorKind.network => '连不上服务端。会自己重试，不用管它。',
          _ => status.errorMessage ?? '',
        },
      ),
      SyncOutcome.partial => (
        Icons.warning_amber_outlined,
        '大部分同步好了',
        '有 ${status.rejects.length} 条内容被拒绝：${status.rejects.first.reason}',
      ),
      _ => (
        Icons.cloud_done_outlined,
        status.lastSuccessAtMs == null ? '已连接' : '已经是最新的',
        status.writtenRows > 0
            ? '这次接收了 ${status.writtenRows} 条改动'
            : (status.lastSuccessAtMs == null
                  ? '第一次同步还没跑过'
                  : '没有新内容'),
      ),
    };

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: failed
            ? scheme.errorContainer.withValues(alpha: 0.5)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: failed ? scheme.error : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: failed ? scheme.error : null,
                  ),
                ),
              ),
              // 失败时给一个"再试一次"：退避最长会等到 30 分钟，
              // 用户刚连上 WiFi 却要等半小时是不可接受的。
              if (failed)
                TextButton(onPressed: onRetry, child: const Text('再试')),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (configured && status.lastSuccessAtMs != null) ...[
            const SizedBox(height: 8),
            Text(
              status.shortLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 讲清楚"会出什么问题"。协议文档 §7 的用户版。
class _Explainer extends StatelessWidget {
  const _Explainer();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      height: 1.7,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• 每台手机都有自己的完整副本，断网照样能打卡。\n'
              '• 照片只留在拍它的那台手机上，不会同步。\n'
              '• 同一件事两边几乎同时改，以后改的为准。\n'
              '• 一台手机离线很久之后才联上，它的删除可能传不过去——'
              '这种情况下宁可多留一条，也不会丢数据。',
              style: style),
        ],
      ),
    );
  }
}

/// 配对页：输码 → 预览（"这是我家的谁谁谁"）→ 认领。
///
/// 中间那一步"预览"不是多余的：同步码是一串念不出来的字符，
/// 用户没办法从码本身判断"我输的是不是我家的码"。看到成员名才敢按下确认。
class PairPage extends StatefulWidget {
  const PairPage({
    required this.config,
    required this.service,
    required this.apiFactory,
    super.key,
  });

  final SyncConfigStore config;
  final SyncService service;
  final SyncApi Function(Uri baseUrl) apiFactory;

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final _urlCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();

  bool _busy = false;
  String? _error;
  PairPreview? _preview;

  SyncApi? _api;

  @override
  void initState() {
    super.initState();
    // 服务地址上次填过就带出来，用户只需改端口/域名的一部分。
    unawaited(_prefill());
  }

  Future<void> _prefill() async {
    final last = await widget.config.load();
    if (last != null && mounted) {
      _urlCtrl.text = last.baseUrl;
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _codeCtrl.dispose();
    _api?.close();
    super.dispose();
  }

  Uri? _parseUrl() {
    final raw = _urlCtrl.text.trim();
    if (raw.isEmpty) {
      return null;
    }
    final withScheme = raw.contains('://') ? raw : 'https://$raw';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    return uri;
  }

  /// 各步共用的错误兜底。把人话放在最前面，原始信息留在下面小字。
  String _describe(Object e) => switch (e) {
    SyncAuthException() => '同步码不对，或者已经用过了。再要一个新的。',
    SyncHttpException(:final statusCode) => '服务端出错了（$statusCode），'
        '过一会儿再试。',
    TransportException() => '连不上这个地址。检查一下网址，或者换个网络。',
    SyncFormatException() => '服务端返回的内容看不懂，可能是版本不一致。',
    _ => '没成功：$e',
  };

  Future<void> _previewCode() async {
    final url = _parseUrl();
    if (url == null) {
      setState(() => _error = '先填服务地址，比如 https://sync.example.com');
      return;
    }
    final code = normalizePairCode(_codeCtrl.text);
    if (code == null) {
      setState(
        () => _error = '同步码是 12 个字符（字母和数字，不含 0 1 I L O）。'
            '再对一遍纸上的码。',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _api?.close();
      _api = widget.apiFactory(url);
      final p = await _api!.preview(code);
      if (mounted) {
        setState(() {
          _preview = p;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _describe(e);
        });
      }
    }
  }

  Future<void> _claim() async {
    final url = _parseUrl();
    final code = normalizePairCode(_codeCtrl.text);
    if (url == null || code == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _api?.close();
      _api = widget.apiFactory(url);
      final result = await _api!.claim(
        code: code,
        deviceName: _deviceName(),
      );
      await widget.config.save(
        SyncConfig(
          baseUrl: url.toString(),
          token: result.token,
          deviceId: result.deviceId,
          familyId: result.familyId,
        ),
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      await widget.service.afterPairing();
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _describe(e);
        });
      }
    }
  }

  /// 设备名只用于"这台是哪台"，服务端不解析。
  String _deviceName() {
    // 没有 platform 包就别费劲：叫"这台手机"已经够用了。
    return '这台手机';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _preview;

    return Scaffold(
      appBar: AppBar(title: const Text('连上家人的手机')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        children: [
          Text(
            '在已经用起来的那台手机上：设置 → 同步 → 生成同步码，'
            '然后把码念给这台手机听。',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _urlCtrl,
            enabled: !_busy && preview == null,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '服务地址',
              hintText: 'https://sync.example.com',
              helperText: '同一家的手机填同一个地址',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _codeCtrl,
            enabled: !_busy && preview == null,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              // 只留字母数字和分隔符：用户从纸上抄的时候常带空格、连字符、
              // 甚至 `FAM-` 前缀。这些都在规范化里处理，输入框不必拦。
              FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z\- ]')),
              LengthLimitingTextInputFormatter(24),
            ],
            decoration: const InputDecoration(
              labelText: '同步码',
              hintText: 'FAM-XXXX-XXXX-XXXX',
              helperText: '大小写、空格、连字符都无所谓',
            ),
            onChanged: (_) {
              // 改了码就把预览丢掉：否则用户会看到"上一次的成员名"，
              // 然后对着错的人按确认。
              if (_preview != null) {
                setState(() => _preview = null);
              }
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 18,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          if (preview == null)
            FilledButton(
              onPressed: _busy ? null : () => unawaited(_previewCode()),
              child: Text(_busy ? '查一下…' : '下一步'),
            )
          else ...[
            Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('这个家里有：', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Text(
                      preview.memberNames.isEmpty
                          ? '（还没有成员）'
                          : preview.memberNames.join('、'),
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '看着对就确认。认错了也没关系——数据不会混，'
                      '断开重连一次就行。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        height: 1.5,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : () => unawaited(_claim()),
              child: Text(_busy ? '连接中…' : '是我们家，确认'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _preview = null),
              child: const Text('换个码'),
            ),
          ],
        ],
      ),
    );
  }
}
