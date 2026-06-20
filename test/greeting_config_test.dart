import 'dart:convert';
import 'dart:io';

import 'package:nyxx/nyxx.dart';
import 'package:test/test.dart';
import 'package:voice_greet_bot/greeting_config.dart';

void main() {
  group('GreetingConfig', () {
    test('parses valid URL and manual file configs', () {
      final config = GreetingConfig.parse('''
{
  "10": {
    "20": {"file": false, "resource": "https://example.com/hello.mp3"},
    "30": {"file": true, "resource": "alex_trim.mp3"}
  }
}
''');

      final entries = config.entriesForGuild(const Snowflake(10));

      expect(entries['20']?.file, isFalse);
      expect(entries['20']?.resource, 'https://example.com/hello.mp3');
      expect(entries['30']?.file, isTrue);
      expect(entries['30']?.resource, 'alex_trim.mp3');
      expect(
        config.audioFor(const Snowflake(10), const Snowflake(30))?.resource,
        'alex_trim.mp3',
      );
      expect(config.audioFor(const Snowflake(10), const Snowflake(99)), isNull);
    });

    test('writes stable two-space indented JSON with a trailing newline', () {
      final config = GreetingConfig.parse('''
{
  "2": {
    "30": {"file": true, "resource": "alex_trim.mp3"}
  },
  "1": {
    "20": {"file": false, "resource": "https://example.com/b.mp3"},
    "10": {"file": false, "resource": "https://example.com/a.mp3"}
  }
}
''');

      expect(config.toPrettyJson(), '''
{
  "1": {
    "10": {
      "file": false,
      "resource": "https://example.com/a.mp3"
    },
    "20": {
      "file": false,
      "resource": "https://example.com/b.mp3"
    }
  },
  "2": {
    "30": {
      "file": true,
      "resource": "alex_trim.mp3"
    }
  }
}
''');
    });

    test('sets URL entries and preserves manual file entries', () {
      final config = GreetingConfig.parse('''
{
  "10": {
    "20": {"file": true, "resource": "alex_trim.mp3"}
  }
}
''');

      config.setOnlineUrl(
        const Snowflake(10),
        const Snowflake(30),
        ' https://example.com/new.mp3 ',
      );

      final entries = config.entriesForGuild(const Snowflake(10));

      expect(entries['20']?.file, isTrue);
      expect(entries['20']?.resource, 'alex_trim.mp3');
      expect(entries['30']?.file, isFalse);
      expect(entries['30']?.resource, 'https://example.com/new.mp3');
    });

    test('removes entries and prunes empty guilds', () {
      final config = GreetingConfig.parse('''
{
  "10": {
    "20": {"file": false, "resource": "https://example.com/hello.mp3"}
  }
}
''');

      expect(config.remove(const Snowflake(10), const Snowflake(99)), isFalse);
      expect(config.remove(const Snowflake(10), const Snowflake(20)), isTrue);
      expect(config.toPrettyJson(), '{}\n');
    });

    test('rejects malformed JSON', () {
      expect(
        () => GreetingConfig.parse('{', sourceName: 'data/users.json'),
        throwsA(
          isA<GreetingConfigException>().having(
            (error) => error.message,
            'message',
            contains('Could not parse data/users.json as JSON'),
          ),
        ),
      );
    });

    test('rejects invalid guild and user IDs', () {
      expect(
        () =>
            GreetingConfig.parse('{"abc": {}}', sourceName: 'data/users.json'),
        throwsA(isA<GreetingConfigException>()),
      );

      expect(
        () => GreetingConfig.parse(
          '{"10": {"abc": {"file": false, "resource": "https://x.test/a.mp3"}}}',
          sourceName: 'data/users.json',
        ),
        throwsA(isA<GreetingConfigException>()),
      );
    });

    test('rejects invalid URL schemes and missing fields', () {
      expect(
        () => GreetingConfig.parse(
          '{"10": {"20": {"file": false, "resource": "ftp://example.com/a.mp3"}}}',
        ),
        throwsA(
          isA<GreetingConfigException>().having(
            (error) => error.message,
            'message',
            contains('http or https URL'),
          ),
        ),
      );

      expect(
        () => GreetingConfig.parse(
          '{"10": {"20": {"resource": "https://example.com/a.mp3"}}}',
        ),
        throwsA(
          isA<GreetingConfigException>().having(
            (error) => error.message,
            'message',
            contains('.file must be a boolean'),
          ),
        ),
      );
    });

    test('rejects unsafe manual filenames', () {
      for (final filename in [
        '../alex.mp3',
        r'folder\alex.mp3',
        '/tmp/alex.mp3',
        'C:alex.mp3',
      ]) {
        expect(
          () => GreetingConfig.parse(
            jsonEncode({
              '10': {
                '20': {'file': true, 'resource': filename},
              },
            }),
          ),
          throwsA(
            isA<GreetingConfigException>().having(
              (error) => error.message,
              'message',
              contains('filenames inside data/sounds'),
            ),
          ),
        );
      }
    });
  });

  group('GreetingConfigStore', () {
    test('loads missing files as empty and creates them on write', () async {
      final directory = await Directory.systemTemp.createTemp(
        'voice_greet_bot_test_',
      );

      try {
        final path = '${directory.path}${Platform.pathSeparator}users.json';
        final store = GreetingConfigStore(path);

        expect(
          (await store.load()).entriesForGuild(const Snowflake(10)),
          isEmpty,
        );

        await store.setOnlineUrl(
          guildId: const Snowflake(10),
          userId: const Snowflake(20),
          url: 'https://example.com/hello.mp3',
        );

        expect(await File(path).readAsString(), '''
{
  "10": {
    "20": {
      "file": false,
      "resource": "https://example.com/hello.mp3"
    }
  }
}
''');
      } finally {
        await directory.delete(recursive: true);
      }
    });
  });
}
