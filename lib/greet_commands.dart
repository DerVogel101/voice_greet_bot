import 'package:nyxx/nyxx.dart';
import 'package:nyxx_commands/nyxx_commands.dart';

import 'channel_config.dart';
import 'greeting_config.dart';

const _maxMessageLength = 1800;

ChatGroup buildGreetCommandGroup({
  required GreetingConfigStore store,
  required ChannelConfigStore channelStore,
}) {
  Future<void> listGreetings(InteractionChatContext context) async {
    final guildId = context.guild?.id;
    if (guildId == null) {
      await _respond(context, 'Run this command in a server.');
      return;
    }

    try {
      final config = await store.load();
      final entries = config.entriesForGuild(guildId);

      if (entries.isEmpty) {
        await _respond(context, 'No greeting audio is configured here.');
        return;
      }

      final lines = entries.entries.map((entry) {
        final audio = entry.value;
        return '<@${entry.key}> (${entry.key}): ${audio.typeLabel} ${audio.resource}';
      });

      for (final chunk in _chunkLines('Configured greeting audio:', lines)) {
        await _respond(context, chunk);
      }
    } on GreetingConfigException catch (error) {
      await _respond(context, error.message);
    }
  }

  Future<void> setGreeting(
    InteractionChatContext context,
    @Description('User to greet') User user,
    @Description('Online audio URL') String url,
  ) async {
    final guildId = context.guild?.id;
    if (guildId == null) {
      await _respond(context, 'Run this command in a server.');
      return;
    }

    try {
      await store.setOnlineUrl(guildId: guildId, userId: user.id, url: url);
      await _respond(
        context,
        'Greeting audio for <@${user.id.value}> is now set to ${url.trim()}.',
      );
    } on GreetingConfigException catch (error) {
      await _respond(context, error.message);
    }
  }

  Future<void> removeGreeting(
    InteractionChatContext context,
    @Description('User to remove') User user,
  ) async {
    final guildId = context.guild?.id;
    if (guildId == null) {
      await _respond(context, 'Run this command in a server.');
      return;
    }

    try {
      final removed = await store.remove(guildId: guildId, userId: user.id);

      await _respond(
        context,
        removed
            ? 'Removed greeting audio for <@${user.id.value}>.'
            : 'No greeting audio was configured for <@${user.id.value}>.',
      );
    } on GreetingConfigException catch (error) {
      await _respond(context, error.message);
    }
  }

  Future<void> listIgnoredChannels(InteractionChatContext context) async {
    final guildId = context.guild?.id;
    if (guildId == null) {
      await _respond(context, 'Run this command in a server.');
      return;
    }

    try {
      final config = await channelStore.load();
      final channelIds = config.ignoredChannelIdsForGuild(guildId);

      if (channelIds.isEmpty) {
        await _respond(context, 'No voice channels are ignored here.');
        return;
      }

      final lines = channelIds.map((id) => '<#$id> ($id)');
      for (final chunk in _chunkLines('Ignored voice channels:', lines)) {
        await _respond(context, chunk);
      }
    } on ChannelConfigException catch (error) {
      await _respond(context, error.message);
    }
  }

  Future<void> ignoreChannel(
    InteractionChatContext context,
    @Description('Voice channel to ignore') GuildVoiceChannel channel,
  ) async {
    final guildId = context.guild?.id;
    if (guildId == null) {
      await _respond(context, 'Run this command in a server.');
      return;
    }

    try {
      final changed = await channelStore.ignore(
        guildId: guildId,
        channelId: channel.id,
      );

      await _respond(
        context,
        changed
            ? 'Ignoring voice channel <#${channel.id.value}>.'
            : 'Voice channel <#${channel.id.value}> is already ignored.',
      );
    } on ChannelConfigException catch (error) {
      await _respond(context, error.message);
    }
  }

  Future<void> allowChannel(
    InteractionChatContext context,
    @Description('Voice channel to allow') GuildVoiceChannel channel,
  ) async {
    final guildId = context.guild?.id;
    if (guildId == null) {
      await _respond(context, 'Run this command in a server.');
      return;
    }

    try {
      final changed = await channelStore.allow(
        guildId: guildId,
        channelId: channel.id,
      );

      await _respond(
        context,
        changed
            ? 'Allowing greetings in voice channel <#${channel.id.value}>.'
            : 'Voice channel <#${channel.id.value}> was not ignored.',
      );
    } on ChannelConfigException catch (error) {
      await _respond(context, error.message);
    }
  }

  return ChatGroup(
    'greet',
    'Manage voice greeting audio.',
    children: [
      ChatCommand('list', 'List configured greeting audio.', listGreetings),
      ChatCommand('set', 'Add or update online greeting audio.', setGreeting),
      ChatCommand(
        'remove',
        'Remove greeting audio for a user.',
        removeGreeting,
      ),
      ChatGroup(
        'channels',
        'Manage ignored voice channels.',
        children: [
          ChatCommand(
            'list',
            'List ignored voice channels.',
            listIgnoredChannels,
          ),
          ChatCommand(
            'ignore',
            'Ignore a voice channel for greetings.',
            ignoreChannel,
          ),
          ChatCommand(
            'allow',
            'Allow greetings in a voice channel again.',
            allowChannel,
          ),
        ],
      ),
    ],
    checks: [
      PermissionsCheck(
        Permissions.manageGuild,
        requiresAll: true,
        allowsDm: false,
      ),
    ],
    options: const CommandOptions(
      type: CommandType.slashOnly,
      defaultResponseLevel: ResponseLevel.private,
    ),
  );
}

Future<void> _respond(InteractionChatContext context, String content) async {
  await context.respond(
    MessageBuilder(content: content),
    level: ResponseLevel.private,
  );
}

Iterable<String> _chunkLines(String header, Iterable<String> lines) sync* {
  var current = header;

  for (final line in lines) {
    final next = '$current\n$line';
    if (next.length <= _maxMessageLength) {
      current = next;
      continue;
    }

    yield current;

    if ('$header\n$line'.length <= _maxMessageLength) {
      current = '$header\n$line';
      continue;
    }

    for (final part in _chunkText(
      line,
      _maxMessageLength - header.length - 1,
    )) {
      yield '$header\n$part';
    }

    current = header;
  }

  if (current != header) {
    yield current;
  }
}

Iterable<String> _chunkText(String text, int maxLength) sync* {
  var start = 0;
  while (start < text.length) {
    final end = (start + maxLength).clamp(0, text.length);
    yield text.substring(start, end);
    start = end;
  }
}
