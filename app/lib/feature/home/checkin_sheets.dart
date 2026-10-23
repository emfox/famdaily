import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/photo/photo_store.dart';

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
                color: theme.colorScheme.onSurfaceVariant,
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

/// 一张刚拍/选好的照片（还没落盘）。
final class PendingPhoto {
  const PendingPhoto({required this.bytes});

  final Uint8List bytes;
}

/// 打完卡后浮出的「记一句 / 加张照片」（ui-spec §1）。
///
/// 返回 null = 用户什么都没填，直接收起（这是**正常**路径，不是取消）。
/// 备注和照片都在这一个弹层里：分开两次弹，第二次没人会点。
///
/// 照片在这里**只拿到字节、还没落盘**——落盘需要 IO，交给调用方在
/// 关闭弹层之后做，弹层里不做异步副作用（关闭动画会和 IO 抢帧）。
Future<CheckinExtras?> showNoteSheet(
  BuildContext context,
  CheckinRow row, {
  PhotoPicker? picker,
}) {
  return showModalBottomSheet<CheckinExtras>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _ExtrasSheet(row: row, picker: picker),
  );
}

/// 弹层里填的东西。
final class CheckinExtras {
  const CheckinExtras({this.note, this.photo});

  final String? note;
  final PendingPhoto? photo;

  bool get isEmpty => (note == null || note!.isEmpty) && photo == null;
}

class _ExtrasSheet extends StatefulWidget {
  const _ExtrasSheet({required this.row, this.picker});

  final CheckinRow row;
  final PhotoPicker? picker;

  @override
  State<_ExtrasSheet> createState() => _ExtrasSheetState();
}

class _ExtrasSheetState extends State<_ExtrasSheet> {
  final TextEditingController _note = TextEditingController();
  Uint8List? _photo;
  String? _photoError;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pick(PhotoSource source) async {
    final picker = widget.picker;
    if (picker == null) {
      return;
    }
    try {
      final bytes = await picker.pick(source);
      if (!mounted) {
        return;
      }
      if (bytes == null) {
        return; // 用户取消，什么也不说。
      }
      setState(() {
        _photo = bytes;
        _photoError = null;
      });
    } on Exception catch (e) {
      if (mounted) {
        // 相机不可用 / 没给权限，都落到这里。说清楚"可以改用相册"，
        // 而不是甩一句技术错误。
        setState(() => _photoError = '打不开相机或相册（$e）。可以先把照片存到相册里再选。');
      }
    }
  }

  void _submit() {
    final text = _note.text.trim();
    Navigator.of(context).pop(
      CheckinExtras(
        note: text.isEmpty ? null : text,
        photo: _photo == null ? null : PendingPhoto(bytes: _photo!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canPick = widget.picker != null;

    return Padding(
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
            '${widget.row.task.name} · 记一句',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            autofocus: true,
            maxLines: 3,
            minLines: 1,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              hintText: '比如：今天吃了两粒，有点反胃',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (canPick) ...[
            const SizedBox(height: 12),
            if (_photo != null)
              _PhotoPreview(
                bytes: _photo!,
                onRemove: () => setState(() => _photo = null),
              )
            else
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _pick(PhotoSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined, size: 18),
                    label: const Text('拍一张'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => _pick(PhotoSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: const Text('从相册选'),
                  ),
                ],
              ),
            if (_photoError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _photoError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('不用了'),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _submit, child: const Text('保存')),
            ],
          ),
        ],
      ),
    );
  }
}

/// 已选照片的预览 + 去脏图。
///
/// 用 `Image.memory` 而不是先把文件写盘再读：这一张还没落盘，
/// 先落盘再删会留下一堆没人管的临时文件。
class _PhotoPreview extends StatelessWidget {
  const _PhotoPreview({required this.bytes, required this.onRemove});

  final Uint8List bytes;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            bytes,
            height: 120,
            width: double.infinity,
            fit: BoxFit.cover,
            // 内存里已经是降采样过的小图，这里再限制一下 decode 尺寸，
            // 免得在低端机上解码一次就掉帧。
            cacheHeight: 360,
            errorBuilder: (_, _, _) => Container(
              height: 120,
              alignment: Alignment.center,
              color: scheme.surfaceContainerHighest,
              child: Text('这张图读不出来', style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          ),
        ),
        Positioned(
          top: 6,
          right: 6,
          child: Material(
            color: scheme.surface.withValues(alpha: 0.85),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onRemove,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 16),
              ),
            ),
          ),
        ),
      ],
    );
  }
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
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
