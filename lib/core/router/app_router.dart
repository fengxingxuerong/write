import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:novel_writer/features/ai_pipeline/ai_pipeline_pages.dart';
import 'package:novel_writer/features/project_list/project_list_page.dart';
import 'package:novel_writer/features/workspace/workspace_page.dart';
import 'package:novel_writer/features/workspace/privacy_page.dart';

/// 全局路由表（声明式）。
///
/// - `/`               ：项目列表首页。
/// - `/novel/:id`      ：项目内工作区（三栏布局）。
///
/// 通过 [routerProvider] 暴露，供 [App] 以 `routerConfig` 挂载。
final Provider<GoRouter> routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) =>
            const ProjectListPage(),
      ),
      GoRoute(
        path: '/novel/:id',
        builder: (BuildContext context, GoRouterState state) =>
            WorkspacePage(novelId: state.pathParameters['id'] ?? ''),
      ),
      GoRoute(
        path: '/privacy',
        builder: (BuildContext context, GoRouterState state) =>
            const PrivacyPage(),
      ),
      GoRoute(
        path: '/ai-pipeline',
        builder: (BuildContext context, GoRouterState state) =>
            const AiPipelineHomePage(),
      ),
      GoRoute(
        path: '/ai-pipeline/config',
        builder: (BuildContext context, GoRouterState state) =>
            const AiPipelineConfigPage(),
      ),
      GoRoute(
        path: '/ai-pipeline/run/:id',
        builder: (BuildContext context, GoRouterState state) =>
            AiPipelineRunPage(taskId: state.pathParameters['id'] ?? ''),
      ),
    ],
    errorBuilder: (BuildContext context, GoRouterState state) => Scaffold(
      appBar: AppBar(title: const Text('页面不存在')),
      body: Center(child: Text('未找到页面：${state.uri}')),
    ),
  );
});
