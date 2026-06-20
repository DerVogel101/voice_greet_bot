import 'dart:convert';
import 'dart:io';

import 'package:nyxx/nyxx.dart';

const _jsonIndent = '  ';
const _soundsPath = 'data/sounds';

class GreetingConfigException implements Exception {
  const GreetingConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GreetingAudio {
  const GreetingAudio._({required this.file, required this.resource});

  factory GreetingAudio.onlineUrl(String url) {
    final normalized = url.trim();
    _validateOnlineUrl(normalized);

    return GreetingAudio._(file: false, resource: normalized);
  }

  factory GreetingAudio.manualFile(String filename) {
    final normalized = filename.trim();
    _validateManualFilename(normalized);

    return GreetingAudio._(file: true, resource: normalized);
  }

  factory GreetingAudio.fromJson(Object? value, String sourcePath) {
    if (value is! Map) {
      throw GreetingConfigException('$sourcePath must be an object.');
    }

    final file = value['file'];
    final resource = value['resource'];

    if (file is! bool) {
      throw GreetingConfigException('$sourcePath.file must be a boolean.');
    }

    if (resource is! String) {
      throw GreetingConfigException('$sourcePath.resource must be a string.');
    }

    return file
        ? GreetingAudio.manualFile(resource)
        : GreetingAudio.onlineUrl(resource);
  }

  final bool file;
  final String resource;

  Map<String, Object> toJson() => {'file': file, 'resource': resource};

  String get typeLabel => file ? 'file' : 'url';
}

class GreetingConfig {
  GreetingConfig._(this._guilds);

  factory GreetingConfig.empty() => GreetingConfig._({});

  factory GreetingConfig.parse(
    String source, {
    String sourceName = 'greeting config',
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw GreetingConfigException(
        'Could not parse $sourceName as JSON: ${error.message}.',
      );
    }

    if (decoded is! Map) {
      throw GreetingConfigException(
        '$sourceName must be a JSON object keyed by Discord guild ID.',
      );
    }

    final guilds = <String, Map<String, GreetingAudio>>{};

    for (final guildEntry in decoded.entries) {
      final guildId = _parseIdKey(guildEntry.key, '$sourceName guild ID');

      final usersValue = guildEntry.value;
      if (usersValue is! Map) {
        throw GreetingConfigException(
          '$sourceName.$guildId must be an object keyed by Discord user ID.',
        );
      }

      final users = <String, GreetingAudio>{};
      for (final userEntry in usersValue.entries) {
        final userId = _parseIdKey(
          userEntry.key,
          '$sourceName.$guildId user ID',
        );

        users[userId] = GreetingAudio.fromJson(
          userEntry.value,
          '$sourceName.$guildId.$userId',
        );
      }

      guilds[guildId] = users;
    }

    return GreetingConfig._(guilds);
  }

  final Map<String, Map<String, GreetingAudio>> _guilds;

  Map<String, GreetingAudio> entriesForGuild(Snowflake guildId) {
    final guildEntries = _guilds[_id(guildId)];
    if (guildEntries == null) {
      return const {};
    }

    return Map.unmodifiable(_sortedMap(guildEntries));
  }

  GreetingAudio? audioFor(Snowflake guildId, Snowflake userId) {
    return _guilds[_id(guildId)]?[_id(userId)];
  }

  void setOnlineUrl(Snowflake guildId, Snowflake userId, String url) {
    final guildKey = _id(guildId);
    final userKey = _id(userId);
    final users = _guilds.putIfAbsent(guildKey, () => {});

    users[userKey] = GreetingAudio.onlineUrl(url);
  }

  bool remove(Snowflake guildId, Snowflake userId) {
    final guildKey = _id(guildId);
    final userKey = _id(userId);
    final users = _guilds[guildKey];

    if (users == null || users.remove(userKey) == null) {
      return false;
    }

    if (users.isEmpty) {
      _guilds.remove(guildKey);
    }

    return true;
  }

  Map<String, Object> toJson() {
    final result = <String, Object>{};

    for (final guildId in _guilds.keys.toList()..sort()) {
      final users = _guilds[guildId]!;
      result[guildId] = {
        for (final userId in users.keys.toList()..sort())
          userId: users[userId]!.toJson(),
      };
    }

    return result;
  }

  String toPrettyJson() =>
      '${const JsonEncoder.withIndent(_jsonIndent).convert(toJson())}\n';
}

class GreetingConfigStore {
  GreetingConfigStore(this.path);

  final String path;

  Future<GreetingConfig> load() async {
    final file = File(path);
    if (!await file.exists()) {
      return GreetingConfig.empty();
    }

    final String source;
    try {
      source = await file.readAsString();
    } on FileSystemException {
      throw GreetingConfigException('Could not read $path.');
    }

    return GreetingConfig.parse(source, sourceName: path);
  }

  Future<void> save(GreetingConfig config) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(config.toPrettyJson());
  }

  Future<void> setOnlineUrl({
    required Snowflake guildId,
    required Snowflake userId,
    required String url,
  }) async {
    final config = await load();
    config.setOnlineUrl(guildId, userId, url);

    await save(config);
  }

  Future<bool> remove({
    required Snowflake guildId,
    required Snowflake userId,
  }) async {
    final config = await load();
    final removed = config.remove(guildId, userId);

    if (removed) {
      await save(config);
    }

    return removed;
  }
}

Map<String, GreetingAudio> _sortedMap(Map<String, GreetingAudio> source) => {
  for (final key in source.keys.toList()..sort()) key: source[key]!,
};

String _id(Snowflake id) => id.value.toString();

String _parseIdKey(Object? key, String label) {
  if (key is! String || key.isEmpty || int.tryParse(key) == null) {
    throw GreetingConfigException('$label must be a positive Discord ID.');
  }

  if (int.parse(key) <= 0) {
    throw GreetingConfigException('$label must be a positive Discord ID.');
  }

  return key;
}

void _validateOnlineUrl(String resource) {
  final uri = Uri.tryParse(resource);
  if (uri == null ||
      !uri.hasScheme ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw GreetingConfigException(
      'Online greeting audio must be an http or https URL.',
    );
  }
}

void _validateManualFilename(String resource) {
  final hasWindowsDrive = RegExp(r'^[A-Za-z]:').hasMatch(resource);

  // The Discord UI only writes URLs; local files stay a manual escape hatch.
  // Naturally, the escape hatch still needs a lock, because path traversal exists.
  if (resource.isEmpty ||
      resource.contains('/') ||
      resource.contains(r'\') ||
      resource.contains('..') ||
      resource.startsWith('.') ||
      resource.contains(':') ||
      hasWindowsDrive) {
    throw GreetingConfigException(
      'Manual file resources must be filenames inside $_soundsPath.',
    );
  }
}
