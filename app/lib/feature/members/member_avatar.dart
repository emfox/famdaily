/// 成员头像：预置图标 or 名字首字 + 稳定色块。
///
/// 从 `today_page.dart` 里抽出来的：成员页、编辑页、选择器三处都要用，
/// 再让它们互相 import 一个页面文件就乱套了。
library;

import 'package:flutter/material.dart';

import '../../domain/model/member.dart';
import 'member_service.dart';

class MemberAvatar extends StatelessWidget {
  const MemberAvatar({
    required this.member,
    this.size = 32,
    this.overrideAvatarId,
    super.key,
  });

  final Member member;
  final double size;

  /// 预览用：编辑页选头像时还没落库，先拿这个 id 画。
  ///
  /// `null` = 用成员自己的；传空串 = 强制走首字兜底。
  final String? overrideAvatarId;

  @override
  Widget build(BuildContext context) {
    final id = overrideAvatarId ?? member.avatarId;
    final option = MemberAvatars.find(id);

    if (option != null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: option.bg,
          borderRadius: BorderRadius.circular(size * 0.32),
        ),
        alignment: Alignment.center,
        child: Icon(
          option.icon,
          size: size * 0.58,
          color: option.fg,
        ),
      );
    }

    // 首字兜底：底色由名字哈希稳定算出，同一个人永远同一个色。
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: MemberAvatars.fallbackColor(member),
        borderRadius: BorderRadius.circular(size * 0.32),
      ),
      alignment: Alignment.center,
      child: Text(
        member.initial,
        style: TextStyle(
          fontSize: size * 0.44,
          fontWeight: FontWeight.w600,
          color: MemberAvatars.fallbackForeground(member),
        ),
      ),
    );
  }
}
