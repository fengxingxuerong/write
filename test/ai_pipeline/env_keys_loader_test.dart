import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/services/env_keys_loader.dart';

/// `.env.local` 自动载入测试。
///
/// 全部用临时目录 + 假密钥，**绝不读仓库真实的 `.env.local`**——
/// 每个用例都显式传 `environment` / `searchDirs`，不依赖机器状态。
const String _envBody = '''
# 商汤三个工作区 Key（规划 / 润色+标题 / 审校）
NOVEL_KEY_SENSE_K1=sk-aaaaaaaa
NOVEL_KEY_SENSE_K2=sk-bbbbbbbb
NOVEL_KEY_SENSE_K3=sk-cccccccc
NOVEL_KEY_AMD=rc-dddddddd
''';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('inksmith_env_loader');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响测试结论。
    }
  });

  String sepJoin(List<String> parts) => parts.join(Platform.pathSeparator);

  group('EnvKeysLoader.load', () {
    test('显式 NOVEL_KEY_FILE 路径优先于搜索目录', () {
      File(sepJoin(<String>[tempDir.path, '.env.local']))
          .writeAsStringSync(_envBody);
      final File explicit =
          File(sepJoin(<String>[tempDir.path, 'custom.txt']));
      explicit.writeAsStringSync('NOVEL_KEY_SENSE_K1=sk-explicit\n');

      final Map<String, String> keys = EnvKeysLoader.load(
        environment: <String, String>{'NOVEL_KEY_FILE': explicit.path},
        searchDirs: <String>[tempDir.path],
      );
      expect(keys['NOVEL_KEY_SENSE_K1'], 'sk-explicit');
    });

    test('搜索目录本层命中：商汤三 Key + AMD 共 4 个', () {
      File(sepJoin(<String>[tempDir.path, '.env.local']))
          .writeAsStringSync(_envBody);

      final Map<String, String> keys = EnvKeysLoader.load(
        environment: <String, String>{},
        searchDirs: <String>[tempDir.path],
      );
      expect(keys, hasLength(4));
      expect(keys['NOVEL_KEY_SENSE_K1'], 'sk-aaaaaaaa');
      expect(keys['NOVEL_KEY_SENSE_K2'], 'sk-bbbbbbbb');
      expect(keys['NOVEL_KEY_SENSE_K3'], 'sk-cccccccc');
      expect(keys['NOVEL_KEY_AMD'], 'rc-dddddddd');
    });

    test('从深层子目录逐级向上找到仓库根的 .env.local', () {
      File(sepJoin(<String>[tempDir.path, '.env.local']))
          .writeAsStringSync(_envBody);
      // 模拟 build/windows/x64/runner/Release 的开发布局（目录不必真实存在）。
      final String deep = sepJoin(<String>[
        tempDir.path,
        'build',
        'windows',
        'x64',
        'runner',
        'Release',
      ]);

      final Map<String, String> keys = EnvKeysLoader.load(
        environment: <String, String>{},
        searchDirs: <String>[deep],
      );
      expect(keys['NOVEL_KEY_SENSE_K1'], 'sk-aaaaaaaa');
      expect(keys['NOVEL_KEY_AMD'], 'rc-dddddddd');
    });

    test('全部候选落空时返回空表且不抛异常', () {
      final Map<String, String> keys = EnvKeysLoader.load(
        environment: <String, String>{
          'NOVEL_KEY_FILE': sepJoin(<String>[tempDir.path, 'missing.env']),
        },
        searchDirs: <String>[sepJoin(<String>[tempDir.path, 'empty'])],
        maxWalkUp: 0, // 不向上找，保证结论与机器环境无关
      );
      expect(keys, isEmpty);
    });

    test('显式路径失效（文件不存在）时静默回退到搜索目录', () {
      File(sepJoin(<String>[tempDir.path, '.env.local']))
          .writeAsStringSync(_envBody);

      final Map<String, String> keys = EnvKeysLoader.load(
        environment: <String, String>{
          'NOVEL_KEY_FILE': sepJoin(<String>[tempDir.path, 'missing.env']),
        },
        searchDirs: <String>[tempDir.path],
        maxWalkUp: 0,
      );
      expect(keys['NOVEL_KEY_SENSE_K1'], 'sk-aaaaaaaa');
    });

    test('候选文件存在但解析不出密钥时视为落空（继续下一候选）', () {
      File(sepJoin(<String>[tempDir.path, '.env.local']))
          .writeAsStringSync('# 只有注释，没有密钥\n');

      final Map<String, String> keys = EnvKeysLoader.load(
        environment: <String, String>{},
        searchDirs: <String>[tempDir.path],
        maxWalkUp: 0,
      );
      expect(keys, isEmpty);
    });
  });
}
