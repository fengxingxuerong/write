import 'dart:convert';
import 'dart:typed_data';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/core/utils/gbk_decoder.dart';

/// 导入原稿中的一章。
class ParsedManuscriptChapter {
  /// 构造一章。
  const ParsedManuscriptChapter({required this.title, required this.content});

  /// 章节标题（已去掉 Markdown 井号与首尾空白）。
  final String title;

  /// 正文。
  final String content;

  /// 按应用统一口径统计的字数。
  int get wordCount => AppConstants.countWords(content);
}

/// 一份待导入的原稿。
class ParsedManuscript {
  /// 构造解析结果。
  const ParsedManuscript({
    required this.chapters,
    required this.detectedHeadings,
    required this.totalWords,
  });

  /// 章节列表（至少一章）。
  final List<ParsedManuscriptChapter> chapters;

  /// 是否真的识别到了章节标题。
  ///
  /// false 表示原文没有可识别的章节标记，整篇被作为一章导入；UI 应明确
  /// 告诉用户这一点，而不是假装「识别成功」。
  final bool detectedHeadings;

  /// 全书字数。
  final int totalWords;
}

/// 原稿解析器：纯函数，不碰文件系统。
///
/// 支持：
/// - UTF-8（含 BOM）、UTF-16 LE/BE（含 BOM，或无 BOM 但零字节分布明显）；
/// - Markdown 标题（`# 第一章` / `## Chapter 1`）；
/// - 中文常见章节标记（`第一章` / `第 12 章` / `楔子` / `序章` / `番外` 等），
///   有空格、冒号、顿号或无分隔符都能识别；
/// - 无章节标题时整篇作为一章。
///
/// 不支持 GBK/GB18030：Dart 标准库没有该解码器，遇到时给出可执行的提示，
/// 而不是用 `allowMalformed` 把中文悄悄解成乱码。
class ManuscriptParser {
  const ManuscriptParser._();

  /// 单个原稿文件的读取上限。
  static const int maxBytes = 50 * 1024 * 1024;

  static final RegExp _markdownHeading = RegExp(
    r'^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$',
  );

  static final RegExp _chineseHeading = RegExp(
    r'^\s{0,8}(第\s*[0-9０-９零〇一二三四五六七八九十百千万两]+\s*[章节回卷集部篇]'
    r'|序章|楔子|引子|前言|序言|尾声|终章|后记|番外(?:\s*[0-9０-９一二三四五六七八九十]+)?)'
    r'\s*(?:[:：、.．·\-—]\s*)?(.*)$',
  );

  static final RegExp _englishHeading = RegExp(
    r'^\s{0,3}(?:chapter|part)\s+\d+\b(.*)$',
    caseSensitive: false,
  );

  static final RegExp _sentencePunctuation = RegExp(r'[。！？!?；;…]');

  /// 解码原稿字节。
  static String decodeBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const StorageException('原稿文件为空');
    }
    if (bytes.length > maxBytes) {
      throw const StorageException('原稿超过 50 MiB，已拒绝导入');
    }

    // UTF-8 with BOM.
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return _decodeUtf8(bytes.sublist(3));
    }

    // UTF-16 with BOM.
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes, offset: 2, littleEndian: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes, offset: 2, littleEndian: false);
    }

    // 没有 BOM 的 UTF-16：中文文本常见的特征是奇数/偶数位里有大量 0。
    final (bool utf16, bool littleEndian) = _sniffUtf16(bytes);
    if (utf16) {
      return _decodeUtf16(bytes, littleEndian: littleEndian);
    }

    return _decodeUtf8(bytes);
  }

  /// 解析已解码的纯文本。
  static ParsedManuscript parse(String text) {
    final String normalized = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final List<String> lines = normalized.split('\n');
    final List<ParsedManuscriptChapter> chapters = <ParsedManuscriptChapter>[];
    final StringBuffer preamble = StringBuffer();
    final StringBuffer body = StringBuffer();
    String? currentTitle;
    bool detectedHeadings = false;

    void flush(String title) {
      final String content = _cleanContent(body.toString());
      if (content.isEmpty) return;
      chapters.add(ParsedManuscriptChapter(title: title, content: content));
    }

    for (final String line in lines) {
      final String? heading = _asHeading(line);
      if (heading != null) {
        detectedHeadings = true;
        if (currentTitle != null) {
          flush(currentTitle);
        } else {
          final String preface = _cleanContent(preamble.toString());
          if (preface.isNotEmpty) {
            chapters.add(
              ParsedManuscriptChapter(title: '序章', content: preface),
            );
          }
        }
        currentTitle = heading;
        body.clear();
      } else if (currentTitle != null) {
        body.writeln(line);
      } else {
        preamble.writeln(line);
      }
    }

    if (!detectedHeadings) {
      final String whole = _cleanContent(normalized);
      if (whole.isEmpty) {
        throw const FormatException('原稿没有可导入的正文');
      }
      return ParsedManuscript(
        chapters: <ParsedManuscriptChapter>[
          ParsedManuscriptChapter(title: '第1章', content: whole),
        ],
        detectedHeadings: false,
        totalWords: AppConstants.countWords(whole),
      );
    }

    if (currentTitle != null) {
      flush(currentTitle);
    } else {
      final String preface = _cleanContent(preamble.toString());
      if (preface.isNotEmpty) {
        chapters.add(ParsedManuscriptChapter(title: '序章', content: preface));
      }
    }

    if (chapters.isEmpty) {
      throw const FormatException('原稿只有章节标题，没有正文');
    }

    return ParsedManuscript(
      chapters: chapters,
      detectedHeadings: true,
      totalWords: chapters.fold<int>(
        0,
        (int sum, ParsedManuscriptChapter chapter) => sum + chapter.wordCount,
      ),
    );
  }

  /// 从文件名生成作品名：去掉扩展名与首尾空白。
  static String suggestTitle(String fileName) {
    String name = fileName.trim();
    final int slash = name.lastIndexOf(RegExp(r'[\\/]'));
    if (slash >= 0) name = name.substring(slash + 1);
    final int dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    name = name.trim();
    return name.isEmpty ? '未命名作品' : name;
  }

  /// 判断一行是否章节标题；是则返回清理后的标题。
  static String? _asHeading(String rawLine) {
    final String line = rawLine.trimRight();
    if (line.trim().isEmpty) return null;

    final RegExpMatch? markdown = _markdownHeading.firstMatch(line);
    if (markdown != null) {
      final String title = _cleanTitle(markdown.group(1) ?? '');
      return title.isEmpty ? null : title;
    }

    final RegExpMatch? chinese = _chineseHeading.firstMatch(line);
    if (chinese != null) {
      final String marker = (chinese.group(1) ?? '').trim();
      final String rest = (chinese.group(2) ?? '').trim();
      // 「第一章说的就是……」这类正文句不是标题：标题行不出现句末标点，
      // 不以「的」开头，且标题本身不会太长（网文标题通常 2~30 字）。
      if (_sentencePunctuation.hasMatch(rest)) return null;
      if (rest.startsWith('的')) return null;
      if (rest.length > 40) return null;
      final String title = _cleanTitle(rest.isEmpty ? marker : '$marker $rest');
      return title.isEmpty ? null : title;
    }

    final RegExpMatch? english = _englishHeading.firstMatch(line);
    if (english != null) {
      final String rest = (english.group(1) ?? '').trim();
      if (_sentencePunctuation.hasMatch(rest) || rest.length > 60) return null;
      return _cleanTitle(line);
    }
    return null;
  }

  static String _cleanTitle(String value) {
    return value
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[\s#]+|[\s#]+$'), '')
        .trim();
  }

  /// 去掉行尾空白，并把 3 个以上连续空行压成 2 个；正文行首缩进保留。
  static String _cleanContent(String value) {
    final List<String> lines = value
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((String line) => line.trimRight())
        .toList();
    final String joined = lines.join('\n');
    return joined
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .replaceAll(RegExp(r'^\n+|\n+$'), '');
  }

  static String _decodeUtf8(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // Windows 中文 TXT 大量仍是 GBK/GB18030；系统解码器可用时直接兼容，
      // 不再强迫用户先另存为 UTF-8。
      final String? gbk = GbkDecoder.tryDecode(bytes);
      if (gbk != null) return gbk;
      throw const StorageException(
        '文件不是 UTF-8，也无法识别为 GBK/GB18030。'
        '请用记事本或编辑器“另存为 UTF-8”后重试。',
      );
    }
  }

  static String _decodeUtf16(
    Uint8List bytes, {
    int offset = 0,
    required bool littleEndian,
  }) {
    if ((bytes.length - offset).isOdd) {
      throw const StorageException('UTF-16 原稿字节数不完整，无法解码');
    }
    final List<int> codeUnits = <int>[];
    for (int i = offset; i + 1 < bytes.length; i += 2) {
      final int a = bytes[i];
      final int b = bytes[i + 1];
      codeUnits.add(littleEndian ? (a | (b << 8)) : ((a << 8) | b));
    }
    try {
      final String decoded = String.fromCharCodes(codeUnits);
      return decoded.startsWith('\uFEFF') ? decoded.substring(1) : decoded;
    } on ArgumentError {
      throw const StorageException('UTF-16 原稿包含非法字符，无法解码');
    }
  }

  /// 无 BOM 时嗅探 UTF-16：中文 UTF-16 文本的零字节占比很高且集中在固定奇偶位。
  static (bool, bool) _sniffUtf16(Uint8List bytes) {
    final int sample = bytes.length < 4096 ? bytes.length : 4096;
    if (sample < 8) return (false, true);
    int evenZeros = 0;
    int oddZeros = 0;
    int pairs = 0;
    for (int i = 0; i + 1 < sample; i += 2) {
      if (bytes[i] == 0) evenZeros++;
      if (bytes[i + 1] == 0) oddZeros++;
      pairs++;
    }
    if (pairs == 0) return (false, true);
    // 纯 ASCII 的 UTF-16LE：奇数位几乎全是 0；UTF-16BE 则相反。
    if (oddZeros >= pairs * 0.6 && evenZeros <= pairs * 0.1) {
      return (true, true);
    }
    if (evenZeros >= pairs * 0.6 && oddZeros <= pairs * 0.1) {
      return (true, false);
    }
    return (false, true);
  }
}
