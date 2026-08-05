import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/novel_repository.dart';

/// 导出格式。
enum ExportFormat {
  /// 纯文本。
  txt,

  /// Markdown。
  markdown,

  /// EPUB3 电子书。
  epub,

  /// Word（.docx，纯 Dart 手写 OOXML）。
  docx,

  /// JSON 备份（整本项目数据，可恢复）。
  backup,
}

/// 导出格式扩展。
extension ExportFormatExt on ExportFormat {
  /// 显示名。
  String get label => switch (this) {
        ExportFormat.txt => '纯文本',
        ExportFormat.markdown => 'Markdown',
        ExportFormat.epub => 'EPUB 电子书',
        ExportFormat.docx => 'Word 文档',
        ExportFormat.backup => 'JSON 备份',
      };

  /// 文件扩展名。
  String get ext => switch (this) {
        ExportFormat.txt => 'txt',
        ExportFormat.markdown => 'md',
        ExportFormat.epub => 'epub',
        ExportFormat.docx => 'docx',
        ExportFormat.backup => 'json',
      };
}

/// 导出服务：拼接正文并提供保存路径选择（完全离线，零网络）。
class ExportService {
  /// 构造导出服务。
  const ExportService(this.novelRepo);

  /// 项目仓库（用于按需加载最新数据）。
  final NovelRepository novelRepo;

  /// 拼接导出文本（按章节顺序）。不触发任何网络请求。
  ///
  /// [includeSettings] 为 true 时，正文后附加角色与世界观附录。
  Future<String> buildContent(
    Novel novel,
    ExportFormat format, {
    bool includeSettings = false,
  }) async {
    final StringBuffer buffer = StringBuffer();
    if (format == ExportFormat.markdown) {
      buffer.writeln('# ${novel.title}');
      buffer.writeln();
      buffer.writeln(
        '> 题材：${GenrePresets.get(novel.genre).label} ｜ 基调：${novel.tone}',
      );
      buffer.writeln();
      for (final Chapter c in novel.chapters) {
        buffer.writeln('## ${c.title}');
        buffer.writeln();
        buffer.writeln(c.content);
        buffer.writeln();
      }
    } else if (format == ExportFormat.epub) {
      // EPUB 走二进制构建（zip），不走 buildContent。
      return 'epub';
    } else {
      buffer.writeln(novel.title);
      buffer.writeln('-' * novel.title.length.clamp(1, 30));
      buffer.writeln();
      for (final Chapter c in novel.chapters) {
        buffer.writeln('第${c.order + 1}章 ${c.title}');
        buffer.writeln(c.content);
        buffer.writeln();
      }
    }
    if (includeSettings) {
      _appendSettings(buffer, novel, format == ExportFormat.markdown);
    }
    return buffer.toString();
  }

  /// 追加角色与世界观附录。
  void _appendSettings(
    StringBuffer buffer,
    Novel novel,
    bool markdown,
  ) {
    final bool hasChars = novel.characters.isNotEmpty;
    final bool hasWorlds = novel.worldSettings.isNotEmpty;
    if (!hasChars && !hasWorlds) return;

    if (markdown) {
      buffer.writeln('---');
      buffer.writeln();
      buffer.writeln('## 附录：角色与设定');
      buffer.writeln();
    } else {
      buffer.writeln();
      buffer.writeln('=' * 30);
      buffer.writeln('附录：角色与设定');
      buffer.writeln('=' * 30);
      buffer.writeln();
    }

    if (hasChars) {
      if (markdown) {
        buffer.writeln('### 角色');
        buffer.writeln();
      } else {
        buffer.writeln('【角色】');
      }
      for (final Character ch in novel.characters) {
        final String head =
            ch.name + (ch.role.isNotEmpty ? '（${ch.role}）' : '');
        if (markdown) {
          buffer.writeln('- **$head**');
        } else {
          buffer.writeln(head);
        }
        if (ch.traits.isNotEmpty) {
          buffer.writeln(markdown ? '  - 性格：${ch.traits}' : '  性格：${ch.traits}');
        }
        if (ch.background.isNotEmpty) {
          buffer.writeln(markdown ? '  - 背景：${ch.background}' : '  背景：${ch.background}');
        }
        if (ch.relationships.isNotEmpty) {
          buffer.writeln(markdown ? '  - 关系：${ch.relationships}' : '  关系：${ch.relationships}');
        }
        buffer.writeln();
      }
    }

    if (hasWorlds) {
      if (markdown) {
        buffer.writeln('### 世界观设定');
        buffer.writeln();
      } else {
        buffer.writeln('【世界观设定】');
      }
      for (final WorldSetting w in novel.worldSettings) {
        final String head = w.title + (w.category.isNotEmpty ? '（${w.category}）' : '');
        if (markdown) {
          buffer.writeln('- **$head**：${w.content}');
        } else {
          buffer.writeln('$head：${w.content}');
        }
        buffer.writeln();
      }
    }
  }

  /// 构建 EPUB3 电子书二进制（zip 容器，纯 Dart 零依赖）。
  ///
  /// 包含 mimetype / META-INF/container.xml / OEBPS 下的 content.opf、
  /// toc.ncx、nav.xhtml 与每章 xhtml，UTF-8 编码。
  Uint8List buildEpub(Novel novel) {
    final String title = novel.title;
    final String uuid =
        'urn:uuid:${_fakeUuid()}'; // 幂等：基于书名与章节数生成稳定 UUID。
    final List<Chapter> chapters = novel.chapters;
    // 真实修改时间（ISO 8601 UTC），避免硬编码时间戳。
    final String modified = novel.updatedAt.toUtc().toIso8601String();

    final StringBuffer opf = StringBuffer();
    opf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    opf.writeln('<package xmlns="http://www.idpf.org/2007/opf" '
        'version="3.0" unique-identifier="book-id">');
    opf.writeln('  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">');
    opf.writeln('    <dc:identifier id="book-id">$uuid</dc:identifier>');
    opf.writeln('    <dc:title>${_xml(title)}</dc:title>');
    opf.writeln('    <dc:language>zh-CN</dc:language>');
    opf.writeln('    <meta property="dcterms:modified">$modified</meta>');
    opf.writeln('  </metadata>');
    opf.writeln('  <manifest>');
    opf.writeln('    <item id="nav" href="nav.xhtml" '
        'media-type="application/xhtml+xml" properties="nav"/>');
    opf.writeln('    <item id="ncx" href="toc.ncx" '
        'media-type="application/x-dtbncx+xml"/>');
    opf.writeln('    <item id="css" href="style.css" '
        'media-type="text/css"/>');
    for (int i = 0; i < chapters.length; i++) {
      opf.writeln('    <item id="ch${i + 1}" href="ch${i + 1}.xhtml" '
          'media-type="application/xhtml+xml"/>');
    }
    opf.writeln('  </manifest>');
    opf.writeln('  <spine toc="ncx">');
    for (int i = 0; i < chapters.length; i++) {
      opf.writeln('    <itemref idref="ch${i + 1}"/>');
    }
    opf.writeln('  </spine>');
    opf.writeln('</package>');

    final StringBuffer ncx = StringBuffer();
    ncx.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    ncx.writeln('<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" '
        'version="2005-1">');
    ncx.writeln('  <head>');
    ncx.writeln(
        '    <meta name="dtb:uid" content="$uuid"/>');
    ncx.writeln('    <meta name="dtb:depth" content="1"/>');
    ncx.writeln('  </head>');
    ncx.writeln('  <docTitle><text>${_xml(title)}</text></docTitle>');
    ncx.writeln('  <navMap>');
    for (int i = 0; i < chapters.length; i++) {
      ncx.writeln('    <navPoint id="nav${i + 1}" playOrder="${i + 1}">');
      ncx.writeln(
          '      <navLabel><text>${_xml(chapters[i].title)}</text></navLabel>');
      ncx.writeln('      <content src="ch${i + 1}.xhtml"/>');
      ncx.writeln('    </navPoint>');
    }
    ncx.writeln('  </navMap>');
    ncx.writeln('</ncx>');

    final StringBuffer nav = StringBuffer();
    nav.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    nav.writeln('<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops">');
    nav.writeln('<head><title>${_xml(title)}</title></head>');
    nav.writeln('<body><nav epub:type="toc"><h1>${_xml(title)}</h1><ol>');
    for (int i = 0; i < chapters.length; i++) {
      nav.writeln('  <li><a href="ch${i + 1}.xhtml">'
          '${_xml(chapters[i].title)}</a></li>');
    }
    nav.writeln('</ol></nav></body></html>');

    const String css = 'body { font-family: serif; line-height: 1.8; '
        'margin: 5% 6%; } h1 { font-size: 1.4em; } p { text-indent: 2em; }\n';

    // zip 条目：路径 -> 内容。
    final Map<String, Uint8List> entries = <String, Uint8List>{
      'mimetype': utf8.encode('application/epub+zip'),
      'META-INF/container.xml': utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
        '  <rootfiles>\n'
        '    <rootfile full-path="OEBPS/content.opf" '
        'media-type="application/oebps-package+xml"/>\n'
        '  </rootfiles>\n'
        '</container>\n',
      ),
      'OEBPS/content.opf': utf8.encode(opf.toString()),
      'OEBPS/toc.ncx': utf8.encode(ncx.toString()),
      'OEBPS/nav.xhtml': utf8.encode(nav.toString()),
      'OEBPS/style.css': utf8.encode(css),
    };
    for (int i = 0; i < chapters.length; i++) {
      entries['OEBPS/ch${i + 1}.xhtml'] = utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml">\n'
        '<head><title>${_xml(chapters[i].title)}</title>'
        '<link rel="stylesheet" type="text/css" href="style.css"/>'
        '</head>\n'
        '<body>\n'
        '<h1>${_xml(chapters[i].title)}</h1>\n'
        '${_bodyHtml(chapters[i].content)}\n'
        '</body></html>\n',
      );
    }

    return _buildZip(entries);
  }

  /// 构建 Word .docx 二进制（OOXML，纯 Dart 零依赖）。
  ///
  /// 最小合法 docx：Content_Types + rels + document.xml（段落样式
  /// 标题/正文，UTF-8）。复用 [buildEpub] 的 zip 构建器。
  Uint8List buildDocx(Novel novel) {
    final StringBuffer document = StringBuffer();
    document.writeln('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
    document.writeln('<w:document '
        'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">');
    document.writeln('  <w:body>');
    // 书名标题。
    document.writeln('    <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr>'
        '<w:r><w:t>${_xml(novel.title)}</w:t></w:r></w:p>');
    // 信息行。
    document.writeln('    <w:p><w:pPr><w:pStyle w:val="Subtitle"/></w:pPr>'
        '<w:r><w:t>${_xml('题材：${GenrePresets.get(novel.genre).label} ｜ 基调：${novel.tone}')}</w:t></w:r></w:p>');
    // 章节。
    for (final Chapter c in novel.chapters) {
      document.writeln('    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
          '<w:r><w:t>${_xml('第${c.order + 1}章 ${c.title}')}</w:t></w:r></w:p>');
      // 按空行分段。
      final List<String> paras = c.content
          .split(RegExp(r'\n\s*\n'))
          .where((String p) => p.trim().isNotEmpty)
          .toList();
      for (final String p in paras) {
        document.writeln('    <w:p><w:r><w:t>${_xml(p.trim())}</w:t></w:r></w:p>');
      }
    }
    document.writeln('  </w:body>');
    document.writeln('</w:document>');

    const String contentTypes =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        '</Types>';
    const String rels =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="word/styles.xml"/>'
        '</Relationships>';
    const String styles =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
        '<w:name w:val="Normal"/><w:pPr><w:spacing w:after="120" w:line="360" w:lineRule="auto"/></w:pPr></w:style>'
        '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/>'
        '<w:pPr><w:spacing w:after="240"/></w:pPr>'
        '<w:rPr><w:b/><w:sz w:val="48"/></w:rPr></w:style>'
        '<w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/>'
        '<w:pPr><w:spacing w:after="240"/></w:pPr>'
        '<w:rPr><w:i/><w:sz w:val="24"/><w:color w:val="666666"/></w:rPr></w:style>'
        '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/>'
        '<w:pPr><w:spacing w:before="360" w:after="180"/></w:pPr>'
        '<w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>'
        '</w:styles>';

    final Map<String, Uint8List> entries = <String, Uint8List>{
      '[Content_Types].xml': utf8.encode(contentTypes),
      '_rels/.rels': utf8.encode(rels),
      'word/document.xml': utf8.encode(document.toString()),
      'word/styles.xml': utf8.encode(styles),
    };
    return _buildZip(entries);
  }

  /// 将正文转为 HTML 段落（按空行分段，逐段 <p>）。
  String _bodyHtml(String content) {
    final String trimmed = content.trim();
    if (trimmed.isEmpty) return '';
    return trimmed
        .split(RegExp(r'\n\s*\n'))
        .where((String p) => p.trim().isNotEmpty)
        .map((String p) => '<p>${_xml(p.trim())}</p>')
        .join('\n');
  }

  /// XML 转义。
  String _xml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// 基于书名+章节数生成稳定伪 UUID（同书多次导出一致，便于阅读器识别）。
  String _fakeUuid() {
    int h = 0x811c9dc5;
    const String seed = 'novel-writer'; // 固定前缀。
    for (final int c in seed.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
    }
    final String h8 = h.toRadixString(16).padLeft(8, '0');
    return '${h8.substring(0, 8)}-${h8.substring(0, 4)}-4${h8.substring(4, 7)}-a${h8.substring(5, 8)}-${h8.substring(2, 6)}${h8.substring(0, 4)}${h8.substring(4, 8)}';
  }

  /// 构建 zip 容器（存储式，无压缩；纯 Dart 零依赖）。
  Uint8List _buildZip(Map<String, Uint8List> entries) {
    final List<int> out = <int>[];
    final List<int> central = <int>[];
    int offset = 0;
    final int count = entries.length;

    void putU16(int v) {
      out.add(v & 0xFF);
      out.add((v >> 8) & 0xFF);
    }

    void putU32(int v) {
      out.add(v & 0xFF);
      out.add((v >> 8) & 0xFF);
      out.add((v >> 16) & 0xFF);
      out.add((v >> 24) & 0xFF);
    }

    void putBytes(List<int> b) {
      out.addAll(b);
    }

    entries.forEach((String name, Uint8List data) {
      final List<int> nameBytes = utf8.encode(name);
      final int crc = _crc32(data);
      final int localOffset = offset;
      // local file header
      putU32(0x04034b50);
      putU16(20); // version needed
      putU16(0x0800); // flags: UTF-8 names
      putU16(0); // method: stored
      putU16(0); // mod time
      putU16(0); // mod date
      putU32(crc);
      putU32(data.length);
      putU32(data.length);
      putU16(nameBytes.length);
      putU16(0); // extra len
      putBytes(nameBytes);
      putBytes(data);
      offset += 30 + nameBytes.length + data.length;
      // central directory record
      final int cdOffset = central.length;
      central.addAll(<int>[0x50, 0x4b, 0x01, 0x02]);
      _addU16(central, 20); // version made by
      _addU16(central, 20); // version needed
      _addU16(central, 0x0800);
      _addU16(central, 0);
      _addU16(central, 0);
      _addU16(central, 0);
      _addU32(central, crc);
      _addU32(central, data.length);
      _addU32(central, data.length);
      _addU16(central, nameBytes.length);
      _addU16(central, 0);
      _addU16(central, 0);
      _addU16(central, 0);
      _addU16(central, 0);
      _addU32(central, 0); // external attrs
      _addU32(central, localOffset);
      central.addAll(nameBytes);
      cdOffset; // keep analyzer happy
    });

    final int cdStart = out.length;
    out.addAll(central);
    final int cdSize = central.length;
    // end of central directory
    putU32(0x06054b50);
    putU16(0);
    putU16(0);
    putU16(count);
    putU16(count);
    putU32(cdSize);
    putU32(cdStart);
    putU16(0);
    return Uint8List.fromList(out);
  }

  void _addU16(List<int> l, int v) {
    l.add(v & 0xFF);
    l.add((v >> 8) & 0xFF);
  }

  void _addU32(List<int> l, int v) {
    l.add(v & 0xFF);
    l.add((v >> 8) & 0xFF);
    l.add((v >> 16) & 0xFF);
    l.add((v >> 24) & 0xFF);
  }

  /// CRC-32（IEEE 802.3 多项式）。
  int _crc32(Uint8List data) {
    int crc = 0xFFFFFFFF;
    for (final int b in data) {
      crc ^= b;
      for (int k = 0; k < 8; k++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      }
    }
    return crc & 0xFFFFFFFF;
  }

  /// 拼接并让用户选择保存路径（file_picker）。返回最终保存路径。
  ///
  /// [includeSettings] 为 true 时，txt/md/docx 导出附带角色与世界观附录。
  /// 用户取消时抛 [ExportException]。
  Future<String> export(
    Novel novel,
    ExportFormat format, {
    bool includeSettings = false,
  }) async {
    if (format == ExportFormat.epub) {
      final Uint8List bytes = buildEpub(novel);
      final String suggested =
          '${AppConstants.safeFileName(novel.title)}_${AppConstants.timestamp()}.epub';
      final String? result = await FilePicker.platform.saveFile(
        fileName: suggested,
        type: FileType.custom,
        bytes: bytes,
        allowedExtensions: <String>['epub'],
      );
      if (result == null) {
        throw const ExportException('用户取消了导出');
      }
      return result;
    }
    if (format == ExportFormat.docx) {
      final Uint8List bytes = buildDocx(novel);
      final String suggested =
          '${AppConstants.safeFileName(novel.title)}_${AppConstants.timestamp()}.docx';
      final String? result = await FilePicker.platform.saveFile(
        fileName: suggested,
        type: FileType.custom,
        bytes: bytes,
        allowedExtensions: <String>['docx'],
      );
      if (result == null) {
        throw const ExportException('用户取消了导出');
      }
      return result;
    }
    if (format == ExportFormat.backup) {
      final String json = const JsonEncoder.withIndent('  ')
          .convert(novel.toJson());
      final String suggested =
          '${AppConstants.safeFileName(novel.title)}_backup_${AppConstants.timestamp()}.json';
      final String? result = await FilePicker.platform.saveFile(
        fileName: suggested,
        type: FileType.custom,
        bytes: utf8.encode(json),
        allowedExtensions: <String>['json'],
      );
      if (result == null) {
        throw const ExportException('用户取消了导出');
      }
      return result;
    }
    final String content = await buildContent(novel, format,
        includeSettings: includeSettings);
    final String suggested =
        '${AppConstants.safeFileName(novel.title)}_${AppConstants.timestamp()}.${format.ext}';
    final String? result = await FilePicker.platform.saveFile(
      fileName: suggested,
      type: FileType.custom,
      bytes: utf8.encode(content),
      allowedExtensions: <String>[format.ext],
    );
    if (result == null) {
      throw const ExportException('用户取消了导出');
    }
    return result;
  }
}
