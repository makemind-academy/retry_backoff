import 'dart:async';
import 'dart:convert';

import 'dart:math';

import 'package:mcp_server/mcp_server.dart';

import 'serve_bundle.dart';

/// gateway_server — the thing you are retrying against.
///
/// Most writing about retries is written from the caller's side: how do I get
/// my request through. This server exists to show the other side of it. It
/// counts every attempt, and it reports the busiest 200ms window it saw.
///
/// That second number is the one that matters. A gateway that is briefly down
/// does not care that you tried again. It cares how many of you tried again at
/// the same instant, because that is what keeps it down.
void main(List<String> args) async {
  const config = McpServerConfig(
    name: 'Flaky Gateway',
    version: '1.0.0',
    capabilities: ServerCapabilities(
      tools: ToolsCapability(listChanged: true),
      resources: ResourcesCapability(listChanged: true),
    ),
  );
  final server = McpServer.createServer(config);
  GatewayServer(server).register();
  // The screen next door: AppPlayer reads it from here and sends the pages'
  // tool calls back to the tools above.
  registerBundleUi(server, '../retry.mbd');
  final transport = McpServer.createStdioTransport().get();
  server.connect(transport);
  await Completer<void>().future;
}


/// "1 order", "2 orders". A screen that says "1 orders" is a screen
/// nobody proofread.
String _plural(int n, String one) => "$n $one" + (n == 1 ? "" : "s");

class GatewayServer {
  GatewayServer(this.server);

  final Server server;

  /// How long the outage lasts, in milliseconds after the run is armed.
  static const _outageMs = 700;

  /// The window the busiest-load figure is measured over.
  static const _windowMs = 200;

  int _armedAtMs = 0;
  final _attemptsAtMs = <int>[];
  var _accepted = 0;
  final _trace = <Map<String, String>>[];
  String _strategy = '';
  String _compare = '';
  Map<String, int>? _hammer;

  int get _elapsed =>
      DateTime.now().millisecondsSinceEpoch - _armedAtMs;

  void register() {
    server.addTool(
      name: 'gate.arm',
      description: 'Start an outage and reset the counters',
      inputSchema: const {'type': 'object', 'properties': {}},
      handler: (args) async {
        _armedAtMs = DateTime.now().millisecondsSinceEpoch;
        _attemptsAtMs.clear();
        _accepted = 0;
        return _state(notice: 'gateway down for ${_outageMs}ms');
      },
    );

    server.addTool(
      name: 'gate.charge',
      description: 'Attempt a charge. Fails while the gateway is down.',
      inputSchema: const {'type': 'object', 'properties': {}},
      handler: (args) async {
        final at = _elapsed;
        _attemptsAtMs.add(at);
        if (at < _outageMs) {
          return _state(notice: 'DOWN at ${at}ms', ok: false);
        }
        _accepted++;
        return _state(notice: 'ACCEPTED at ${at}ms', ok: true);
      },
    );

    // The two caller strategies, run here so the screen can ask for a whole
    // outage with one tap. Four callers all fail at the same moment; what
    // differs is how they come back.
    server.addTool(
      name: 'gate.run',
      description: 'Arm an outage and run four callers with one retry strategy: '
          '"hammer" (retry at once) or "backoff" (exponential + jitter)',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'strategy': {'type': 'string'},
        },
        'required': ['strategy'],
      },
      handler: (args) async {
        final polite = args['strategy'] == 'backoff';
        _armedAtMs = DateTime.now().millisecondsSinceEpoch;
        _attemptsAtMs.clear();
        _accepted = 0;
        _trace.clear();
        _strategy = polite ? 'Back off with jitter' : 'Retry at once';
        final rnd = Random(20260729);
        int waitBefore(int n) {
          if (!polite) return 10; // a round trip, then straight back
          final base = min(20 * (1 << (n - 1)), 400);
          return base + rnd.nextInt(base);
        }
        Future<void> caller(int id) async {
          for (var n = 1; n <= 60; n++) {
            final wait = waitBefore(n);
            if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
            final at = _elapsed;
            _attemptsAtMs.add(at);
            final ok = at >= _outageMs;
            if (ok) _accepted++;
            if (id == 0) {
              _trace.add({'n': '$n', 'line': '${wait > 0 ? 'waited ${wait}ms · ' : ''}${ok ? 'ACCEPTED' : 'DOWN'} at ${at}ms'});
            }
            if (ok) return;
          }
        }
        await Future.wait([for (var i = 0; i < 4; i++) caller(i)]);
        if (polite && _hammer != null) {
          _compare = '${_hammer!['attempts']} attempts and peak ${_hammer!['peak']} when retrying at once';
        } else if (!polite) {
          _hammer = {'attempts': _attemptsAtMs.length, 'peak': _peak};
          _compare = '';
        }
        return _state(notice: 'four callers, one outage of ${_outageMs}ms');
      },
    );

    server.addTool(
      name: 'gate.report',
      description: 'How many attempts arrived, and how bunched up they were',
      inputSchema: const {'type': 'object', 'properties': {}},
      handler: (args) async => _state(),
    );
  }

  /// The most attempts that landed inside any [_windowMs] window.
  int get _peak {
    var worst = 0;
    for (final start in _attemptsAtMs) {
      final n = _attemptsAtMs
          .where((t) => t >= start && t < start + _windowMs)
          .length;
      if (n > worst) worst = n;
    }
    return worst;
  }

  CallToolResult _state({String notice = '', bool ok = true}) =>
      CallToolResult(content: [
        TextContent(
          text: jsonEncode({
            'attempts': _attemptsAtMs.length,
            'accepted': _accepted,
            'peak': _peak,
            'peakNote': '${_plural(_peak, 'attempt')} inside one ${_windowMs}ms window',
            'ok': ok,
            'strategy': _strategy,
            'rows': _trace,
            'compare': _compare,
            'notice': notice,
          }),
        )
      ]);
}
