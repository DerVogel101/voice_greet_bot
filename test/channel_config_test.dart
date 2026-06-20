import 'dart:io';

import 'package:nyxx/nyxx.dart';
import 'package:test/test.dart';
import 'package:voice_greet_bot/channel_config.dart';

void main() {
  group('ChannelConfig', () {
    test('parses ignored channel config', () {
      final config = ChannelConfig.parse('''
{
  "10": {
    "20": {"ignore": true},
    "30": {"ignore": true}
  }
}
''');

      expect(config.ignoredChannelIdsForGuild(const Snowflake(10)), [
        '20',
        '30',
      ]);
      expect(
        config.isIgnored(const Snowflake(10), const Snowflake(20)),
        isTrue,
      );
      expect(
        config.isIgnored(const Snowflake(10), const Snowflake(99)),
        isFalse,
      );
    });

    test('writes stable two-space indented JSON with a trailing newline', () {
      final config = ChannelConfig.parse('''
{
  "2": {
    "30": {"ignore": true}
  },
  "1": {
    "20": {"ignore": true},
    "10": {"ignore": true}
  }
}
''');

      expect(config.toPrettyJson(), '''
{
  "1": {
    "10": {
      "ignore": true
    },
    "20": {
      "ignore": true
    }
  },
  "2": {
    "30": {
      "ignore": true
    }
  }
}
''');
    });

    test('adds and removes ignored channels and prunes empty guilds', () {
      final config = ChannelConfig.empty();

      expect(config.ignore(const Snowflake(10), const Snowflake(20)), isTrue);
      expect(config.ignore(const Snowflake(10), const Snowflake(20)), isFalse);
      expect(config.allow(const Snowflake(10), const Snowflake(99)), isFalse);
      expect(config.allow(const Snowflake(10), const Snowflake(20)), isTrue);
      expect(config.toPrettyJson(), '{}\n');
    });

    test('rejects malformed JSON', () {
      expect(
        () => ChannelConfig.parse('{', sourceName: 'data/channels.json'),
        throwsA(
          isA<ChannelConfigException>().having(
            (error) => error.message,
            'message',
            contains('Could not parse data/channels.json as JSON'),
          ),
        ),
      );
    });

    test('rejects invalid guild and channel IDs', () {
      expect(
        () => ChannelConfig.parse(
          '{"abc": {}}',
          sourceName: 'data/channels.json',
        ),
        throwsA(isA<ChannelConfigException>()),
      );

      expect(
        () => ChannelConfig.parse(
          '{"10": {"abc": {"ignore": true}}}',
          sourceName: 'data/channels.json',
        ),
        throwsA(isA<ChannelConfigException>()),
      );
    });

    test('rejects invalid ignore entries', () {
      for (final source in [
        '{"10": {"20": true}}',
        '{"10": {"20": {"ignore": "yes"}}}',
        '{"10": {"20": {"ignore": false}}}',
      ]) {
        expect(
          () => ChannelConfig.parse(source, sourceName: 'data/channels.json'),
          throwsA(isA<ChannelConfigException>()),
        );
      }
    });
  });

  group('ChannelConfigStore', () {
    test('loads missing files as empty and creates them on write', () async {
      final directory = await Directory.systemTemp.createTemp(
        'voice_greet_bot_test_',
      );

      try {
        final path = '${directory.path}${Platform.pathSeparator}channels.json';
        final store = ChannelConfigStore(path);

        expect(
          (await store.load()).ignoredChannelIdsForGuild(const Snowflake(10)),
          isEmpty,
        );

        await store.ignore(
          guildId: const Snowflake(10),
          channelId: const Snowflake(20),
        );

        expect(await File(path).readAsString(), '''
{
  "10": {
    "20": {
      "ignore": true
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
