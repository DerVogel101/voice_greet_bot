import 'dart:convert';
import 'dart:io';

import 'package:nyxx/nyxx.dart';

const _jsonIndent = '  ';

class ChannelConfigException implements Exception {
  const ChannelConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ChannelConfig {
  ChannelConfig._(this._guilds);

  factory ChannelConfig.empty() => ChannelConfig._({});

  factory ChannelConfig.parse(
    String source, {
    String sourceName = 'channel config',
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw ChannelConfigException(
        'Could not parse $sourceName as JSON: ${error.message}.',
      );
    }

    if (decoded is! Map) {
      throw ChannelConfigException(
        '$sourceName must be a JSON object keyed by Discord guild ID.',
      );
    }

    final guilds = <String, Set<String>>{};

    for (final guildEntry in decoded.entries) {
      final guildId = _parseIdKey(guildEntry.key, '$sourceName guild ID');

      final channelsValue = guildEntry.value;
      if (channelsValue is! Map) {
        throw ChannelConfigException(
          '$sourceName.$guildId must be an object keyed by Discord channel ID.',
        );
      }

      final channels = <String>{};
      for (final channelEntry in channelsValue.entries) {
        final channelId = _parseIdKey(
          channelEntry.key,
          '$sourceName.$guildId channel ID',
        );

        _validateIgnoredChannel(
          channelEntry.value,
          '$sourceName.$guildId.$channelId',
        );
        channels.add(channelId);
      }

      guilds[guildId] = channels;
    }

    return ChannelConfig._(guilds);
  }

  final Map<String, Set<String>> _guilds;

  List<String> ignoredChannelIdsForGuild(Snowflake guildId) {
    final channelIds = _guilds[_id(guildId)];
    if (channelIds == null) {
      return const [];
    }

    return List.unmodifiable(channelIds.toList()..sort());
  }

  bool isIgnored(Snowflake guildId, Snowflake channelId) {
    return _guilds[_id(guildId)]?.contains(_id(channelId)) ?? false;
  }

  bool ignore(Snowflake guildId, Snowflake channelId) {
    final channels = _guilds.putIfAbsent(_id(guildId), () => <String>{});
    return channels.add(_id(channelId));
  }

  bool allow(Snowflake guildId, Snowflake channelId) {
    final guildKey = _id(guildId);
    final channels = _guilds[guildKey];

    if (channels == null || !channels.remove(_id(channelId))) {
      return false;
    }

    if (channels.isEmpty) {
      _guilds.remove(guildKey);
    }

    return true;
  }

  Map<String, Object> toJson() {
    final result = <String, Object>{};

    for (final guildId in _guilds.keys.toList()..sort()) {
      final channels = _guilds[guildId]!;
      result[guildId] = {
        for (final channelId in channels.toList()..sort())
          channelId: {'ignore': true},
      };
    }

    return result;
  }

  String toPrettyJson() =>
      '${const JsonEncoder.withIndent(_jsonIndent).convert(toJson())}\n';
}

class ChannelConfigStore {
  ChannelConfigStore(this.path);

  final String path;

  Future<ChannelConfig> load() async {
    final file = File(path);
    if (!await file.exists()) {
      return ChannelConfig.empty();
    }

    final String source;
    try {
      source = await file.readAsString();
    } on FileSystemException {
      throw ChannelConfigException('Could not read $path.');
    }

    return ChannelConfig.parse(source, sourceName: path);
  }

  Future<void> save(ChannelConfig config) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(config.toPrettyJson());
  }

  Future<bool> ignore({
    required Snowflake guildId,
    required Snowflake channelId,
  }) async {
    final config = await load();
    final changed = config.ignore(guildId, channelId);

    if (changed) {
      await save(config);
    }

    return changed;
  }

  Future<bool> allow({
    required Snowflake guildId,
    required Snowflake channelId,
  }) async {
    final config = await load();
    final changed = config.allow(guildId, channelId);

    if (changed) {
      await save(config);
    }

    return changed;
  }
}

String _id(Snowflake id) => id.value.toString();

String _parseIdKey(Object? key, String label) {
  if (key is! String || key.isEmpty || int.tryParse(key) == null) {
    throw ChannelConfigException('$label must be a positive Discord ID.');
  }

  if (int.parse(key) <= 0) {
    throw ChannelConfigException('$label must be a positive Discord ID.');
  }

  return key;
}

void _validateIgnoredChannel(Object? value, String sourcePath) {
  if (value is! Map) {
    throw ChannelConfigException('$sourcePath must be an object.');
  }

  final ignore = value['ignore'];
  if (ignore is! bool) {
    throw ChannelConfigException('$sourcePath.ignore must be a boolean.');
  }

  if (!ignore) {
    throw ChannelConfigException('$sourcePath.ignore must be true.');
  }
}
