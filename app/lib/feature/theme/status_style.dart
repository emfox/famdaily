import 'package:flutter/material.dart';

import '../../domain/model/checkin_row.dart';

/// 五态的配色与描边。
///
/// 单独抽出来因为它是**产品语义**，不只是样式：什么时候该用红、
/// 什么时候必须用灰，是 ui-spec 里明确写死的规则（"没做"不许标红——
/// 标红等于惩罚用户，而这个 App 不评判）。
final class StatusStyle {
  const StatusStyle({
    required this.foreground,
    required this.background,
    required this.border,
  });

  final Color foreground;
  final Color background;
  final Color border;

  static StatusStyle of(CheckinVisual visual, ColorScheme scheme) {
    return switch (visual) {
      // 待做：干净的白，不打扰。
      CheckinVisual.pending => StatusStyle(
        foreground: scheme.primary,
        background: scheme.surface,
        border: scheme.outlineVariant.withValues(alpha: 0.5),
      ),
      // 已过时间：淡红底，让它在列表里"跳出来"但不刺眼。
      CheckinVisual.overdue => StatusStyle(
        foreground: scheme.error,
        background: scheme.errorContainer.withValues(alpha: 0.25),
        border: scheme.error.withValues(alpha: 0.25),
      ),
      // 准时：实心绿。
      CheckinVisual.doneOnTime => StatusStyle(
        foreground: scheme.primary,
        background: scheme.surface,
        border: scheme.primary.withValues(alpha: 0.18),
      ),
      // 补卡：空心绿（视觉上与准时区分，但不打折——它也是"做了"）。
      CheckinVisual.doneMakeup => StatusStyle(
        foreground: scheme.primary,
        background: scheme.surface,
        border: scheme.primary.withValues(alpha: 0.18),
      ),
      // 没做：米白 + 灰，整体淡化，不标红。
      //
      // 灰用 onSurfaceVariant 而不是 outline：outline 是给**描边**用的，
      // 它在浅色 surface 上只有 4.29:1，当正文色不达标（WCAG AA 要 4.5）。
      // 这个坑正是核查 e2e 规格 G-10 时量出来的。
      CheckinVisual.skipped => StatusStyle(
        foreground: scheme.onSurfaceVariant,
        background: scheme.surfaceContainerLow,
        border: scheme.outlineVariant.withValues(alpha: 0.4),
      ),
    };
  }
}
