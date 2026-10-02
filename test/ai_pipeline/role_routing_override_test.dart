import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/ai_pipeline/fixed_workflow_preset.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 角色路由覆盖（按角色换主模型）的行为护栏。
///
/// 覆盖这个能力的动机很实际：真实链路里模型换代极快——实测 NVIDIA
/// `z-ai/glm-5.2` 已 410 EOL、`stealth/ox-alpha` 更名 `z-ai/glm-5.3-flash`。
/// 硬编码的角色→模型映射必然跟不上，而「改代码重编译」对用户不可接受。
void main() {
  const Map<String, String> keys = <String, String>{
    'NOVEL_KEY_AMD': 'rc-test',
    'NOVEL_KEY_SENSE_K1': 'sk-k1',
    'NOVEL_KEY_SENSE_K2': 'sk-k2',
    'NOVEL_KEY_SENSE_K3': 'sk-k3',
  };

  group('parseOverrides：坏输入一律静默忽略', () {
    test('合法 JSON 解析出角色 → 覆盖字段', () {
      final Map<AiRole, Map<String, dynamic>> o =
          FixedWorkflowPreset.parseOverrides(
        '{"writer":{"model":"glm-5.3","temperature":0.9}}',
      );
      expect(o.keys.toList(), <AiRole>[AiRole.writer]);
      expect(o[AiRole.writer]!['model'], 'glm-5.3');
      expect(o[AiRole.writer]!['temperature'], 0.9);
    });

    test('坏 JSON / 非对象 / 空串都回退空表（不抛异常）', () {
      // 这段配置不该有能力把应用启动搞崩——用户手写 JSON 拼错是常态。
      expect(FixedWorkflowPreset.parseOverrides('not json'), isEmpty);
      expect(FixedWorkflowPreset.parseOverrides('{'), isEmpty);
      expect(FixedWorkflowPreset.parseOverrides('[1,2]'), isEmpty);
      expect(FixedWorkflowPreset.parseOverrides('"str"'), isEmpty);
      expect(FixedWorkflowPreset.parseOverrides(''), isEmpty);
      expect(FixedWorkflowPreset.parseOverrides('   '), isEmpty);
    });

    test('未知角色名被丢弃，不影响已知角色', () {
      final Map<AiRole, Map<String, dynamic>> o =
          FixedWorkflowPreset.parseOverrides(
        '{"writer":{"model":"a"},"nobody":{"model":"b"}}',
      );
      expect(o.keys.toList(), <AiRole>[AiRole.writer]);
    });

    test('值不是对象的条目被丢弃', () {
      expect(
        FixedWorkflowPreset.parseOverrides('{"writer":"glm-5.3"}'),
        isEmpty,
      );
    });
  });

  group('覆盖只改主位，备用链保持预设', () {
    test('model 覆盖只作用在链首位', () {
      final Map<AiRole, AiRoleConfig> base =
          FixedWorkflowPreset.roles(keys);
      final Map<AiRole, AiRoleConfig> routed = FixedWorkflowPreset.roles(
        keys,
        roleOverrides: <AiRole, Map<String, dynamic>>{
          AiRole.writer: <String, dynamic>{'model': 'glm-5.3'},
        },
      );
      expect(routed[AiRole.writer]!.llm.model, 'glm-5.3');
      // 未覆盖角色不受影响。
      expect(routed[AiRole.planner]!.llm.model, base[AiRole.planner]!.llm.model);
      // 备用链逐条保持不变——多级降级不能被一次换模型搞废。
      final List<String> baseFb = base[AiRole.writer]!.fallbacks
          .map((LlmConfig e) => e.model)
          .toList();
      final List<String> routedFb = routed[AiRole.writer]!.fallbacks
          .map((LlmConfig e) => e.model)
          .toList();
      expect(routedFb, baseFb);
    });

    test('temperature / maxTokens 覆盖生效', () {
      final Map<AiRole, AiRoleConfig> r = FixedWorkflowPreset.roles(
        keys,
        roleOverrides: <AiRole, Map<String, dynamic>>{
          AiRole.editor: <String, dynamic>{'temperature': 0.3, 'maxTokens': 8000},
        },
      );
      expect(r[AiRole.editor]!.llm.temperature, 0.3);
      expect(r[AiRole.editor]!.llm.maxTokens, 8000);
    });

    test('覆盖不改变密钥与端点（除非显式指定）', () {
      final Map<AiRole, AiRoleConfig> base =
          FixedWorkflowPreset.roles(keys);
      final Map<AiRole, AiRoleConfig> r = FixedWorkflowPreset.roles(
        keys,
        roleOverrides: <AiRole, Map<String, dynamic>>{
          AiRole.titler: <String, dynamic>{'model': 'x'},
        },
      );
      expect(r[AiRole.titler]!.llm.apiKey, base[AiRole.titler]!.llm.apiKey);
      expect(r[AiRole.titler]!.llm.baseUrl, base[AiRole.titler]!.llm.baseUrl);
    });

    test('空字符串字段被忽略（不把 model 清空成无模型端点）', () {
      final Map<AiRole, AiRoleConfig> base =
          FixedWorkflowPreset.roles(keys);
      final Map<AiRole, AiRoleConfig> r = FixedWorkflowPreset.roles(
        keys,
        roleOverrides: <AiRole, Map<String, dynamic>>{
          AiRole.writer: <String, dynamic>{'model': '  ', 'baseUrl': ''},
        },
      );
      expect(
        r[AiRole.writer]!.llm.model,
        base[AiRole.writer]!.llm.model,
        reason: '空白 model 不该覆盖掉预设模型',
      );
    });

    test('maxTokens<=0 被忽略', () {
      final Map<AiRole, AiRoleConfig> base =
          FixedWorkflowPreset.roles(keys);
      final Map<AiRole, AiRoleConfig> r = FixedWorkflowPreset.roles(
        keys,
        roleOverrides: <AiRole, Map<String, dynamic>>{
          AiRole.writer: <String, dynamic>{'maxTokens': 0},
        },
      );
      expect(r[AiRole.writer]!.llm.maxTokens, base[AiRole.writer]!.llm.maxTokens);
    });

    test('未知字段被忽略而不是让装配失败', () {
      final Map<AiRole, AiRoleConfig> base =
          FixedWorkflowPreset.roles(keys);
      final Map<AiRole, AiRoleConfig> r = FixedWorkflowPreset.roles(
        keys,
        roleOverrides: <AiRole, Map<String, dynamic>>{
          AiRole.writer: <String, dynamic>{'typo_field': 123},
        },
      );
      expect(
        r[AiRole.writer]!.llm.model,
        base[AiRole.writer]!.llm.model,
        reason: '拼错一个键不该让整个预设装配失败',
      );
    });
  });

  group('encodeOverrides 往返', () {
    test('序列化后能解析回等价结构', () {
      final Map<AiRole, Map<String, dynamic>> o = <AiRole, Map<String, dynamic>>{
        AiRole.writer: <String, dynamic>{'model': 'glm-5.3'},
        AiRole.planner: <String, dynamic>{'temperature': 0.9},
      };
      final Map<AiRole, Map<String, dynamic>> back =
          FixedWorkflowPreset.parseOverrides(
        FixedWorkflowPreset.encodeOverrides(o),
      );
      expect(back.keys.toSet(), o.keys.toSet());
      expect(back[AiRole.writer]!['model'], 'glm-5.3');
      expect(back[AiRole.planner]!['temperature'], 0.9);
    });

    test('空表序列化成 {}（合法的「无覆盖」）', () {
      expect(
        FixedWorkflowPreset.encodeOverrides(<AiRole, Map<String, dynamic>>{}),
        '{}',
      );
      expect(FixedWorkflowPreset.parseOverrides('{}'), isEmpty);
    });
  });
}