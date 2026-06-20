import 'dart:async';
import 'dart:io';

import 'package:nyxx/nyxx.dart';
import 'package:nyxx_commands/nyxx_commands.dart';
import 'package:nyxx_lavalink/nyxx_lavalink.dart';

import 'channel_config.dart';
import 'greet_commands.dart';
import 'greeting_config.dart';
import 'lavalink_process.dart';
import 'server_config.dart';
import 'voice_greeting_service.dart';

const _discordTokenVariable = 'DISCORD_TOKEN';
const _playbackStartDelayVariable = 'VOICE_GREETING_START_DELAY_MS';
const _serversConfigPath = 'data/servers.json';
const _serverSettingsConfigPath = 'data/server_config.json';
const _usersConfigPath = 'data/users.json';
const _channelsConfigPath = 'data/channels.json';

Future<void> main() async {
  final token = Platform.environment[_discordTokenVariable]?.trim();
  if (token == null || token.isEmpty) {
    stderr.writeln('Missing $_discordTokenVariable environment variable.');
    exitCode = 64;
    return;
  }

  final serverConfigStore = ServerConfigStore(_serversConfigPath);
  try {
    await serverConfigStore.loadRequired();
  } on ServerConfigException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
    return;
  }

  final guildIds = serverConfigStore.guildIds;
  final serverSettingsStore = ServerSettingsStore(_serverSettingsConfigPath);
  final greetingConfigStore = GreetingConfigStore(_usersConfigPath);
  final channelConfigStore = ChannelConfigStore(_channelsConfigPath);
  final playbackStartDelay = _playbackStartDelayFromEnvironment();
  final LavalinkProcessConfig lavalinkConfig;
  try {
    lavalinkConfig = LavalinkProcessConfig.fromEnvironment();
  } on LavalinkProcessException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
    return;
  }

  final lavalinkProcess = LavalinkProcessManager(lavalinkConfig);
  final lavalink = LavalinkPlugin(
    base: lavalinkConfig.base,
    password: lavalinkConfig.password,
  );
  final voiceGreetingService = VoiceGreetingService(
    isGuildAllowed: serverConfigStore.allows,
    settingsStore: serverSettingsStore,
    greetingStore: greetingConfigStore,
    channelStore: channelConfigStore,
    lavalink: lavalink,
    playbackStartDelay: playbackStartDelay,
  );

  final commands = CommandsPlugin(prefix: null)
    ..check(GuildCheck.anyId(guildIds))
    ..check(
      Check(
        (context) {
          final guildId = context.guild?.id;
          return guildId != null && serverConfigStore.allows(guildId);
        },
        name: 'Configured server check',
        allowsDm: false,
      ),
    )
    ..addCommand(
      ChatCommand(
        'test',
        'Plays test.mp3 in your voice channel.',
        id('test_greeting', (InteractionChatContext context) async {
          final guild = context.guild;
          if (guild == null) {
            await _respondTest(context, 'Run this command in a server.');
            return;
          }

          try {
            final result = await voiceGreetingService.queueTest(
              guild: guild,
              userId: context.user.id,
            );
            await _respondTest(context, _testResponse(result));
          } on ChannelConfigException catch (error) {
            await _respondTest(context, error.message);
          }
        }),
        options: const CommandOptions(
          type: CommandType.slashOnly,
          defaultResponseLevel: ResponseLevel.private,
        ),
      ),
    )
    ..addCommand(
      buildGreetCommandGroup(
        store: greetingConfigStore,
        channelStore: channelConfigStore,
        settingsStore: serverSettingsStore,
      ),
    );

  NyxxGateway? client;
  final shutdownSubscriptions = <StreamSubscription<ProcessSignal>>[];
  try {
    await serverConfigStore.startWatching(
      onLog: (message) => stdout.writeln('Server config: $message'),
      onError: (error) => stderr.writeln('Server config: ${error.message}'),
    );
    await lavalinkProcess.start();

    client = await Nyxx.connectGateway(
      token,
      GatewayIntents.guilds | GatewayIntents.guildVoiceStates,
      options: GatewayClientOptions(plugins: [commands, lavalink]),
    );
    voiceGreetingService.start(client);
    _watchShutdownSignals(client, shutdownSubscriptions);

    stdout.writeln(
      'Voice greet bot connected. Registered commands in ${guildIds.length} guild(s).',
    );

    await client.done;
  } on LavalinkProcessException catch (error) {
    stderr.writeln(error.message);
    exitCode = 70;
  } catch (error, stackTrace) {
    stderr.writeln('Voice greet bot stopped unexpectedly: $error');
    stderr.writeln(stackTrace);
    exitCode = 1;
  } finally {
    for (final subscription in shutdownSubscriptions) {
      await subscription.cancel();
    }

    await serverConfigStore.close();
    await voiceGreetingService.close();
    await _closeClient(client);
    await lavalinkProcess.stop();
  }
}

Future<void> _respondTest(
  InteractionChatContext context,
  String content,
) async {
  await context.respond(
    MessageBuilder(content: content),
    level: ResponseLevel.private,
  );
}

String _testResponse(VoiceGreetingQueueResult result) {
  return switch (result.status) {
    VoiceGreetingQueueStatus.queued =>
      'Queued test greeting in <#${result.channelId!.value}>.',
    VoiceGreetingQueueStatus.notReady => 'Voice playback is not ready yet.',
    VoiceGreetingQueueStatus.notInVoice => 'Join a voice channel first.',
    VoiceGreetingQueueStatus.ignoredChannel =>
      'That voice channel is ignored for greetings.',
    VoiceGreetingQueueStatus.missingAudio =>
      'Could not find $defaultSoundsPath/$testGreetingFilename.',
  };
}

Duration _playbackStartDelayFromEnvironment() {
  final rawValue = Platform.environment[_playbackStartDelayVariable]?.trim();
  if (rawValue == null || rawValue.isEmpty) {
    return defaultPlaybackStartDelay;
  }

  final milliseconds = int.tryParse(rawValue);
  if (milliseconds == null || milliseconds < 0) {
    stderr.writeln(
      'Invalid $_playbackStartDelayVariable="$rawValue"; using default ${defaultPlaybackStartDelay.inMilliseconds}ms.',
    );
    return defaultPlaybackStartDelay;
  }

  return Duration(milliseconds: milliseconds);
}

void _watchShutdownSignals(
  NyxxGateway client,
  List<StreamSubscription<ProcessSignal>> subscriptions,
) {
  for (final signal in _supportedShutdownSignals()) {
    try {
      subscriptions.add(
        signal.watch().listen(
          (_) {
            stdout.writeln('Received $signal; shutting down.');
            unawaited(client.close());
          },
          onError: (Object error) {
            stderr.writeln('Could not watch $signal: $error');
          },
        ),
      );
    } on Object catch (error) {
      stderr.writeln('Could not register $signal shutdown handler: $error');
    }
  }
}

List<ProcessSignal> _supportedShutdownSignals() {
  if (Platform.isWindows) {
    return [ProcessSignal.sigint];
  }

  return [ProcessSignal.sigint, ProcessSignal.sigterm];
}

Future<void> _closeClient(NyxxGateway? client) async {
  if (client == null) {
    return;
  }

  try {
    await client.close();
  } catch (_) {
    // The original shutdown error has already been reported.
  }
}
