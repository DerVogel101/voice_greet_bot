import 'dart:async';
import 'dart:io';

import 'package:nyxx/nyxx.dart';
import 'package:test/test.dart';
import 'package:voice_greet_bot/greeting_config.dart';
import 'package:voice_greet_bot/voice_greeting_service.dart';

void main() {
  group('resolveAudioIdentifier', () {
    test('leaves online URLs unchanged', () {
      final audio = GreetingAudio.onlineUrl('https://example.com/hello.mp3');

      expect(resolveAudioIdentifier(audio), 'https://example.com/hello.mp3');
    });

    test('turns local audio filenames into absolute file paths', () {
      final directory = Directory.systemTemp.createTempSync(
        'voice_greet_bot_test_',
      );

      try {
        final audio = GreetingAudio.manualFile('test.mp3');
        final identifier = resolveAudioIdentifier(
          audio,
          soundsPath: directory.path,
        );

        expect(identifier, isNot(startsWith('file:')));
        expect(identifier, endsWith('test.mp3'));
        expect(File(identifier).isAbsolute, isTrue);
      } finally {
        directory.deleteSync(recursive: true);
      }
    });
  });

  group('GuildTaskQueue', () {
    test('runs tasks for the same guild in order', () async {
      final queue = GuildTaskQueue();
      final events = <String>[];
      final firstCanFinish = Completer<void>();

      final first = queue.enqueue(const Snowflake(1), () async {
        events.add('first-start');
        await firstCanFinish.future;
        events.add('first-end');
      });

      final second = queue.enqueue(const Snowflake(1), () async {
        events.add('second-start');
      });

      await Future<void>.delayed(Duration.zero);
      expect(events, ['first-start']);

      firstCanFinish.complete();
      await first;
      await second;

      expect(events, ['first-start', 'first-end', 'second-start']);
    });

    test('runs tasks for different guilds independently', () async {
      final queue = GuildTaskQueue();
      final events = <String>[];
      final firstCanFinish = Completer<void>();

      final first = queue.enqueue(const Snowflake(1), () async {
        events.add('guild-1-start');
        await firstCanFinish.future;
      });

      final second = queue.enqueue(const Snowflake(2), () async {
        events.add('guild-2-start');
      });

      await Future<void>.delayed(Duration.zero);
      expect(events, ['guild-1-start', 'guild-2-start']);

      firstCanFinish.complete();
      await first;
      await second;
    });
  });
}
