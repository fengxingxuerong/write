import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/security/secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DpapiSecretStore', () {
    const MethodChannel channel = MethodChannel('novel_writer/secure_storage');
    late DpapiSecretStore store;

    setUp(() {
      store = const DpapiSecretStore();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            switch (call.method) {
              case 'protect':
                final Map<Object?, Object?> args =
                    call.arguments as Map<Object?, Object?>;
                return Uint8List.fromList(
                  utf8.encode('protected:${args['plaintext']}'),
                );
              case 'unprotect':
                final Map<Object?, Object?> args =
                    call.arguments as Map<Object?, Object?>;
                final Uint8List bytes = args['data']! as Uint8List;
                final String encoded = utf8.decode(bytes);
                return encoded.substring('protected:'.length);
              default:
                throw PlatformException(code: 'unsupported');
            }
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('protect/unprotect 通过 Windows 通道往返', () async {
      final String protectedValue = await store.protect('secret-value');
      expect(protectedValue, isNotEmpty);
      expect(await store.unprotect(protectedValue), 'secret-value');
    });

    test('空字符串不调用平台通道', () async {
      expect(await store.protect(''), '');
      expect(await store.unprotect(''), '');
    });

    test('递归保护与恢复嵌套 apiKey', () async {
      final InMemorySecretStore memory = InMemorySecretStore();
      final Object? protectedTree = await protectJsonSecrets(<String, Object?>{
        'apiKey': 'root-secret',
        'nested': <Object?>[
          <String, Object?>{'apiKey': 'nested-secret'},
          'plain',
        ],
      }, memory);
      expect(protectedTree.toString(), isNot(contains('root-secret')));
      expect(protectedTree.toString(), isNot(contains('nested-secret')));
      final Object? restored = await unprotectJsonSecrets(
        protectedTree,
        memory,
      );
      expect(restored.toString(), contains('root-secret'));
      expect(restored.toString(), contains('nested-secret'));
    });
  });

  test('InMemorySecretStore 拒绝未知的保护值', () async {
    expect(
      () => InMemorySecretStore().unprotect('memory-does-not-exist'),
      throwsStateError,
    );
  });
}
