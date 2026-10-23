import 'dart:convert';
import 'dart:io';

import 'package:famdaily/data/db/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

/// 导出建库 DDL 快照到 `drift_schemas/schema_v1.json`。
///
/// 用途：以后改表结构时，把上一版 DDL 拿出来对比，就知道"这次迁移该写什么"，
/// 也是给迁移测试 (drift_dev schema steps) 的输入。
///
/// 跑法：`flutter test test/data/schema_dump_test.dart`
void main() {
  test('导出当前 schema 的 DDL', () async {
    final db = AppDatabase.forTesting(openTestConnection());
    // 打开一次触发 onCreate，DDL 才落库。
    await db.customSelect('SELECT 1').get();

    final master = await db
        .customSelect(
          'SELECT type, name, sql FROM sqlite_master '
          "WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' "
          'ORDER BY type, name',
        )
        .get();

    final ddl = {
      'schemaVersion': db.schemaVersion,
      'objects': [
        for (final row in master)
          {
            'type': row.read<String>('type'),
            'name': row.read<String>('name'),
            'sql': row.read<String>('sql'),
          },
      ],
    };

    final dir = Directory('drift_schemas');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    File(
      '${dir.path}/schema_v1.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(ddl));

    // 六张表 + 五个索引，少一个都说明建库没跑完。
    final types = (ddl['objects']! as List).map((e) => (e as Map)['type']);
    expect(types.where((t) => t == 'table'), hasLength(6));
    expect(types.where((t) => t == 'index'), hasLength(5));

    await db.close();
  });
}
