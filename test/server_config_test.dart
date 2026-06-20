import 'dart:io';

import 'package:nyxx/nyxx.dart';
import 'package:test/test.dart';
import 'package:voice_greet_bot/server_config.dart';

void main() {
  group('parseGuildIds', () {
    test('accepts string and integer guild IDs', () {
      final guildIds = parseGuildIds(
        '["123456789012345678", 234567890123456789]',
      );

      expect(guildIds.map((id) => id.value), [
        123456789012345678,
        234567890123456789,
      ]);
    });

    test('rejects an empty array', () {
      expect(
        () => parseGuildIds('[]', sourceName: 'data/servers.json'),
        throwsA(
          isA<ServerConfigException>().having(
            (error) => error.message,
            'message',
            contains('at least one Discord guild ID'),
          ),
        ),
      );
    });

    test('rejects malformed JSON', () {
      expect(
        () => parseGuildIds('[', sourceName: 'data/servers.json'),
        throwsA(
          isA<ServerConfigException>().having(
            (error) => error.message,
            'message',
            contains('Could not parse data/servers.json as JSON'),
          ),
        ),
      );
    });

    test('rejects an invalid ID value', () {
      expect(
        () => parseGuildIds('["not-a-guild"]', sourceName: 'data/servers.json'),
        throwsA(
          isA<ServerConfigException>().having(
            (error) => error.message,
            'message',
            contains('entry 0 must be a positive Discord guild ID'),
          ),
        ),
      );
    });
  });

  group('ServerConfigStore', () {
    test('loads allowed guilds and answers membership checks', () async {
      final directory = await Directory.systemTemp.createTemp(
        'voice_greet_bot_test_',
      );

      try {
        final path = '${directory.path}${Platform.pathSeparator}servers.json';
        await File(path).writeAsString('["10", "20"]');

        final store = ServerConfigStore(path);
        await store.loadRequired();

        expect(store.guildIds.map((id) => id.value), [10, 20]);
        expect(store.allows(const Snowflake(10)), isTrue);
        expect(store.allows(const Snowflake(99)), isFalse);
      } finally {
        await directory.delete(recursive: true);
      }
    });

    test('reloads valid changes from disk', () async {
      final directory = await Directory.systemTemp.createTemp(
        'voice_greet_bot_test_',
      );

      try {
        final path = '${directory.path}${Platform.pathSeparator}servers.json';
        final file = File(path);
        await file.writeAsString('["10"]');

        final store = ServerConfigStore(path);
        await store.loadRequired();

        await file.writeAsString('["20", "30"]');
        final reloaded = await store.reloadKeepingLast();

        expect(reloaded, isTrue);
        expect(store.allows(const Snowflake(10)), isFalse);
        expect(store.allows(const Snowflake(20)), isTrue);
        expect(store.allows(const Snowflake(30)), isTrue);
      } finally {
        await directory.delete(recursive: true);
      }
    });

    test('keeps the last valid config if a reload is invalid', () async {
      final directory = await Directory.systemTemp.createTemp(
        'voice_greet_bot_test_',
      );

      try {
        final path = '${directory.path}${Platform.pathSeparator}servers.json';
        final file = File(path);
        await file.writeAsString('["10"]');

        final store = ServerConfigStore(path);
        await store.loadRequired();

        final errors = <ServerConfigException>[];
        await file.writeAsString('[]');
        final reloaded = await store.reloadKeepingLast(onError: errors.add);

        expect(reloaded, isFalse);
        expect(errors, hasLength(1));
        expect(store.allows(const Snowflake(10)), isTrue);
      } finally {
        await directory.delete(recursive: true);
      }
    });
  });

  group('ServerSettingsConfig', () {
    test('parses per-guild volume settings', () {
      final config = ServerSettingsConfig.parse('''
{
  "20": {
    "volume": 25
  },
  "10": {
    "volume": 0
  }
}
''');

      expect(config.volumeFor(const Snowflake(10)), 0);
      expect(config.volumeFor(const Snowflake(20)), 25);
    });

    test('defaults missing guilds to normal volume', () {
      final config = ServerSettingsConfig.empty();

      expect(
        config.volumeFor(const Snowflake(99)),
        ServerSettingsConfig.defaultVolume,
      );
    });

    test('rejects invalid settings entries', () {
      void expectSettingsError(String source, String message) {
        expect(
          () => ServerSettingsConfig.parse(
            source,
            sourceName: 'data/server_config.json',
          ),
          throwsA(
            isA<ServerConfigException>().having(
              (error) => error.message,
              'message',
              contains(message),
            ),
          ),
        );
      }

      expectSettingsError(
        '{"not-a-guild": {"volume": 50}}',
        'guild ID must be a positive Discord ID',
      );
      expectSettingsError(
        '{"10": 50}',
        'data/server_config.json.10 must be an object',
      );
      expectSettingsError(
        '{"10": {}}',
        'data/server_config.json.10.volume is required',
      );
      expectSettingsError(
        '{"10": {"volume": 50.5}}',
        'data/server_config.json.10.volume must be an integer from 0 to 100',
      );
      expectSettingsError(
        '{"10": {"volume": 101}}',
        'data/server_config.json.10.volume must be an integer from 0 to 100',
      );
    });
  });

  group('ServerSettingsStore', () {
    test('missing file loads default settings', () async {
      final directory = await Directory.systemTemp.createTemp(
        'voice_greet_bot_test_',
      );

      try {
        final path =
            '${directory.path}${Platform.pathSeparator}server_config.json';
        final store = ServerSettingsStore(path);
        final config = await store.load();

        expect(
          config.volumeFor(const Snowflake(10)),
          ServerSettingsConfig.defaultVolume,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    });

    test('saves and reloads stable pretty JSON', () async {
      final directory = await Directory.systemTemp.createTemp(
        'voice_greet_bot_test_',
      );

      try {
        final path =
            '${directory.path}${Platform.pathSeparator}server_config.json';
        final store = ServerSettingsStore(path);
        final config = ServerSettingsConfig.empty()
          ..setVolume(const Snowflake(20), 50)
          ..setVolume(const Snowflake(10), 75);

        await store.save(config);

        expect(await File(path).readAsString(), '''
{
  "10": {
    "volume": 75
  },
  "20": {
    "volume": 50
  }
}
''');

        final reloaded = await store.load();
        expect(reloaded.volumeFor(const Snowflake(10)), 75);
        expect(reloaded.volumeFor(const Snowflake(20)), 50);
      } finally {
        await directory.delete(recursive: true);
      }
    });
  });
}
