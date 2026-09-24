import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/widgets/app_feedback.dart';

/// 隐私与合规页面：声明数据归属、不出域、不用于模型训练。
class PrivacyPage extends ConsumerWidget {
  const PrivacyPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: () => context.pop(),
        ),
        title: const Text('隐私与合规'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.s4),
        children: [
          _heroCard(theme),
          const SizedBox(height: AppTokens.s4),
          _principleCard(
            theme,
            icon: Icons.shield_outlined,
            title: '文稿归作者所有',
            content:
                '您创建的一切内容（包括角色设定、章节正文、大纲等）完全属于您本人。墨匠不会以任何形式获取您的作品权利，也不会用于分发、展示或授权第三方使用。',
            color: AppInk.of(context).primary,
          ),
          _principleCard(
            theme,
            icon: Icons.cloud_off_outlined,
            title: '可选的云端调用',
            content:
                '调用 AI 生成时，发送给开源兼容 API（如 OpenAI、DeepSeek、通义千问等）的数据仅用于完成本次生成返回结果，墨匠本身不搭建内容中转服务器，不会留存您发送或返回的内容。'
                '\n\n您可以选择在设置中完全关闭 AI 功能，使用纯本地模板引擎（零网络）。',
            color: AppInk.of(context).success,
          ),
          _principleCard(
            theme,
            icon: Icons.model_training_outlined,
            title: '不用于模型训练',
            content:
                '墨匠作者郑重承诺：在您使用本应用期间产生的任何文本、角色、大纲内容，不会被收集用于 LLM 微调、RLHA、DPO 或任何形式的模型训练。您写的东西就是您写的。',
            color: AppInk.of(context).accent,
          ),
          _principleCard(
            theme,
            icon: Icons.storage_outlined,
            title: '本地数据自主',
            content:
                '所有项目以单项目 JSON 文件形式保存在您本机的应用支持目录中。您可随时通过资源管理器自行备份、迁移或销毁数据。点击“清除所有本地数据”会删除项目、流水线、快照、设置和诊断数据，请提前备份。',
            color: AppInk.of(context).warn,
          ),
          _principleCard(
            theme,
            icon: Icons.gpp_good_outlined,
            title: '符合法规要求',
            content:
                '本应用遵循《中华人民共和国个人信息保护法》（PIPL）与《生成式人工智能服务管理暂行办法》相关要求：\n'
                '• 内容过滤：内置敏感词库 + 上下文白名单，避免生成违规内容。\n'
                '• 用户删除权：全程支持删除章节、角色、世界观设定。\n'
                '• 透明度：所有 AI 生成内容均可追溯原始提示词与模型。',
            color: AppInk.of(context).primary,
          ),
          const SizedBox(height: AppTokens.s4),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.s4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.code, size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text('开放生态',
                          style: theme.textTheme.titleSmall),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '墨匠以开放生态运作，支持所有 OpenAI 兼容 API。您可以在本应用「AI 设置」页选择任意 API 提供商或使用本地 Ollama。您选择哪家提供商，决定权在您。',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppTokens.s6),
          FilledButton.icon(
            icon: const Icon(Icons.delete_forever),
            label: const Text('清除所有本地数据'),
            style: FilledButton.styleFrom(
                backgroundColor: AppInk.of(context).danger),
            onPressed: () => _confirmWipe(context, ref),
          ),
          const SizedBox(height: AppTokens.s8),
        ],
      ),
    );
  }

  Widget _heroCard(ThemeData theme) {
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.s4),
        child: Column(
          children: [
            Icon(Icons.verified_user, size: 40, color: theme.colorScheme.primary),
            const SizedBox(height: 8),
            Text('墨匠隐私守则',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              '您的故事，只属于您。',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _principleCard(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String content,
    required Color color,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.s3),
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 8),
                Text(title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            Text(content, style: theme.textTheme.bodySmall, textAlign: TextAlign.justify),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmWipe(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清除？'),
        content: const Text(
          '此操作将删除应用目录中的所有项目文件（含章节、角色、大纲）。此操作不可撤销。\n\n建议先通过「导出」功能备份重要作品。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppInk.of(ctx).danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      try {
        await ref.read(appDatabaseProvider).clearAllData();
        ref.invalidate(projectListViewModelProvider);
        ref.invalidate(llmSettingsProvider);
        ref.invalidate(readerSettingsProvider);
        ref.invalidate(sensitiveWordsProvider);
        if (context.mounted) {
          AppToast.success(context, '本地数据已清除');
        }
      } catch (e) {
        if (context.mounted) {
          AppToast.error(context, '清除失败：$e');
        }
      }
    }
  }
}
