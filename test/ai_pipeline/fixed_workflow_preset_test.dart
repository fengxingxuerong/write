import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/fixed_workflow_preset.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';

/// 固定的「API → 角色」装配测试（用假密钥，不含真实凭据）。
///
/// 样本格式对齐用户提供的配置清单：Base URL / 模型名 / API Key 混排。
const String _sample = '''
Base URL https://developer.amd.com.cn/radeon/api/v1
Model DeepSeek-V4-Flash
API Key rc-0000000000000000000000000000000000000000000000

https://token.sensenova.cn/v1/chat/completions
deepseek-v4-flash
sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sk-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
sk-cccccccccccccccccccccccccccccccc

Base URL https://openrouter.ai/api/v1
API Key sk-or-v1-ddddddddddddddddddddddddddddddddddddddddddddddddddd
模型 stealth/ox-alpha

nvapi-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
''';

void main() {
  group('FixedWorkflowPreset.parseKeys', () {
    test('识别混排清单里的全部密钥（含 sense 三个独立 Key）', () {
      final Map<String, String> keys = FixedWorkflowPreset.parseKeys(_sample);
      expect(keys['NOVEL_KEY_AMD'], startsWith('rc-'));
      expect(keys['NOVEL_KEY_SENSE_K1'], 'sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
      expect(keys['NOVEL_KEY_SENSE_K2'], 'sk-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
      expect(keys['NOVEL_KEY_SENSE_K3'], 'sk-cccccccccccccccccccccccccccccccc');
      expect(keys['NOVEL_KEY_NVIDIA'], startsWith('nvapi-'));
      expect(keys['NOVEL_KEY_OPENROUTER'], startsWith('sk-or-v1-'));
      // OpenRouter 的 sk-or-v1- 不能被误当成 SenseNova 的 sk-。
      expect(keys.values.where((String v) => v.startsWith('sk-or-v1-')),
          hasLength(1));
    });

    test('.env.local 的 KEY=VALUE 形式同样识别', () {
      final Map<String, String> keys = FixedWorkflowPreset.parseKeys(
        '# 注释\nNOVEL_KEY_AMD=rc-xyz\nNOVEL_KEY_SENSE_K1=sk-p\nNOVEL_KEY_NVIDIA=nvapi-q\n',
      );
      expect(keys, hasLength(3));
      expect(keys['NOVEL_KEY_AMD'], 'rc-xyz');
    });

    test('没有密钥时返回空表', () {
      expect(FixedWorkflowPreset.parseKeys('Base URL\n模型名\n'), isEmpty);
    });

    test('NOVEL_KEY_FILE 不会被当成密钥（前缀匹配陷阱）', () {
      expect(FixedWorkflowPreset.knownEnvKeys,
          isNot(contains('NOVEL_KEY_FILE')));
      expect(FixedWorkflowPreset.knownEnvKeys, hasLength(6));
    });
  });

  group('FixedWorkflowPreset.roles', () {
    test('五岗位各自拿到主 + 备链，主力为已验证端点', () {
      final Map<AiRole, AiRoleConfig> roles =
          FixedWorkflowPreset.roles(FixedWorkflowPreset.parseKeys(_sample));
      expect(roles.keys, containsAll(AiRole.values));

      // 写手、规划官和审校都先走 AMD；SenseNova 作为备用。
      expect(roles[AiRole.writer]!.llm.model, 'DeepSeek-V4-Flash');
      expect(roles[AiRole.writer]!.llm.baseUrl, contains('developer.amd.com.cn'));
      expect(roles[AiRole.writer]!.fallbacks, isNotEmpty);
      expect(roles[AiRole.planner]!.llm.baseUrl, contains('developer.amd.com.cn'));
      expect(roles[AiRole.verifier]!.llm.temperature, 0.2);

      // 2026-09-22 全端点实测定稿：规划/审校主力 glm-5.2（需 temp=1.0），
      // 编辑主力 kimi-k3，写手备选为 K2 的 deepseek-v4-flash。
      expect(roles[AiRole.planner]!.llm.model, 'DeepSeek-V4-Flash');
      expect(roles[AiRole.planner]!.llm.temperature, 1.0);
      expect(roles[AiRole.editor]!.llm.model, 'kimi-k3');
      expect(roles[AiRole.verifier]!.llm.model, 'DeepSeek-V4-Flash');
      expect(roles[AiRole.writer]!.fallbacks.first.model, 'deepseek-v4-flash');

      // 标题官复用第 3 个 Key，避免与策划/编辑抢同一配额。
      expect(roles[AiRole.titler]!.llm.apiKey, 'sk-cccccccccccccccccccccccccccccccc');
      expect(roles[AiRole.editor]!.llm.apiKey, 'sk-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
    });

    test('默认不把未实测端点放进链里', () {
      final Map<AiRole, AiRoleConfig> roles =
          FixedWorkflowPreset.roles(FixedWorkflowPreset.parseKeys(_sample));
      for (final AiRoleConfig c in roles.values) {
        for (final String url in c.chain.map((e) => e.baseUrl)) {
          expect(url, isNot(contains('openrouter')));
          expect(url, isNot(contains('nvidia')));
        }
      }
    });

    test('显式开启后，未实测端点仅作链尾兜底', () {
      final Map<AiRole, AiRoleConfig> roles = FixedWorkflowPreset.roles(
        FixedWorkflowPreset.parseKeys(_sample),
        includeCandidates: true,
      );
      final AiRoleConfig verifier = roles[AiRole.verifier]!;
      expect(verifier.chain.length, greaterThan(2));
      expect(verifier.chain.last.baseUrl, anyOf(
          contains('openrouter'), contains('nvidia')));
      // 主力不受候选影响。
      expect(verifier.llm.baseUrl, contains('developer.amd.com.cn'));
    });

    test('链内不出现重复端点', () {
      final Map<AiRole, AiRoleConfig> roles = FixedWorkflowPreset.roles(
        FixedWorkflowPreset.parseKeys(_sample),
        includeCandidates: true,
      );
      for (final AiRoleConfig c in roles.values) {
        final List<String> ids = c.chain
            .map((e) => '${e.baseUrl}|${e.model}|${e.apiKey}')
            .toList();
        expect(ids.toSet(), hasLength(ids.length),
            reason: '${c.role.label} 链上有重复端点');
      }
    });

    test('只有 AMD 一个密钥时，五岗位仍可用（链退化为单端点）', () {
      final Map<AiRole, AiRoleConfig> roles =
          FixedWorkflowPreset.roles(<String, String>{
        'NOVEL_KEY_AMD': 'rc-only0000000000000000000000000000000000000000',
      });
      for (final AiRoleConfig c in roles.values) {
        expect(c.llm.isConfigured, isTrue, reason: '${c.role.label} 未配置');
        expect(c.chain, hasLength(1));
      }
    });

    test('完全无密钥时不产生可用配置（由 UI 提示补填）', () {
      final Map<AiRole, AiRoleConfig> roles =
          FixedWorkflowPreset.roles(<String, String>{});
      for (final AiRoleConfig c in roles.values) {
        expect(c.llm.isConfigured, isFalse);
      }
    });
  });
}