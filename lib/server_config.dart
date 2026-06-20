import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nyxx/nyxx.dart';

const _serverConfigWatchDebounce = Duration(milliseconds: 500);
const _serverConfigPollInterval = Duration(seconds: 5);
const _jsonIndent = '  ';

typedef ServerConfigErrorHandler = void Function(ServerConfigException error);
typedef ServerConfigLogHandler = void Function(String message);

class ServerConfigException implements Exception {
  const ServerConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<List<Snowflake>> loadGuildIdsFromFile(String path) async {
  final String source;
  try {
    source = await File(path).readAsString();
  } on FileSystemException {
    throw ServerConfigException(
      'Could not read $path. Create it as a JSON array of Discord guild IDs.',
    );
  }

  return parseGuildIds(source, sourceName: path);
}

class ServerConfigStore {
  ServerConfigStore(
    this.path, {
    this.watchDebounce = _serverConfigWatchDebounce,
    this.pollInterval = _serverConfigPollInterval,
  });

  final String path;
  final Duration watchDebounce;
  final Duration pollInterval;

  List<Snowflake> _guildIds = const [];
  Set<String> _guildIdSet = const {};
  StreamSubscription<FileSystemEvent>? _watchSubscription;
  Timer? _debounceTimer;
  Timer? _pollTimer;
  _FileSnapshot? _lastSnapshot;

  List<Snowflake> get guildIds => List.unmodifiable(_guildIds);

  bool allows(Snowflake guildId) => _guildIdSet.contains(_id(guildId));

  Future<void> loadRequired() async {
    _replaceGuildIds(await loadGuildIdsFromFile(path));
    _lastSnapshot = await _snapshot();
  }

  Future<bool> reloadKeepingLast({
    ServerConfigErrorHandler? onError,
    ServerConfigLogHandler? onLog,
  }) async {
    try {
      final guildIds = await loadGuildIdsFromFile(path);
      final changed = _replaceGuildIds(guildIds);
      _lastSnapshot = await _snapshot();

      if (changed) {
        onLog?.call(
          'Reloaded $path with ${_guildIds.length} allowed guild(s).',
        );
      }
      return true;
    } on ServerConfigException catch (error) {
      _lastSnapshot = await _snapshot();
      onError?.call(error);
      return false;
    }
  }

  Future<void> startWatching({
    ServerConfigErrorHandler? onError,
    ServerConfigLogHandler? onLog,
  }) async {
    await close();
    _lastSnapshot = await _snapshot();

    final target = File(path).absolute;
    try {
      _watchSubscription = target.parent.watch().listen(
        (event) {
          if (!_isTargetEvent(event, target)) {
            return;
          }

          _scheduleReload(onError: onError, onLog: onLog);
        },
        onError: (Object error) {
          onLog?.call('Could not watch $path: $error. Polling will continue.');
        },
      );
    } on Object catch (error) {
      onLog?.call('Could not watch $path: $error. Polling will continue.');
    }

    _pollTimer = Timer.periodic(pollInterval, (_) {
      unawaited(_reloadIfChanged(onError: onError, onLog: onLog));
    });
  }

  Future<void> close() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;

    _pollTimer?.cancel();
    _pollTimer = null;

    await _watchSubscription?.cancel();
    _watchSubscription = null;
  }

  bool _replaceGuildIds(List<Snowflake> guildIds) {
    final nextSet = {for (final guildId in guildIds) _id(guildId)};
    final changed = !_sameSet(_guildIdSet, nextSet);

    _guildIds = List.unmodifiable(guildIds);
    _guildIdSet = Set.unmodifiable(nextSet);

    return changed;
  }

  void _scheduleReload({
    ServerConfigErrorHandler? onError,
    ServerConfigLogHandler? onLog,
  }) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(watchDebounce, () {
      unawaited(reloadKeepingLast(onError: onError, onLog: onLog));
    });
  }

  Future<void> _reloadIfChanged({
    ServerConfigErrorHandler? onError,
    ServerConfigLogHandler? onLog,
  }) async {
    final snapshot = await _snapshot();
    if (_lastSnapshot == snapshot) {
      return;
    }

    await reloadKeepingLast(onError: onError, onLog: onLog);
  }

  Future<_FileSnapshot?> _snapshot() async {
    final stat = await File(path).stat();
    if (stat.type == FileSystemEntityType.notFound) {
      return null;
    }

    return _FileSnapshot(modified: stat.modified, size: stat.size);
  }
}

class ServerSettingsConfig {
  ServerSettingsConfig._(this._volumes);

  factory ServerSettingsConfig.empty() => ServerSettingsConfig._({});

  factory ServerSettingsConfig.parse(
    String source, {
    String sourceName = 'server settings config',
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw ServerConfigException(
        'Could not parse $sourceName as JSON: ${error.message}.',
      );
    }

    if (decoded is! Map) {
      throw ServerConfigException(
        '$sourceName must be a JSON object keyed by Discord guild ID.',
      );
    }

    final volumes = <String, int>{};
    for (final guildEntry in decoded.entries) {
      final guildId = _parseGuildIdKey(guildEntry.key, '$sourceName guild ID');

      final settingsValue = guildEntry.value;
      if (settingsValue is! Map) {
        throw ServerConfigException('$sourceName.$guildId must be an object.');
      }

      if (!settingsValue.containsKey('volume')) {
        throw ServerConfigException('$sourceName.$guildId.volume is required.');
      }

      final volume = settingsValue['volume'];
      validateVolume(volume, '$sourceName.$guildId.volume');
      volumes[guildId] = volume as int;
    }

    return ServerSettingsConfig._(volumes);
  }

  static const minVolume = 0;
  static const maxVolume = 100;
  static const defaultVolume = 100;

  final Map<String, int> _volumes;

  int volumeFor(Snowflake guildId) {
    return _volumes[_id(guildId)] ?? defaultVolume;
  }

  void setVolume(Snowflake guildId, int volume) {
    validateVolume(volume, 'volume');
    _volumes[_id(guildId)] = volume;
  }

  Map<String, Object> toJson() {
    final result = <String, Object>{};

    for (final guildId in _volumes.keys.toList()..sort()) {
      result[guildId] = {'volume': _volumes[guildId]!};
    }

    return result;
  }

  String toPrettyJson() =>
      '${const JsonEncoder.withIndent(_jsonIndent).convert(toJson())}\n';

  static bool isValidVolume(int volume) {
    return volume >= minVolume && volume <= maxVolume;
  }

  static void validateVolume(Object? value, String sourcePath) {
    if (value is! int || !isValidVolume(value)) {
      throw ServerConfigException(
        '$sourcePath must be an integer from $minVolume to $maxVolume.',
      );
    }
  }
}

class ServerSettingsStore {
  ServerSettingsStore(this.path);

  final String path;

  Future<ServerSettingsConfig> load() async {
    final file = File(path);
    if (!await file.exists()) {
      return ServerSettingsConfig.empty();
    }

    final String source;
    try {
      source = await file.readAsString();
    } on FileSystemException {
      throw ServerConfigException('Could not read $path.');
    }

    return ServerSettingsConfig.parse(source, sourceName: path);
  }

  Future<void> save(ServerSettingsConfig config) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(config.toPrettyJson());
  }

  Future<int> volumeFor(Snowflake guildId) async {
    final config = await load();
    return config.volumeFor(guildId);
  }

  Future<void> setVolume({
    required Snowflake guildId,
    required int volume,
  }) async {
    final config = await load();
    config.setVolume(guildId, volume);
    await save(config);
  }
}

List<Snowflake> parseGuildIds(
  String source, {
  String sourceName = 'servers config',
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (error) {
    throw ServerConfigException(
      'Could not parse $sourceName as JSON: ${error.message}.',
    );
  }

  if (decoded is! List<Object?>) {
    throw ServerConfigException(
      '$sourceName must be a JSON array of Discord guild IDs.',
    );
  }

  if (decoded.isEmpty) {
    throw ServerConfigException(
      '$sourceName must contain at least one Discord guild ID.',
    );
  }

  return [
    for (var index = 0; index < decoded.length; index++)
      _parseGuildId(decoded[index], sourceName, index),
  ];
}

Snowflake _parseGuildId(Object? value, String sourceName, int index) {
  final int? parsed = switch (value) {
    final String text => int.tryParse(text.trim()),
    final int number => number,
    _ => null,
  };

  // Discord IDs look numeric, so naturally JSON gives us several ways to get them wrong.
  if (parsed == null || parsed <= 0) {
    throw ServerConfigException(
      '$sourceName entry $index must be a positive Discord guild ID string or integer.',
    );
  }

  return Snowflake(parsed);
}

String _parseGuildIdKey(Object? key, String label) {
  if (key is! String || key.isEmpty || int.tryParse(key) == null) {
    throw ServerConfigException('$label must be a positive Discord ID.');
  }

  if (int.parse(key) <= 0) {
    throw ServerConfigException('$label must be a positive Discord ID.');
  }

  return key;
}

String _id(Snowflake id) => id.value.toString();

bool _sameSet(Set<String> left, Set<String> right) {
  if (left.length != right.length) {
    return false;
  }

  return left.containsAll(right);
}

bool _isTargetEvent(FileSystemEvent event, File target) {
  final eventPath = File(event.path).absolute.path;
  final targetPath = target.path;

  if (Platform.isWindows) {
    return eventPath.toLowerCase() == targetPath.toLowerCase();
  }

  return eventPath == targetPath;
}

class _FileSnapshot {
  const _FileSnapshot({required this.modified, required this.size});

  final DateTime modified;
  final int size;

  @override
  bool operator ==(Object other) =>
      other is _FileSnapshot &&
      other.modified == modified &&
      other.size == size;

  @override
  int get hashCode => Object.hash(modified, size);
}
