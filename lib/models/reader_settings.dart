import 'dart:convert';
import 'dart:io';

import 'package:novel_writer/core/errors/app_exceptions.dart';

/// 阅读器主题。
enum ReaderTheme {
  /// 白纸黑字。
  light,

  /// 米黄护眼纸。
  sepia,

  /// 夜间模式（黑底浅字）。
  dark,
}

/// 阅读器设置（字号 / 主题 / 行距 / 衬线字体），全局持久化。
class ReaderSettings {
  /// 主题。
  final ReaderTheme theme;

  /// 正文字号（12~32）。
  final double fontSize;

  /// 行高倍数（1.4~2.4）。
  final double lineHeight;

  /// 是否使用衬线字体（宋体类）。
  final bool serif;

  /// 构造设置。
  const ReaderSettings({
    this.theme = ReaderTheme.light,
    this.fontSize = 18,
    this.lineHeight = 1.9,
    this.serif = false,
  });

  /// 复制并修改部分字段。
  ReaderSettings copyWith({
    ReaderTheme? theme,
    double? fontSize,
    double? lineHeight,
    bool? serif,
  }) {
    return ReaderSettings(
      theme: theme ?? this.theme,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      serif: serif ?? this.serif,
    );
  }

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'theme': theme.name,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'serif': serif,
      };

  /// 反序列化（兼容缺失字段）。
  factory ReaderSettings.fromJson(Map<String, dynamic> json) {
    return ReaderSettings(
      theme: ReaderTheme.values.firstWhere(
        (ReaderTheme e) => e.name == json['theme'],
        orElse: () => ReaderTheme.light,
      ),
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 18,
      lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.9,
      serif: json['serif'] as bool? ?? false,
    );
  }
}

/// 阅读器设置仓库：JSON 文件持久化。
///
/// 存于 applicationSupportDirectory 下的 `app_settings.json`。
class ReaderSettingsRepository {
  /// 构造仓库。
  ReaderSettingsRepository(this.directory);

  /// 配置所在目录（AppDatabase 同级）。
  final String directory;

  /// 配置文件路径。
  String get filePath => '$directory/app_settings.json';

  /// 读取配置；文件不存在时返回默认。
  Future<ReaderSettings> load() async {
    final File file = File(filePath);
    if (!await file.exists()) return const ReaderSettings();
    try {
      final Map<String, dynamic> json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ReaderSettings.fromJson(json);
    } catch (e) {
      throw StorageException('阅读设置读取失败', e);
    }
  }

  /// 保存配置（原子写）。
  Future<void> save(ReaderSettings settings) async {
    final File file = File(filePath);
    final File tmp = File('$filePath.tmp');
    try {
      await tmp.writeAsString(jsonEncode(settings.toJson()), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      if (await tmp.exists()) {
        await tmp.delete().ignore();
      }
      throw StorageException('阅读设置保存失败', e);
    }
  }
}

/// 忽略异常的清理扩展。
extension _FutureIgnore<T> on Future<T> {
  /// 吞掉异常。
  Future<void> ignore() async {
    try {
      await this;
    } catch (_) {
      // 忽略。
    }
  }
}
