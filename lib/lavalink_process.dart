import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _defaultJavaExecutable = 'java';
const _defaultJarPath = 'data/lava/Lavalink.jar';
const _defaultBaseUrl = 'http://127.0.0.1:2333';
const _defaultPassword = 'youshallnotpass';
const _defaultPidPath = 'data/lava/lavalink.pid';

class LavalinkProcessException implements Exception {
  const LavalinkProcessException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LavalinkProcessConfig {
  const LavalinkProcessConfig({
    required this.autoStart,
    required this.javaExecutable,
    required this.jarPath,
    required this.base,
    required this.password,
    required this.pidPath,
    this.configPath,
  });

  factory LavalinkProcessConfig.fromEnvironment([
    Map<String, String>? environment,
  ]) {
    final values = environment ?? Platform.environment;

    return LavalinkProcessConfig(
      autoStart: _boolEnv(values, 'LAVALINK_AUTO_START', true),
      javaExecutable: _env(values, 'LAVALINK_JAVA', _defaultJavaExecutable),
      jarPath: _env(values, 'LAVALINK_JAR_PATH', _defaultJarPath),
      base: Uri.parse(_env(values, 'LAVALINK_BASE_URL', _defaultBaseUrl)),
      password: _env(values, 'LAVALINK_PASSWORD', _defaultPassword),
      pidPath: _env(values, 'LAVALINK_PID_PATH', _defaultPidPath),
      configPath: _optionalEnv(values, 'LAVALINK_CONFIG_PATH'),
    );
  }

  final bool autoStart;
  final String javaExecutable;
  final String jarPath;
  final Uri base;
  final String password;
  final String pidPath;
  final String? configPath;
}

class LavalinkProcessManager {
  LavalinkProcessManager(
    this.config, {
    this.startupTimeout = const Duration(seconds: 45),
    this.pollInterval = const Duration(milliseconds: 500),
  });

  final LavalinkProcessConfig config;
  final Duration startupTimeout;
  final Duration pollInterval;

  Process? _process;
  int? _adoptedPid;

  Future<void> start() async {
    if (await _isHealthy()) {
      if (!config.autoStart) {
        stdout.writeln(
          'Lavalink auto-start disabled; using external node at ${config.base}.',
        );
        return;
      }

      _adoptedPid = await _readPidFile();
      if (_adoptedPid == null) {
        stdout.writeln(
          'Lavalink is already reachable at ${config.base}; using the existing node.',
        );
      } else {
        stdout.writeln(
          'Lavalink is already reachable at ${config.base}; adopting pid $_adoptedPid.',
        );
      }
      return;
    }

    if (!config.autoStart) {
      stdout.writeln(
        'Lavalink auto-start disabled; waiting for external node at ${config.base}.',
      );
      await _waitUntilHealthy(
        timeoutMessage:
            'Timed out waiting for external Lavalink at ${config.base}.',
      );
      stdout.writeln('External Lavalink is reachable at ${config.base}.');
      return;
    }

    final jarFile = File(config.jarPath).absolute;
    if (!await jarFile.exists()) {
      throw LavalinkProcessException(
        'Could not find Lavalink jar at ${jarFile.path}.',
      );
    }

    final args = ['-jar', jarFile.path, ..._springConfigArguments(jarFile)];

    _process = await Process.start(
      config.javaExecutable,
      args,
      workingDirectory: jarFile.parent.path,
    );
    _pipeProcessLogs(_process!);
    await _writePidFile(_process!.pid);

    int? exitCode;
    unawaited(
      _process!.exitCode.then((code) async {
        exitCode = code;
        await _deletePidFile();
      }),
    );

    await _waitUntilHealthy(
      timeoutMessage: 'Timed out waiting for Lavalink at ${config.base}.',
      exitCode: () => exitCode,
    );
    stdout.writeln('Lavalink started at ${config.base}.');
  }

  Future<void> stop() async {
    if (!config.autoStart) {
      stdout.writeln(
        'Lavalink auto-start disabled; leaving external node running.',
      );
      return;
    }

    final process = _process;
    final adoptedPid = _adoptedPid;
    _process = null;
    _adoptedPid = null;

    if (process == null) {
      if (adoptedPid != null) {
        stdout.writeln('Stopping adopted Lavalink process $adoptedPid.');
        final killed = Process.killPid(adoptedPid);
        if (!killed) {
          stderr.writeln(
            'Could not stop adopted Lavalink process $adoptedPid.',
          );
        }
        await _deletePidFile();
        return;
      }

      stdout.writeln(
        'Lavalink was not started by this bot; leaving it running.',
      );
      return;
    }

    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
      await _deletePidFile();
    } on TimeoutException {
      stderr.writeln('Lavalink did not exit within 5 seconds after shutdown.');
    }
  }

  Future<void> _waitUntilHealthy({
    required String timeoutMessage,
    int? Function()? exitCode,
  }) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < startupTimeout) {
      if (await _isHealthy()) {
        return;
      }

      final code = exitCode?.call();
      if (code != null) {
        throw LavalinkProcessException(
          'Lavalink exited before it became reachable, exit code $code.',
        );
      }

      await Future<void>.delayed(pollInterval);
    }

    await stop();
    throw LavalinkProcessException(timeoutMessage);
  }

  Future<bool> _isHealthy() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.getUrl(config.base.resolve('/version'));
      request.headers.set(HttpHeaders.authorizationHeader, config.password);

      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await response.drain<void>();

      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  List<String> _springConfigArguments(File jarFile) {
    final explicitConfig = config.configPath;
    if (explicitConfig != null && explicitConfig.trim().isNotEmpty) {
      return [
        '--spring.config.additional-location=${File(explicitConfig).absolute.uri}',
      ];
    }

    final liveConfig = File(
      '${jarFile.parent.path}${Platform.pathSeparator}application.yml',
    );
    if (liveConfig.existsSync()) {
      return ['--spring.config.additional-location=${liveConfig.absolute.uri}'];
    }

    final exampleConfig = File(
      '${jarFile.parent.path}${Platform.pathSeparator}application.example.yml',
    );
    if (exampleConfig.existsSync()) {
      return [
        '--spring.config.additional-location=${exampleConfig.absolute.uri}',
      ];
    }

    return const [];
  }

  Future<int?> _readPidFile() async {
    final file = File(config.pidPath);
    if (!await file.exists()) {
      return null;
    }

    final source = await file.readAsString();
    final pid = int.tryParse(source.trim());
    return pid == null || pid <= 0 ? null : pid;
  }

  Future<void> _writePidFile(int pid) async {
    final file = File(config.pidPath);
    await file.parent.create(recursive: true);
    await file.writeAsString('$pid\n');
  }

  Future<void> _deletePidFile() async {
    final file = File(config.pidPath);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

void _pipeProcessLogs(Process process) {
  _pipeLines(process.stdout, 'lavalink', stdout.writeln);
  _pipeLines(process.stderr, 'lavalink', stderr.writeln);
}

void _pipeLines(
  Stream<List<int>> stream,
  String prefix,
  void Function(String line) write,
) {
  stream
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) => write('[$prefix] $line'));
}

String _env(Map<String, String> environment, String key, String fallback) {
  final value = environment[key]?.trim();
  return value == null || value.isEmpty ? fallback : value;
}

bool _boolEnv(Map<String, String> environment, String key, bool fallback) {
  final value = environment[key]?.trim().toLowerCase();
  if (value == null || value.isEmpty) {
    return fallback;
  }

  return switch (value) {
    'true' || '1' || 'yes' || 'on' => true,
    'false' || '0' || 'no' || 'off' => false,
    _ => throw LavalinkProcessException(
      '$key must be true or false, got "$value".',
    ),
  };
}

String? _optionalEnv(Map<String, String> environment, String key) {
  final value = environment[key]?.trim();
  return value == null || value.isEmpty ? null : value;
}
