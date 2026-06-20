import 'package:test/test.dart';
import 'package:voice_greet_bot/lavalink_process.dart';

void main() {
  group('LavalinkProcessConfig', () {
    test('defaults to local auto-start settings', () {
      final config = LavalinkProcessConfig.fromEnvironment({});

      expect(config.autoStart, isTrue);
      expect(config.javaExecutable, 'java');
      expect(config.jarPath, 'data/lava/Lavalink.jar');
      expect(config.base.toString(), 'http://127.0.0.1:2333');
      expect(config.password, 'youshallnotpass');
      expect(config.pidPath, 'data/lava/lavalink.pid');
      expect(config.configPath, isNull);
    });

    test('allows external Lavalink mode', () {
      final config = LavalinkProcessConfig.fromEnvironment({
        'LAVALINK_AUTO_START': 'false',
        'LAVALINK_BASE_URL': 'http://lavalink:2333',
        'LAVALINK_PASSWORD': 'secret',
        'LAVALINK_CONFIG_PATH': '/opt/Lavalink/application.yml',
      });

      expect(config.autoStart, isFalse);
      expect(config.base.toString(), 'http://lavalink:2333');
      expect(config.password, 'secret');
      expect(config.configPath, '/opt/Lavalink/application.yml');
    });

    test('accepts common boolean environment values', () {
      for (final value in ['true', '1', 'yes', 'on']) {
        expect(
          LavalinkProcessConfig.fromEnvironment({
            'LAVALINK_AUTO_START': value,
          }).autoStart,
          isTrue,
        );
      }

      for (final value in ['false', '0', 'no', 'off']) {
        expect(
          LavalinkProcessConfig.fromEnvironment({
            'LAVALINK_AUTO_START': value,
          }).autoStart,
          isFalse,
        );
      }
    });

    test('rejects invalid auto-start values', () {
      expect(
        () => LavalinkProcessConfig.fromEnvironment({
          'LAVALINK_AUTO_START': 'sometimes',
        }),
        throwsA(
          isA<LavalinkProcessException>().having(
            (error) => error.message,
            'message',
            contains('LAVALINK_AUTO_START must be true or false'),
          ),
        ),
      );
    });
  });
}
