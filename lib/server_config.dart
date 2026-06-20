import 'dart:convert';
import 'dart:io';

import 'package:nyxx/nyxx.dart';

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
