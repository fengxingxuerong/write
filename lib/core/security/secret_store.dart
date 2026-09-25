import 'dart:convert';

import 'package:flutter/services.dart';

/// Secret store abstraction used for credentials that must not be persisted as
/// plaintext JSON.
///
/// The Windows implementation delegates to the runner's DPAPI channel. Tests
/// and non-Windows callers can inject [InMemorySecretStore] explicitly.
abstract interface class SecretStore {
  /// Encrypts [plaintext] and returns an opaque, base64-like token.
  Future<String> protect(String plaintext);

  /// Decrypts a token previously returned by [protect].
  Future<String> unprotect(String protectedValue);
}

/// Windows DPAPI-backed secret store.
class DpapiSecretStore implements SecretStore {
  const DpapiSecretStore();

  static const MethodChannel _channel = MethodChannel(
    'novel_writer/secure_storage',
  );

  @override
  Future<String> protect(String plaintext) async {
    if (plaintext.isEmpty) return '';
    final Uint8List? bytes = await _channel.invokeMethod<Uint8List>(
      'protect',
      <String, Object?>{'plaintext': plaintext},
    );
    if (bytes == null || bytes.isEmpty) {
      throw StateError('Windows DPAPI returned an empty protected value');
    }
    return base64Encode(bytes);
  }

  @override
  Future<String> unprotect(String protectedValue) async {
    if (protectedValue.isEmpty) return '';
    final Uint8List bytes = base64Decode(protectedValue);
    final String? plaintext = await _channel.invokeMethod<String>(
      'unprotect',
      <String, Object?>{'data': bytes},
    );
    if (plaintext == null) {
      throw StateError('Windows DPAPI returned an empty plaintext value');
    }
    return plaintext;
  }
}

/// Deterministic in-memory store for unit tests and non-Windows tooling.
///
/// It is intentionally not a production credential store.
class InMemorySecretStore implements SecretStore {
  final Map<String, String> _values = <String, String>{};
  int _sequence = 0;

  @override
  Future<String> protect(String plaintext) async {
    if (plaintext.isEmpty) return '';
    final String token = 'memory-${_sequence++}';
    _values[token] = plaintext;
    return token;
  }

  @override
  Future<String> unprotect(String protectedValue) async {
    if (protectedValue.isEmpty) return '';
    final String? value = _values[protectedValue];
    if (value == null) {
      throw StateError('Unknown in-memory protected value');
    }
    return value;
  }
}

/// Recursively replaces plaintext `apiKey` fields with `apiKeyEncrypted`.
/// The input tree is not mutated.
Future<Object?> protectJsonSecrets(Object? value, SecretStore store) async {
  if (value is Map) {
    final Map<String, dynamic> result = <String, dynamic>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final Object? key = entry.key;
      if (key is! String) {
        throw StateError('凭据 JSON 的对象字段名必须是字符串');
      }
      final Object? child = entry.value;
      if (key == 'apiKey' && child is String) {
        if (child.isNotEmpty) {
          result['apiKeyEncrypted'] = await store.protect(child);
        }
      } else {
        result[key] = await protectJsonSecrets(child, store);
      }
    }
    return result;
  }
  if (value is List) {
    return <Object?>[
      for (final Object? child in value) await protectJsonSecrets(child, store),
    ];
  }
  return value;
}

/// Recursively restores encrypted `apiKeyEncrypted` fields to `apiKey`.
/// The input tree is not mutated.
Future<Object?> unprotectJsonSecrets(Object? value, SecretStore store) async {
  if (value is Map) {
    final Map<String, dynamic> result = <String, dynamic>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final Object? key = entry.key;
      if (key is! String) {
        throw StateError('凭据 JSON 的对象字段名必须是字符串');
      }
      final Object? child = entry.value;
      if (key == 'apiKeyEncrypted' && child is String) {
        if (child.isNotEmpty) {
          result['apiKey'] = await store.unprotect(child);
        }
      } else {
        result[key] = await unprotectJsonSecrets(child, store);
      }
    }
    return result;
  }
  if (value is List) {
    return <Object?>[
      for (final Object? child in value)
        await unprotectJsonSecrets(child, store),
    ];
  }
  return value;
}
