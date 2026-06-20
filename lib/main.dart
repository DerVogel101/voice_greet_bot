import 'dart:io';

import 'package:nyxx/nyxx.dart';
import 'package:nyxx_commands/nyxx_commands.dart';

import 'server_config.dart';

const _discordTokenVariable = 'DISCORD_TOKEN';
const _serversConfigPath = 'data/servers.json';

Future<void> main() async {
  final token = Platform.environment[_discordTokenVariable]?.trim();
  if (token == null || token.isEmpty) {
    stderr.writeln('Missing $_discordTokenVariable environment variable.');
    exitCode = 64;
    return;
  }

  final List<Snowflake> guildIds;
  try {
    guildIds = await loadGuildIdsFromFile(_serversConfigPath);
  } on ServerConfigException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
    return;
  }

  final commands = CommandsPlugin(prefix: null)
    ..addCommand(
      ChatCommand(
        'test',
        'Replies with test.',
        (InteractionChatContext context) async {
          await context.respond(MessageBuilder(content: 'test'));
        },
        checks: [GuildCheck.anyId(guildIds)],
        options: const CommandOptions(type: CommandType.slashOnly),
      ),
    );

  await Nyxx.connectGateway(
    token,
    GatewayIntents.guilds,
    options: GatewayClientOptions(plugins: [commands]),
  );

  stdout.writeln(
    'Voice greet bot connected. Registered /test in ${guildIds.length} guild(s).',
  );
}
