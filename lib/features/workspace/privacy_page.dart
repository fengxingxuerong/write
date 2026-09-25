import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/widgets/app_feedback.dart';

/// 隐私与合规页面：说明本地数据、可选云端调用与 API Key 处理方式。
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
                '您创建的角色设定、章节正文、大纲等属于您的创作内容。墨匠不会自行将作品用于分发、展示或授权第三方使用；启用远程 AI 时，生成所需内容会发送给所选服务商，处理方式请以其条款和隐私政策为准。',
            color: AppInk.of(context).primary,
          ),
          _principleCard(
            theme,
            icon: Icons.cloud_off_outlined,
            title: '可选的云端调用',
            content:
                '启用远程 AI 后，墨匠会将本次生成所需的提示词及所选文稿内容发送给所配置的 API 服务商。服务商对内容的处理、保存和训练使用由其服务条款及隐私政策决定，墨匠无法代第三方承诺或控制。请在调用前确认所选服务商的政策。\n\n在 Windows 桌面版中，API Key 使用 Windows DPAPI 加密后保存在本机设置文件中，调用远程 API 时仅在请求中作为鉴权凭据发送。您可以关闭 AI 功能，改用不发起 AI 网络请求的本地模板引擎。',
            color: AppInk.of(context).success,
          ),
          _principleCard(
            theme,
            icon: Icons.model_training_outlined,
            title: '模型训练说明',
            content:
                '使用远程 AI 时，提示词和所选文稿内容会发送给所选服务商；这些内容是否用于模型训练、服务改进或人工处理，取决于服务商的条款和隐私政策。使用本地模型时，相关处理由您运行的本地模型服务决定。若您不接受相关用途，请关闭远程 AI 或选择符合您要求的本地服务。',
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
            title: '隐私保护措施',
            content:
                '本页面说明应用的数据处理方式，不构成法律意见或法规符合性保证：\n'
                '• 内容安全：提供敏感词检测，但可能存在误判或漏判。\n'
                '• 数据管理：支持删除项目和清除本地数据。\n'
                '• 信息透明：AI 调用由您选择服务商和模型，相关数据处理请结合服务商政策评估。',
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
                      Icon(
                        Icons.code,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text('开放生态', style: theme.textTheme.titleSmall),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '墨匠可连接兼容 OpenAI chat/completions 接口的远程服务商，具体兼容性取决于服务商接口实现；您也可以使用本地 Ollama。请在连接前确认服务商的服务条款与隐私政策。',
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
              backgroundColor: AppInk.of(context).danger,
            ),
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
            Icon(
              Icons.verified_user,
              size: 40,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 8),
            Text(
              '墨匠隐私守则',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
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
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              content,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.justify,
            ),
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
              backgroundColor: AppInk.of(ctx).danger,
            ),
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
