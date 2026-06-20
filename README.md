# Voice Greet Bot

Stage one is a Discord bot with a guild-only `/test` slash command. Running
`/test` sends `test` in the same channel.

## Discord setup

Invite the bot with these OAuth2 scopes:

- `bot`
- `applications.commands`

The command is registered only in guilds listed in `data/servers.json`, so
updates should appear quickly while testing.

## Configuration

Set the bot token in PowerShell:

```powershell
$env:DISCORD_TOKEN = 'your-bot-token'
```

Add one or more guild IDs to `data/servers.json`:

```json
["123456789012345678"]
```

The file must be a non-empty JSON array of Discord guild ID strings or integers.

## Run

From the project root:

```powershell
dart pub get
dart run
```

If `DISCORD_TOKEN` or `data/servers.json` is missing or invalid, startup fails
with a clear error.
