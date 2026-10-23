import 'package:flutter/material.dart';

import '../../domain/model/checkin_row.dart';

/// 打卡的三种结果（供 UI 层选择）。
enum CheckinChoice {
  /// 做了，按时。只有在没超时的情况下才该出现。
  done,

  /// 做了，但当时忘了记 —— 记为补卡，算完成不算准时。
  makeup,

  /// 老实记一笔"没做"，这条就结案。
  skipped,
}

/// 漏卡的两个出口（ui-spec §1.2）。
///
/// **只有两个选项 + 一个取消。** 不提供"先不管"——
/// 什么都不点就等于没做，明天 0 点自动结案。
/// 这一条的用意是：产品不逼用户做假账，但也不让数据悬空。
Future<CheckinChoice?> showOverdueSheet(BuildContext context, CheckinRow row) {
  final theme = Theme.of(context);
  return showModalBottomSheet<CheckinChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(row.task.name, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '${_hhmm(row)} · 这件事最后怎么样？',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 20),
            _ChoiceCard(
              icon: Icons.check_circle_outline,
              title: '做了，只是当时忘了记',
              subtitle: '记为补卡 · 算完成不算准时',
              tone: _ChoiceTone.positive,
              onTap: () => Navigator.of(context).pop(CheckinChoice.makeup),
            ),
            const SizedBox(height: 10),
            _ChoiceCard(
              icon: Icons.close,
              title: '没做',
              subtitle: '老实记一笔，这条就结案',
              tone: _ChoiceTone.negative,
              onTap: () => Navigator.of(context).pop(CheckinChoice.skipped),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('算了，不改'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 打完卡后浮出「＋备注 ＋照片」（ui-spec §1：3 秒自动收起）。
///
/// P1 只做到"能记一笔文字备注"；照片在 P1 后半段接 image_picker 再做
/// （需求里照片只存本地、不同步网页，需要额外考虑存储与清理）。
Future<String?> showNoteSheet(BuildContext context, CheckinRow row) {
  final controller = TextEditingController();
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${row.task.name} · 记一句',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            minLines: 1,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              hintText: '比如：今天吃了两粒，有点反胃',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(controller.text),
                child: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

enum _ChoiceTone { positive, negative }

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tone,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final _ChoiceTone tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final positive = tone == _ChoiceTone.positive;
    final bg = positive
        ? scheme.primaryContainer.withValues(alpha: 0.5)
        : scheme.errorContainer.withValues(alpha: 0.35);
    final fg = positive ? scheme.primary : scheme.error;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: fg),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _hhmm(CheckinRow row) {
  final t = row.dueAt.time;
  return '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}
