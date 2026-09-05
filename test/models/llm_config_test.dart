import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/models/llm_config.dart';

/// LlmConfig 模型 + LlmSettingsRepository 单元测试
///
/// 覆盖：序列化/反序列化、isConfigured 各种场景、本地 URL 判断、LlmSettingsRepository 原子读写。

void main() {
  group('LlmConfig 默认值', () {
    test('默认值为 Ollama 本地配置', () {
      const config = LlmConfig();
      expect(config.provider, LlmProvider.ollama);
      expect(config.model, 'qwen2.5:7b');
      expect(config.apiKey, '');
      expect(config.baseUrl, '');
      expect(config.maxTokens, 8192);
      expect(config.temperature, 0.8);
    });
  });

  group('LlmConfig.isConfigured', () {
    test('模型为空时未配置', () {
      const config = LlmConfig(model: '');
      expect(config.isConfigured, isFalse);
    });

    test('模型仅空白字符时未配置', () {
      const config = LlmConfig(model: '   ');
      expect(config.isConfigured, isFalse);
    });

    test('Ollama 有 baseUrl 时己配置', () {
      const config = LlmConfig(
        provider: LlmProvider.ollama,
        baseUrl: 'http://localhost:11434',
      );
      expect(config.isConfigured, isTrue);
    });

    test('Ollama 无 baseUrl 时未配置', () {
      const config = LlmConfig(provider: LlmProvider.ollama);
      expect(config.isConfigured, isFalse);
    });

    test('OpenAI 兼容 + 本地地址免 Key', () {
      const config = LlmConfig(
        provider: LlmProvider.openaiCompatible,
        baseUrl: 'http://localhost:8080/v1',
        apiKey: '',
      );
      expect(config.isConfigured, isTrue);
    });

    test('OpenAI 兼容 + 127.0.0.1 免 Key', () {
      const config = LlmConfig(
        provider: LlmProvider.openaiCompatible,
        baseUrl: 'http://127.0.0.1:8080/v1',
        apiKey: '',
      );
      expect(config.isConfigured, isTrue);
    });

    test('OpenAI 兼容 + 远程地址需要 Key', () {
      const config = LlmConfig(
        provider: LlmProvider.openaiCompatible,
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: '',
      );
      expect(config.isConfigured, isFalse);
    });

    test('OpenAI 兼容 + 远程地址有 Key 时己配置', () {
      const config = LlmConfig(
        provider: LlmProvider.openaiCompatible,
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'sk-xxx',
      );
      expect(config.isConfigured, isTrue);
    });

    test('OpenAI 兼容无 baseUrl 时未配置', () {
      const config = LlmConfig(
        provider: LlmProvider.openaiCompatible,
        apiKey: 'sk-xxx',
      );
      expect(config.isConfigured, isFalse);
    });
  });

  group('LlmConfig.isLocal', () {
    test('localhost 为本地', () {
      const config = LlmConfig(baseUrl: 'http://localhost:11434');
      expect(config.isLocal, isTrue);
    });

    test('127.0.0.1 为本地', () {
      const config = LlmConfig(baseUrl: 'http://127.0.0.1:8080');
      expect(config.isLocal, isTrue);
    });

    test('0.0.0.0 为本地', () {
      const config = LlmConfig(baseUrl: 'http://0.0.0.0:8080');
      expect(config.isLocal, isTrue);
    });

    test('远程地址非本地', () {
      const config = LlmConfig(baseUrl: 'https://api.deepseek.com/v1');
      expect(config.isLocal, isFalse);
    });
  });

  group('LlmConfig.label', () {
    test('Ollama 显示本地', () {
      const config = LlmConfig(model: 'qwen2.5:7b');
      expect(config.label, 'Ollama 本地 · qwen2.5:7b');
    });

    test('OpenAI 兼容显示云端', () {
      const config = LlmConfig(
        provider: LlmProvider.openaiCompatible,
        model: 'deepseek-chat',
      );
      expect(config.label, '云端 API · deepseek-chat');
    });
  });

  group('LlmConfig 序列化', () {
    test('toJson 包含所有字段', () {
      const config = LlmConfig(
        provider: LlmProvider.openaiCompatible,
        model: 'deepseek-chat',
        apiKey: 'sk-xxx',
        baseUrl: 'https://api.deepseek.com/v1',
        maxTokens: 4096,
        temperature: 0.7,
      );
      final json = config.toJson();
      expect(json['provider'], 'openaiCompatible');
      expect(json['model'], 'deepseek-chat');
      expect(json['apiKey'], 'sk-xxx');
      expect(json['baseUrl'], 'https://api.deepseek.com/v1');
      expect(json['maxTokens'], 4096);
      expect(json['temperature'], 0.7);
    });

    test('fromJson 完整字段', () {
      final json = {
        'provider': 'ollama',
        'model': 'llama3',
        'apiKey': '',
        'baseUrl': 'http://localhost:11434',
        'maxTokens': 2048,
        'temperature': 0.5,
      };
      final config = LlmConfig.fromJson(json);
      expect(config.provider, LlmProvider.ollama);
      expect(config.model, 'llama3');
      expect(config.maxTokens, 2048);
      expect(config.temperature, 0.5);
    });

    test('fromJson 缺失字段使用默认值', () {
      final config = LlmConfig.fromJson(<String, dynamic>{});
      expect(config.provider, LlmProvider.ollama);
      expect(config.model, 'qwen2.5:7b');
      expect(config.maxTokens, 8192);
      expect(config.temperature, 0.8);
    });

    test('fromJson 兼容未知 provider', () {
      final config = LlmConfig.fromJson({'provider': 'unknown_provider'});
      expect(config.provider, LlmProvider.ollama);
    });

    test('toJson/fromJson 往返一致', () {
      const original = LlmConfig(
        provider: LlmProvider.openaiCompatible,
        model: 'test-model',
        apiKey: 'key',
        baseUrl: 'https://example.com',
        maxTokens: 1000,
        temperature: 0.3,
      );
      final restored = LlmConfig.fromJson(original.toJson());
      expect(restored.provider, original.provider);
      expect(restored.model, original.model);
      expect(restored.apiKey, original.apiKey);
      expect(restored.baseUrl, original.baseUrl);
      expect(restored.maxTokens, original.maxTokens);
      expect(restored.temperature, original.temperature);
    });
  });

  group('LlmConfig.copyWith', () {
    test('未传参返回等价副本', () {
      const original = LlmConfig(model: 'test');
      final copy = original.copyWith();
      expect(copy.model, original.model);
      expect(copy.provider, original.provider);
    });

    test('仅修改指定字段', () {
      const original = LlmConfig(model: 'old');
      final copy = original.copyWith(model: 'new');
      expect(copy.model, 'new');
      expect(copy.provider, original.provider);
      expect(copy.maxTokens, original.maxTokens);
    });
  });

  group('LlmSettingsRepository', () {
    late Directory tempDir;
    late LlmSettingsRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('llm_config_test_');
      repo = LlmSettingsRepository(tempDir.path);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('load 文件不存在返回默认配置', () async {
      final config = await repo.load();
      expect(config.provider, LlmProvider.ollama);
      expect(config.model, 'qwen2.5:7b');
    });

    test('save/load 往返一致', () async {
      const original = LlmConfig(
        provider: LlmProvider.openaiCompatible,
        model: 'deepseek-chat',
        apiKey: 'sk-test',
        baseUrl: 'https://api.deepseek.com/v1',
        maxTokens: 4096,
        temperature: 0.7,
      );
      await repo.save(original);
      final loaded = await repo.load();
      expect(loaded.provider, original.provider);
      expect(loaded.model, original.model);
      expect(loaded.apiKey, original.apiKey);
      expect(loaded.baseUrl, original.baseUrl);
      expect(loaded.maxTokens, original.maxTokens);
      expect(loaded.temperature, original.temperature);
    });

    test('save 是原子写（无 .tmp 残留）', () async {
      const config = LlmConfig(model: 'test');
      await repo.save(config);
      final tmpFile = File('${tempDir.path}/llm_settings.json.tmp');
      expect(tmpFile.existsSync(), isFalse);
      final targetFile = File('${tempDir.path}/llm_settings.json');
      expect(targetFile.existsSync(), isTrue);
    });

    test('覆盖保存更新内容', () async {
      await repo.save(const LlmConfig(model: 'v1'));
      await repo.save(const LlmConfig(model: 'v2'));
      final loaded = await repo.load();
      expect(loaded.model, 'v2');
    });
  });
}
