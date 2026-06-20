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
}
