import 'dart:io';

import 'package:novel_writer/ai_pipeline/fixed_workflow_preset.dart';

/// 从本机常见位置自动发现 `.env.local` 并解析密钥（纯本机文件读取，不触网）。
///
/// 存在意义：真 Key 永不入库是仓库铁律（CI 有 `scripts/test_secret_hygiene.py`
/// 扫描已入库文件的高熵密钥串），但让用户每次启动应用都手动
/// 「导入本机 API 配置」又太费事。本加载器只在**用户自己的机器**上按候选
/// 路径找 `.env.local`（被 `.gitignore` 的 `.env.*` 规则覆盖、从不入库），
/// 找到后走与手动导入**完全相同**的 `FixedWorkflowPreset.parseKeys` 解析
/// ——不另开第二条解析口径，避免两条路径漂移。
class EnvKeysLoader {
  const EnvKeysLoader._();

  /// 递归向上查找的目录层数上限。
  ///
  /// 覆盖典型开发/构建布局 `build/windows/x64/runner/Release`
  ///（仓库根在第 5 层）再留余量；到文件系统根即停。
  static const int _maxWalkUp = 8;

  /// 返回解析到的密钥映射（`NOVEL_KEY_*`）；全部候选落空时返回空表。
  ///
  /// 候选顺序：
  /// 1. 环境变量 `NOVEL_KEY_FILE` 指定的显式路径（最高优先，便于把密钥
  ///    文件放在非标准位置）；
  /// 2. [searchDirs]（缺省 = 当前工作目录 + 可执行文件所在目录）及其各级
  ///    祖先目录下的 `.env.local`，近者先试。
  ///
  /// 任何异常（文件不存在 / 无权限 / 编码坏）都吞掉并继续下一个候选——
  /// 自动发现只是便利路径，绝不允许它把页面加载搞崩。
  static Map<String, String> load({
    Map<String, String>? environment,
    List<String>? searchDirs,
    int maxWalkUp = _maxWalkUp,
  }) {
    final Map<String, String> env = environment ?? Platform.environment;
    final List<File> candidates = <File>[];
    final String? explicit = env['NOVEL_KEY_FILE']?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      candidates.add(File(explicit));
    }
    final List<String> roots = searchDirs ??
        <String>[
          Directory.current.path,
          File(Platform.resolvedExecutable).parent.path,
        ];
    for (final String root in roots) {
      candidates.addAll(_ancestorChain(root, maxWalkUp));
    }
    final Set<String> seen = <String>{};
    for (final File file in candidates) {
      try {
        if (!seen.add(file.absolute.path)) continue;
        if (!file.existsSync()) continue;
        final Map<String, String> keys =
            FixedWorkflowPreset.parseKeys(file.readAsStringSync());
        if (keys.isNotEmpty) return keys;
      } catch (_) {
        // 坏文件 / 无权限：静默换下一个候选。
      }
    }
    return <String, String>{};
  }

  /// 从 [startPath] 逐级向上收集 `.env.local` 候选（含本层，最多 [levels] 次上跳）。
  static List<File> _ancestorChain(String startPath, int levels) {
    final List<File> out = <File>[];
    try {
      Directory dir = Directory(startPath);
      for (int i = 0; i <= levels; i++) {
        out.add(File('${dir.path}${Platform.pathSeparator}.env.local'));
        final Directory parent = dir.parent;
        if (parent.path == dir.path) break; // 已到文件系统根
        dir = parent;
      }
    } catch (_) {
      // 非法路径：返回已收集的部分，由调用方按存在性过滤。
    }
    return out;
  }
}
