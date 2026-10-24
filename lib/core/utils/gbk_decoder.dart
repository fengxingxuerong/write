import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// Windows 系统编码转换：把 GBK/GB18030 字节解码为 Dart 字符串。
///
/// 为什么不用纯 Dart 表：GBK 有约 2.4 万个双字节映射，手写/提交整张表
/// 会让仓库多出一大块生成物；而本项目主力平台是 Windows，系统自带
/// `MultiByteToWideChar` 就是最可靠的解码器。非 Windows 平台返回 null，
/// 由调用方给出「另存为 UTF-8」的提示。
///
/// 只做**解码**，不修改源文件；输出不经过网络。
class GbkDecoder {
  const GbkDecoder._();

  static final DynamicLibrary? _kernel32 = _openKernel32();
  static final _LocalAllocDart? _localAlloc = _lookupAlloc();
  static final _LocalFreeDart? _localFree = _lookupFree();
  static final _MultiByteToWideCharDart? _multiByteToWideChar =
      _lookupMultiByteToWideChar();

  /// 尝试按 GB18030 / GBK 解码；失败返回 null。
  ///
  /// [bytes] 不能为空；调用方通常先试 UTF-8，失败后再进来。
  static String? tryDecode(Uint8List bytes) {
    if (!Platform.isWindows || bytes.isEmpty) return null;
    final _LocalAllocDart? alloc = _localAlloc;
    final _LocalFreeDart? free = _localFree;
    final _MultiByteToWideCharDart? convert = _multiByteToWideChar;
    if (alloc == null || free == null || convert == null) return null;

    final Pointer<Uint8> input = alloc(_lptr, bytes.length);
    if (input == nullptr) return null;
    Pointer<Uint16> output = nullptr;
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      // GB18030 覆盖 GBK；系统不支持时再退回 CP936。
      for (final int codePage in <int>[54936, 936]) {
        final int needed = convert(
          codePage,
          _mbErrInvalidChars,
          input,
          bytes.length,
          nullptr,
          0,
        );
        if (needed <= 0) continue;
        output = alloc(_lptr, needed * 2).cast<Uint16>();
        if (output == nullptr) return null;
        final int written = convert(
          codePage,
          _mbErrInvalidChars,
          input,
          bytes.length,
          output,
          needed,
        );
        if (written <= 0) {
          free(output.cast<Void>());
          output = nullptr;
          continue;
        }
        final String decoded = String.fromCharCodes(
          output.asTypedList(written),
        );
        free(output.cast<Void>());
        output = nullptr;
        if (decoded.trim().isEmpty) continue;
        return decoded;
      }
      return null;
    } finally {
      if (output != nullptr) free(output.cast<Void>());
      free(input.cast<Void>());
    }
  }

  // LPTR = LMEM_FIXED | LMEM_ZEROINIT；MB_ERR_INVALID_CHARS 让非法字节
  // 直接失败，而不是静默替换成乱码。
  static const int _lptr = 0x0040;
  static const int _mbErrInvalidChars = 0x00000008;

  static DynamicLibrary? _openKernel32() {
    if (!Platform.isWindows) return null;
    try {
      return DynamicLibrary.open('kernel32.dll');
    } catch (_) {
      return null;
    }
  }

  static _LocalAllocDart? _lookupAlloc() {
    try {
      return _kernel32?.lookupFunction<_LocalAllocNative, _LocalAllocDart>(
        'LocalAlloc',
      );
    } catch (_) {
      return null;
    }
  }

  static _LocalFreeDart? _lookupFree() {
    try {
      return _kernel32?.lookupFunction<_LocalFreeNative, _LocalFreeDart>(
        'LocalFree',
      );
    } catch (_) {
      return null;
    }
  }

  static _MultiByteToWideCharDart? _lookupMultiByteToWideChar() {
    try {
      return _kernel32?.lookupFunction<
        _MultiByteToWideCharNative,
        _MultiByteToWideCharDart
      >('MultiByteToWideChar');
    } catch (_) {
      return null;
    }
  }
}

typedef _LocalAllocNative = Pointer<Uint8> Function(Uint32 flags, IntPtr bytes);
typedef _LocalAllocDart = Pointer<Uint8> Function(int flags, int bytes);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> memory);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void> memory);
typedef _MultiByteToWideCharNative =
    Int32 Function(
      Uint32 codePage,
      Uint32 flags,
      Pointer<Uint8> input,
      Int32 inputLength,
      Pointer<Uint16> output,
      Int32 outputLength,
    );
typedef _MultiByteToWideCharDart =
    int Function(
      int codePage,
      int flags,
      Pointer<Uint8> input,
      int inputLength,
      Pointer<Uint16> output,
      int outputLength,
    );
