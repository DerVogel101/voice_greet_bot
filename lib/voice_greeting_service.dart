import 'dart:async';
import 'dart:io';

import 'package:nyxx/nyxx.dart';
import 'package:nyxx_lavalink/nyxx_lavalink.dart';

import 'channel_config.dart';
import 'greeting_config.dart';

const defaultSoundsPath = 'data/sounds';
const testGreetingFilename = 'test.mp3';
const defaultPlaybackStartDelay = Duration(milliseconds: 500);
const _voiceConnectTimeout = Duration(seconds: 20);

enum VoiceGreetingQueueStatus {
  queued,
  notReady,
  notInVoice,
  ignoredChannel,
  missingAudio,
}

class VoiceGreetingQueueResult {
  const VoiceGreetingQueueResult(this.status, {this.channelId});

  final VoiceGreetingQueueStatus status;
  final Snowflake? channelId;
}

class GuildTaskQueue {
  final Map<String, Future<void>> _tails = {};

  Future<void> enqueue(Snowflake guildId, Future<void> Function() task) {
    final key = _id(guildId);
    final previous = _tails[key] ?? Future<void>.value();

    late final Future<void> next;
    next = previous
        .catchError((Object _, StackTrace _) {})
        .then((_) => task())
        .whenComplete(() {
          if (_tails[key] == next) {
            _tails.remove(key);
          }
        });

    _tails[key] = next;
    return next;
  }
}

class VoiceGreetingService {
  VoiceGreetingService({
    required Iterable<Snowflake> allowedGuildIds,
    required this.greetingStore,
    required this.channelStore,
    required this.lavalink,
    this.soundsPath = defaultSoundsPath,
    this.playbackStartDelay = defaultPlaybackStartDelay,
    GuildTaskQueue? queue,
  }) : _allowedGuildIds = {for (final guildId in allowedGuildIds) _id(guildId)},
       _queue = queue ?? GuildTaskQueue();

  final Set<String> _allowedGuildIds;
  final GreetingConfigStore greetingStore;
  final ChannelConfigStore channelStore;
  final LavalinkPlugin lavalink;
  final String soundsPath;
  final Duration playbackStartDelay;
  final GuildTaskQueue _queue;

  NyxxGateway? _client;
  StreamSubscription<VoiceStateUpdateEvent>? _voiceStateSubscription;

  void start(NyxxGateway client) {
    if (_client != null) {
      throw StateError('VoiceGreetingService has already been started.');
    }

    _client = client;
    _log(
      'Voice greeting service started. Playback start delay: ${playbackStartDelay.inMilliseconds}ms.',
    );
    _voiceStateSubscription = client.onVoiceStateUpdate.listen((event) {
      unawaited(_handleVoiceStateUpdate(event));
    });
  }

  Future<void> close() async {
    await _voiceStateSubscription?.cancel();
    _voiceStateSubscription = null;
    _client = null;
    _log('Voice greeting service stopped.');
  }

  Future<VoiceGreetingQueueResult> queueTest({
    required Guild guild,
    required Snowflake userId,
  }) async {
    if (_client == null) {
      return const VoiceGreetingQueueResult(VoiceGreetingQueueStatus.notReady);
    }

    final channelId = guild.voiceStates[userId]?.channelId;
    if (channelId == null) {
      return const VoiceGreetingQueueResult(
        VoiceGreetingQueueStatus.notInVoice,
      );
    }

    if (await _isIgnored(guild.id, channelId)) {
      return VoiceGreetingQueueResult(
        VoiceGreetingQueueStatus.ignoredChannel,
        channelId: channelId,
      );
    }

    final audio = GreetingAudio.manualFile(testGreetingFilename);
    if (!await _localAudioExists(audio)) {
      return VoiceGreetingQueueResult(
        VoiceGreetingQueueStatus.missingAudio,
        channelId: channelId,
      );
    }

    _enqueue(
      _PlaybackRequest(
        guildId: guild.id,
        userId: userId,
        channelId: channelId,
        audio: audio,
        label: testGreetingFilename,
      ),
    );
    _log(
      'Queued test greeting for user ${userId.value} in channel ${channelId.value}.',
    );

    return VoiceGreetingQueueResult(
      VoiceGreetingQueueStatus.queued,
      channelId: channelId,
    );
  }

  Future<void> _handleVoiceStateUpdate(VoiceStateUpdateEvent event) async {
    final client = _client;
    if (client == null) {
      return;
    }

    final state = event.state;
    final guildId = state.guildId;
    final channelId = state.channelId;

    if (guildId == null ||
        channelId == null ||
        !_allowedGuildIds.contains(_id(guildId)) ||
        state.userId == client.user.id ||
        event.oldState?.channelId == channelId) {
      return;
    }

    try {
      if (await _isIgnored(guildId, channelId)) {
        _log(
          'Ignoring join for user ${state.userId.value}; channel ${channelId.value} is ignored.',
        );
        return;
      }

      final config = await greetingStore.load();
      final audio = config.audioFor(guildId, state.userId);
      if (audio == null) {
        _log(
          'Ignoring join for user ${state.userId.value}; no greeting is configured.',
        );
        return;
      }

      _enqueue(
        _PlaybackRequest(
          guildId: guildId,
          userId: state.userId,
          channelId: channelId,
          audio: audio,
          label: '<@${state.userId.value}>',
        ),
      );
      _log(
        'Queued greeting for user ${state.userId.value} in channel ${channelId.value}.',
      );
    } on GreetingConfigException catch (error) {
      _log(error.message);
    } on ChannelConfigException catch (error) {
      _log(error.message);
    } catch (error, stackTrace) {
      _log('Could not queue greeting: $error\n$stackTrace');
    }
  }

  void _enqueue(_PlaybackRequest request) {
    unawaited(
      _queue.enqueue(request.guildId, () => _playIfStillValid(request)),
    );
  }

  Future<void> _playIfStillValid(_PlaybackRequest request) async {
    try {
      final client = _client;
      if (client == null) {
        _log('Skipping ${request.label}; Discord client is not ready.');
        return;
      }

      final voiceState =
          client.guilds[request.guildId].voiceStates[request.userId];
      if (voiceState?.channelId != request.channelId) {
        _log(
          'Skipping ${request.label}; user is now in ${voiceState?.channelId?.value ?? 'no voice channel'}, expected ${request.channelId.value}.',
        );
        return;
      }

      if (await _isIgnored(request.guildId, request.channelId)) {
        _log(
          'Skipping ${request.label}; channel ${request.channelId.value} is ignored.',
        );
        return;
      }

      if (!await _localAudioExists(request.audio)) {
        _log(
          'Skipping ${request.label}; ${request.audio.resource} does not exist.',
        );
        return;
      }

      _log(
        'Starting playback for ${request.label} in channel ${request.channelId.value}.',
      );
      await _play(request);
    } catch (error, stackTrace) {
      _log('Could not play ${request.label}: $error\n$stackTrace');
    }
  }

  Future<void> _play(_PlaybackRequest request) async {
    final client = _client;
    if (client == null) {
      return;
    }

    final channel = await client.channels[request.channelId].get();
    if (channel is! VoiceChannel) {
      _log('Channel ${request.channelId.value} is not a voice channel.');
      return;
    }

    final guildChannel = channel is GuildChannel
        ? channel as GuildChannel
        : null;
    if (guildChannel == null) {
      _log('Channel ${request.channelId.value} is not a guild voice channel.');
      return;
    }
    await _assertBotCanUseVoiceChannel(guildChannel);

    final completion = Completer<void>();
    LavalinkPlayer? player;
    final subscriptions = <StreamSubscription<dynamic>>[];

    void complete() {
      if (!completion.isCompleted) {
        completion.complete();
      }
    }

    void completeError(Object error, StackTrace stackTrace) {
      if (!completion.isCompleted) {
        completion.completeError(error, stackTrace);
      }
    }

    try {
      _log(
        'Connecting to voice channel ${request.channelId.value} for ${request.label}.',
      );
      player = await _connectLavalinkWithDiagnostics(
        client: client,
        channel: channel,
        request: request,
      );
      _log('Connected to voice channel ${request.channelId.value}.');
      // Give the listener's client a beat to finish joining. Voice UX is a race now, apparently.
      await Future<void>.delayed(playbackStartDelay);

      subscriptions.add(player.onTrackEnd.listen((_) => complete()));
      subscriptions.add(
        player.onTrackException.listen((event) {
          completeError(
            VoiceGreetingPlaybackException(
              event.exception.message ?? event.exception.cause,
            ),
            StackTrace.current,
          );
        }),
      );
      subscriptions.add(
        player.onTrackStuck.listen((_) {
          completeError(
            const VoiceGreetingPlaybackException('Track got stuck.'),
            StackTrace.current,
          );
        }),
      );

      final track = await _loadTrack(request.audio);
      _log('Playing "${track.info.title}" for ${request.label}.');
      await player.play(track);
      await completion.future.timeout(_playbackTimeout(track));
    } on TimeoutException {
      _log('Timed out waiting for ${request.label} to finish.');
    } finally {
      await Future.wait([
        for (final subscription in subscriptions) subscription.cancel(),
      ]);

      if (player != null) {
        await player.disconnect();
      } else {
        client.updateVoiceState(
          request.guildId,
          GatewayVoiceStateBuilder(
            channelId: null,
            isMuted: false,
            isDeafened: false,
          ),
        );
      }
    }
  }

  Future<LavalinkPlayer> _connectLavalinkWithDiagnostics({
    required NyxxGateway client,
    required VoiceChannel channel,
    required _PlaybackRequest request,
  }) async {
    var sawBotVoiceState = false;
    var sawVoiceServerUpdate = false;
    var sawPlayerConnected = false;

    final diagnosticSubscriptions = <StreamSubscription<dynamic>>[
      client.onVoiceStateUpdate.listen((event) {
        final state = event.state;
        if (state.userId != client.user.id ||
            state.guildId != request.guildId) {
          return;
        }

        sawBotVoiceState = true;
        _log(
          'Discord voice state for bot: channel ${state.channelId?.value ?? 'none'}, session ${state.sessionId}.',
        );
      }),
      client.onVoiceServerUpdate.listen((event) {
        if (event.guildId != request.guildId) {
          return;
        }

        sawVoiceServerUpdate = true;
        _log(
          'Discord voice server update for guild ${event.guildId.value}: endpoint ${event.endpoint ?? 'none'}.',
        );
      }),
      lavalink.onPlayerConnected.listen((player) {
        if (player.guildId != request.guildId) {
          return;
        }

        sawPlayerConnected = true;
        _log('Lavalink player connected for guild ${player.guildId.value}.');
      }),
    ];

    try {
      return await channel.connectLavalink().timeout(
        _voiceConnectTimeout,
        onTimeout: () {
          throw VoiceGreetingPlaybackException(
            'Timed out connecting to voice channel ${request.channelId.value}. '
            'botVoiceState=$sawBotVoiceState, '
            'voiceServerUpdate=$sawVoiceServerUpdate, '
            'playerConnected=$sawPlayerConnected.',
          );
        },
      );
    } finally {
      await Future.wait([
        for (final subscription in diagnosticSubscriptions)
          subscription.cancel(),
      ]);
    }
  }

  Future<Track> _loadTrack(GreetingAudio audio) async {
    final identifier = resolveAudioIdentifier(audio, soundsPath: soundsPath);
    _log('Loading audio identifier "$identifier".');
    final result = await lavalink.loadTrack(identifier);

    return switch (result) {
      TrackLoadResult(:final data) => data,
      PlaylistLoadResult(:final data) when data.tracks.isNotEmpty =>
        data.tracks.first,
      SearchLoadResult(:final data) when data.isNotEmpty => data.first,
      EmptyLoadResult() => throw VoiceGreetingPlaybackException(
        'Lavalink found no playable track for $identifier.',
      ),
      ErrorLoadResult(:final data) => throw VoiceGreetingPlaybackException(
        data.message ?? data.cause,
      ),
      _ => throw VoiceGreetingPlaybackException(
        'Lavalink returned an unsupported load result for $identifier.',
      ),
    };
  }

  Future<void> _assertBotCanUseVoiceChannel(GuildChannel channel) async {
    final botId = _client?.user.id;
    if (botId == null) {
      throw const VoiceGreetingPlaybackException(
        'Discord client is not ready.',
      );
    }

    final guild = await channel.guild.get();
    final botMember = await guild.members[botId].get();
    final permissions = _permissionsFor(guild, channel, botMember);
    final missing = <String>[
      if (!permissions.has(Permissions.viewChannel)) 'View Channel',
      if (!permissions.has(Permissions.connect)) 'Connect',
      if (!permissions.has(Permissions.speak)) 'Speak',
    ];

    _log(
      'Bot permissions in voice channel ${channel.id.value}: '
      'view=${permissions.has(Permissions.viewChannel)}, '
      'connect=${permissions.has(Permissions.connect)}, '
      'speak=${permissions.has(Permissions.speak)}.',
    );

    if (missing.isNotEmpty) {
      throw VoiceGreetingPlaybackException(
        'Bot is missing ${missing.join(', ')} in voice channel ${channel.id.value}.',
      );
    }
  }

  Future<bool> _isIgnored(Snowflake guildId, Snowflake channelId) async {
    final config = await channelStore.load();
    return config.isIgnored(guildId, channelId);
  }

  Future<bool> _localAudioExists(GreetingAudio audio) async {
    if (!audio.file) {
      return true;
    }

    return File(
      localAudioPath(audio.resource, soundsPath: soundsPath),
    ).exists();
  }
}

Permissions _permissionsFor(Guild guild, GuildChannel channel, Member member) {
  if (guild.ownerId == member.id) {
    return Permissions.allPermissions;
  }

  var permissions = _rolePermissions(guild, guild.id);
  for (final roleId in member.roleIds) {
    permissions |= _rolePermissions(guild, roleId);
  }

  if (Permissions(permissions).has(Permissions.administrator)) {
    return Permissions.allPermissions;
  }

  final everyoneOverwrite = channel.permissionOverwrites
      .where(
        (overwrite) =>
            overwrite.type == PermissionOverwriteType.role &&
            overwrite.id == guild.id,
      )
      .firstOrNull;
  if (everyoneOverwrite != null) {
    permissions &= ~everyoneOverwrite.deny.value;
    permissions |= everyoneOverwrite.allow.value;
  }

  var roleAllow = 0;
  var roleDeny = 0;
  for (final overwrite in channel.permissionOverwrites) {
    if (overwrite.type != PermissionOverwriteType.role ||
        !member.roleIds.contains(overwrite.id)) {
      continue;
    }

    roleDeny |= overwrite.deny.value;
    roleAllow |= overwrite.allow.value;
  }

  permissions &= ~roleDeny;
  permissions |= roleAllow;

  final memberOverwrite = channel.permissionOverwrites
      .where(
        (overwrite) =>
            overwrite.type == PermissionOverwriteType.member &&
            overwrite.id == member.id,
      )
      .firstOrNull;
  if (memberOverwrite != null) {
    permissions &= ~memberOverwrite.deny.value;
    permissions |= memberOverwrite.allow.value;
  }

  return Permissions(permissions);
}

int _rolePermissions(Guild guild, Snowflake roleId) {
  for (final role in guild.roleList) {
    if (role.id == roleId) {
      return role.permissions.value;
    }
  }

  return 0;
}

class VoiceGreetingPlaybackException implements Exception {
  const VoiceGreetingPlaybackException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _PlaybackRequest {
  const _PlaybackRequest({
    required this.guildId,
    required this.userId,
    required this.channelId,
    required this.audio,
    required this.label,
  });

  final Snowflake guildId;
  final Snowflake userId;
  final Snowflake channelId;
  final GreetingAudio audio;
  final String label;
}

String resolveAudioIdentifier(
  GreetingAudio audio, {
  String soundsPath = defaultSoundsPath,
}) {
  if (!audio.file) {
    return audio.resource;
  }

  return File(
    localAudioPath(audio.resource, soundsPath: soundsPath),
  ).absolute.path;
}

String localAudioPath(
  String filename, {
  String soundsPath = defaultSoundsPath,
}) {
  final needsSeparator =
      !soundsPath.endsWith('/') && !soundsPath.endsWith(r'\');

  return needsSeparator
      ? '$soundsPath${Platform.pathSeparator}$filename'
      : '$soundsPath$filename';
}

Duration _playbackTimeout(Track track) {
  final length = track.info.length;
  if (track.info.isStream || length <= Duration.zero) {
    return const Duration(minutes: 10);
  }

  // Give Lavalink a little grace after the advertised duration.
  // Humanity has invented distributed audio timing. Truly touching.
  return length + const Duration(seconds: 15);
}

String _id(Snowflake id) => id.value.toString();

void _log(String message) {
  stderr.writeln('Voice greeting: $message');
}
