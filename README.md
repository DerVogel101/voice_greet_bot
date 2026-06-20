# Voice Greet Bot

This is a Discord bot that plays short greeting audio when configured users join
voice channels on allowed servers. It connects through a local Lavalink node and
leaves the voice channel after playback finishes.

It also has guild-only `/greet` slash commands for managing greeting audio
configuration in `data/users.json` and ignored voice channels in
`data/channels.json`, plus per-server playback volume in
`data/server_config.json`.

## Discord setup

Invite the bot with these OAuth2 scopes:

- `bot`
- `applications.commands`

The bot needs permission to view, connect to, and speak in voice channels where
greetings should play.

All bot slash commands are registered only in guilds listed in
`data/servers.json`, and command execution is also guarded by that same list.
Updates should appear quickly while testing.

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

Per-server bot settings are configured in `data/server_config.json`. This file
is ignored by Git because it is live server data; use
`data/server_config.example.json` as the template. The shape is:

```json
{
  "617718300851306516": {
    "volume": 100
  }
}
```

`volume` is a percentage from `0` to `100`. Missing servers default to `100`.
Whenever the bot writes `data/server_config.json`, it uses two-space indentation
and a trailing newline.

Greeting audio is configured in `data/users.json`. This file is intentionally
ignored by Git because it is live server data. The shape is:

```json
{
  "617718300851306516": {
    "543801897916694529": {
      "file": false,
      "resource": "https://example.com/greeting.mp3"
    }
  }
}
```

Set `"file": false` for online audio URLs. Discord commands can only write
`http` or `https` URLs.

Manual local audio can still be configured by editing `data/users.json` directly:

```json
{
  "617718300851306516": {
    "543801897916694529": {
      "file": true,
      "resource": "alex_trim.mp3"
    }
  }
}
```

Manual file resources must be filenames inside `data/sounds`, not paths.
Whenever the bot writes `data/users.json`, it uses two-space indentation and a
trailing newline. The bot resolves those filenames to absolute filesystem paths
before handing them to Lavalink's local source.

Ignored voice channels are configured in `data/channels.json`. This file is
also ignored by Git because it is live server data. The shape is:

```json
{
  "617718300851306516": {
    "1386361673794715740": {
      "ignore": true
    }
  }
}
```

Whenever the bot writes `data/channels.json`, it uses two-space indentation and
a trailing newline.

`data/servers.json` is watched while the bot runs. Valid external edits replace
the active allowed-server list for voice join handling and command execution.
Invalid edits are logged and the last valid server list stays active.
Per-server settings, greeting audio, and ignored-channel configs are read from
disk whenever they are used, so external edits to `data/server_config.json`,
`data/users.json`, and `data/channels.json` are picked up on the next command or
voice event.

Slash commands are registered in the guilds present in `data/servers.json` at
startup. If you add a brand-new guild ID while the bot is already running,
restart the bot once so Discord receives the slash commands for that guild.

## Lavalink

The bot auto-starts `data/lava/Lavalink.jar` before connecting to Discord. The
default connection settings are:

```powershell
$env:LAVALINK_JAVA = 'java'
$env:LAVALINK_JAR_PATH = 'data/lava/Lavalink.jar'
$env:LAVALINK_BASE_URL = 'http://127.0.0.1:2333'
$env:LAVALINK_PASSWORD = 'youshallnotpass'
$env:LAVALINK_PID_PATH = 'data/lava/lavalink.pid'
$env:LAVALINK_AUTO_START = 'true'
```

Playback waits briefly after the bot joins a voice channel before starting the
track. The default is `500` milliseconds and can be changed with:

```powershell
$env:VOICE_GREETING_START_DELAY_MS = '750'
```

`data/lava/application.yml` is ignored by Git for local secrets. If that file is
missing, startup uses the tracked `data/lava/application.example.yml`, which
enables Lavalink local file playback for files in `data/sounds`.

When this bot starts Lavalink itself, it writes `data/lava/lavalink.pid` and
uses that pid file to stop the same JVM on shutdown or on the next run after an
unclean IDE stop. If Lavalink was already running without that pid file, the bot
uses it as an external node and leaves it running.

Set `LAVALINK_AUTO_START=false` to use an external Lavalink node. In that mode,
the bot waits for `LAVALINK_BASE_URL` and never starts or stops a JVM.

## Slash commands

- `/test`: queues `data/sounds/test.mp3` in the voice channel you are currently
  in, using the same playback path as join-triggered greetings.
- `/greet list`: lists greeting audio configured for the current server.
- `/greet set user:<user> url:<url>`: adds or updates a user's online greeting
  audio URL.
- `/greet remove user:<user>`: removes a user's greeting audio.
- `/greet volume percentage:<0-100>`: sets this server's greeting playback
  volume.
- `/greet channels list`: lists voice channels ignored for greetings.
- `/greet channels ignore channel:<voice-channel>`: ignores a voice channel.
- `/greet channels allow channel:<voice-channel>`: allows greetings in a voice
  channel again.

`/greet` commands require the Manage Server permission and respond ephemerally.

Join-triggered greetings and `/test` both respect ignored channels. Greetings
are queued per server, so overlapping joins play in order instead of interrupting
each other.

## Run

From the project root:

```powershell
dart pub get
dart run
```

If `DISCORD_TOKEN`, `data/servers.json`, or the Lavalink jar is missing or
invalid, startup fails with a clear error.

## Docker Compose

The tracked `docker-compose.example.yml` runs the bot and Lavalink as separate
containers. It lists every supported bot environment option with its default.

Before starting Compose:

1. Add your allowed guild IDs to `data/servers.json`.
2. Put local greeting files such as `test.mp3` in `data/sounds`.
3. Set your Discord token in the shell:

```powershell
$env:DISCORD_TOKEN = 'your-bot-token'
```

Start the stack:

```powershell
docker compose -f docker-compose.example.yml up --build
```

The compose file sets `LAVALINK_AUTO_START=false` and
`LAVALINK_BASE_URL=http://lavalink:2333`, so the bot connects to the Lavalink
service instead of launching `data/lava/Lavalink.jar`. Both containers mount the
audio directory at `/app/data/sounds`, which lets local MP3 paths resolve the
same way in the bot and in Lavalink.

The Docker build uses `dart run nyxx_commands:compile` before native
compilation. Do not replace that with plain `dart compile exe lib/main.dart`;
nyxx_commands needs generated callback metadata in compiled executables.

By default Compose mounts `./data`. To keep the live data directory somewhere
else, set `DATA_DIR` to the directory that directly contains `servers.json`,
`server_config.json`, `users.json`, `channels.json`, `sounds`, and `lava`:

```bash
DATA_DIR=/home/dervogel/docker/greet_bot \
DISCORD_TOKEN=your-bot-token \
docker compose -f docker-compose.example.yml up --build
```
