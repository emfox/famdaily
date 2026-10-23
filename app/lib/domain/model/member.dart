/// 成员：账号下的一个人名 + 一个头像。**纯标签，不是账号、不能登录**（需求 2）。
library;

/// 头像的表示：预置头像 id 或"用名字自动生成的色块"。
sealed class Avatar {
  const Avatar();
}

/// 预置头像（图标库里挑一个），[id] 是图标名。
final class PresetAvatar extends Avatar {
  const PresetAvatar(this.id);

  final String id;

  @override
  bool operator ==(Object other) =>
      other is PresetAvatar && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 头像库索引（图标名 + 配色）。排序服务端无关，纯本地。
abstract final class AvatarLibrary {
  static const List<String> ids = [
    'grandpa',
    'grandma',
    'dad',
    'mom',
    'boy',
    'girl',
    'baby',
    'me',
    'cat',
    'dog',
    'flower',
    'ball',
  ];

  /// 名字首字色块的取色：把名字的哈希稳定映射到色板。
  static int colorIndexFor(String name) {
    if (name.isEmpty) {
      return 0;
    }
    var h = 0;
    for (final rune in name.runes) {
      h = (h * 31 + rune) & 0x7fffffff;
    }
    return h % 8;
  }
}

/// 一个家庭成员。
final class Member {
  const Member({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.avatarId,
    this.deletedAtMs,
  });

  final String id;
  final String name;

  /// 预置头像 id；null = 用名字首字色块。
  final String? avatarId;

  /// 排序，决定列表与打卡页顺序。
  final int sortOrder;

  final int createdAtMs;
  final int updatedAtMs;

  /// 软删除时间；非 null = 已删除（历史记录保留）。
  final int? deletedAtMs;

  bool get isDeleted => deletedAtMs != null;

  /// 是否是不可删除的"我"（默认自带一个，需求 2）。
  /// 由调用方结合"是否为首个成员"判断，这里只提供一个稳定 id 约定。
  static const String defaultSelfName = '我';

  /// 名字首字（用于色块兜底头像）。
  String get initial => name.isEmpty ? '?' : String.fromCharCode(name.runes.first);

  /// 色块配色索引。
  int get avatarColorIndex => AvatarLibrary.colorIndexFor(name);

  Member copyWith({
    String? name,
    String? avatarId,
    int? sortOrder,
    int? updatedAtMs,
    int? deletedAtMs,
  }) => Member(
    id: id,
    name: name ?? this.name,
    avatarId: avatarId ?? this.avatarId,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    deletedAtMs: deletedAtMs ?? this.deletedAtMs,
  );
}
