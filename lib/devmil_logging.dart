import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:file_selector/file_selector.dart';
import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Producers supply reviewed codes and public scalar fields. Never pass raw
/// payloads, external exception text, paths, account IDs, or credentials.
final class DiagnosticEvent {
  const DiagnosticEvent(
    this.code, {
    this.fields = const {},
    this.detailed = false,
  });
  final String code;
  final Map<String, num> fields;
  final bool detailed;
}

/// One isolate's memory history. No disk, automatic upload or async write
/// queue. Each composition root holds its own idempotent lease.
///
/// Debug builds may echo sanitized lines to a developer console: the
/// `DEVMIL_DIAGNOSTIC_CONSOLE` define selects `debugPrint`, and tests may pass
/// [developerConsole]. Release builds never have a console. The console also
/// receives below-INFO records, which history retains only while detailed.
final class DiagnosticHistory extends ChangeNotifier {
  DiagnosticHistory({
    this.maxBytes = 256 * 1024,
    this.maxEvents = 1000,
    this.maxEventBytes = 2048,
    DateTime Function()? now,
    void Function(String line)? developerConsole,
  }) : assert(maxBytes > 0),
       assert(maxEvents > 0),
       assert(maxEventBytes > 0),
       _now = now ?? DateTime.now,
       _console = kDebugMode
           ? developerConsole ??
                 (const bool.fromEnvironment('DEVMIL_DIAGNOSTIC_CONSOLE')
                     ? (line) => debugPrint(line)
                     : null)
           : null;
  static final instance = DiagnosticHistory();
  final int maxBytes, maxEvents, maxEventBytes;
  final DateTime Function() _now;
  final void Function(String line)? _console;
  final _events = Queue<String>();
  int _bytes = 0, _owners = 0;
  int clearGeneration = 0;
  DateTime? _until;
  Timer? _expiry;
  StreamSubscription<LogRecord>? _subscription;
  String? Function(LogRecord)? formatReviewedRecord;
  static final _code = RegExp(r'^[A-Za-z][A-Za-z0-9_. -]{0,100}$');
  int get bytes => _bytes;
  int get count => _events.length;
  bool get detailed => _until != null && _now().isBefore(_until!);

  DiagnosticLease acquire() {
    if (_owners++ == 0) {
      hierarchicalLoggingEnabled = true;
      Logger.root.level = Level.ALL;
      _subscription = Logger.root.onRecord.listen(_record);
    }
    return DiagnosticLease._(this);
  }

  void enableDetailed({Duration duration = const Duration(minutes: 15)}) {
    _expiry?.cancel();
    final bounded = duration > const Duration(minutes: 15)
        ? const Duration(minutes: 15)
        : duration;
    if (bounded <= Duration.zero) {
      disableDetailed();
      return;
    }
    _until = _now().add(bounded);
    _expiry = Timer(bounded, disableDetailed);
    notifyListeners();
  }

  void disableDetailed() {
    _until = null;
    _expiry?.cancel();
    _expiry = null;
    notifyListeners();
  }

  void clear() {
    clearGeneration++;
    _events.clear();
    _bytes = 0;
    notifyListeners();
  }

  void _record(LogRecord record) {
    final retain = record.level >= Level.INFO || detailed;
    final console = _console;
    if (!retain && console == null) return;
    final Object? message = record.object ?? record.message;
    String? safe;
    if (message is DiagnosticEvent &&
        (!message.detailed || detailed) &&
        _code.hasMatch(message.code)) {
      safe = message.code;
      for (final entry in message.fields.entries.take(16)) {
        if (_code.hasMatch(entry.key) && entry.value.isFinite) {
          safe = '$safe ${entry.key}=${entry.value}';
        }
      }
    } else if (message is! DiagnosticEvent) {
      try {
        safe = formatReviewedRecord?.call(record);
      } catch (_) {
        safe = 'diagnostic_policy_failed';
      }
      // Unclassified legacy text is never serialized, even in detailed mode.
      // A severity and event category still preserve the fact of a failure.
      safe ??= record.level >= Level.WARNING ? 'unclassified_failure' : null;
    }
    if (safe == null) return;
    if (record.error != null)
      safe = '$safe error_type=${record.error.runtimeType}';
    final line =
        '${record.time.toUtc().toIso8601String()} '
        '${record.level.name} ${redact(safe)}';
    if (utf8.encode(line).length > maxEventBytes ||
        utf8.encode(line).length > maxBytes)
      return;
    console?.call(line);
    if (!retain) return;
    _events.add(line);
    _bytes += utf8.encode(line).length;
    while (_events.length > maxEvents || _bytes > maxBytes) {
      _bytes -= utf8.encode(_events.removeFirst()).length;
    }
    // Capture does not rebuild settings on every event. Controls refresh on
    // user actions; snapshots are synchronous and bounded.
  }

  String snapshot({required String application, required String version}) =>
      'Diagnostics schema 1\nApp: ${redact(application)}\n'
      'Version: ${redact(version)}\nPlatform: ${defaultTargetPlatform.name}\n'
      'Memory history: $count events, $_bytes bytes\n\n'
      '${_events.map(redact).join('\n')}';

  static String redact(String value) {
    var text = value.replaceAll(
      RegExp(r'https?://\S+', caseSensitive: false),
      '<uri>',
    );
    text = text.replaceAll(
      RegExp(r'\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b'),
      '<email>',
    );
    text = text.replaceAll(
      RegExp(r'(?:/[\w.-]+/|[A-Za-z]:[\\/])\S*'),
      '<path>',
    );
    text = text.replaceAll(
      RegExp(
        r'\b(?:password|passphrase|token|secret|cookie|authorization|key)\s*[:=]\s*\S+',
        caseSensitive: false,
      ),
      '<secret>',
    );
    return text;
  }

  Future<void> _release() async {
    if (--_owners != 0) return;
    final subscription = _subscription;
    _subscription = null;
    disableDetailed();
    await subscription?.cancel();
    // Keep safe history available through bootstrap failure/retry.
  }
}

final class DiagnosticLease {
  DiagnosticLease._(this._history);
  final DiagnosticHistory _history;
  Future<void>? _closing;
  Future<void> close() => _closing ??= _history._release();
}

typedef DiagnosticButton =
    Widget Function(String label, VoidCallback? onPressed);

/// Product-localized copy, passed by the app's ARB localization boundary.
final class DiagnosticLabels {
  const DiagnosticLabels({
    required this.title,
    required this.description,
    required this.enable,
    required this.disable,
    required this.clear,
    required this.preview,
    required this.cancel,
    required this.save,
    required this.share,
    required this.failed,
    required this.saved,
  });
  final String title,
      description,
      enable,
      disable,
      clear,
      preview,
      cancel,
      save,
      share,
      failed,
      saved;
}

/// UI-independent actions and a bounded preview. Applications supply their
/// design-system button and spacing, avoiding duplicate workflow mechanics.
class DiagnosticControls extends StatefulWidget {
  const DiagnosticControls({
    super.key,
    required this.application,
    required this.version,
    required this.labels,
    required this.button,
    required this.spacing,
    required this.previewHeight,
    this.history,
    this.confirmDetailed,
    this.exporter = const DiagnosticExporter(),
  });
  final String application, version;
  final DiagnosticLabels labels;
  final DiagnosticButton button;
  final double spacing, previewHeight;
  final DiagnosticHistory? history;
  final DiagnosticExporter exporter;
  final Future<bool> Function()? confirmDetailed;
  @override
  State<DiagnosticControls> createState() => _DiagnosticControlsState();
}

class _DiagnosticControlsState extends State<DiagnosticControls> {
  DiagnosticHistory get history => widget.history ?? DiagnosticHistory.instance;
  String? _preview, _status;
  int _previewGeneration = 0;
  String _version = 'unknown';
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    history.addListener(_changed);
    _version = widget.version;
    if (_version == 'unknown') unawaited(_readVersion());
  }

  Future<void> _readVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) _version = '${info.version}+${info.buildNumber}';
    } catch (_) {
      /* Metadata is optional; export must remain available. */
    }
  }

  void _changed() {
    if (_previewGeneration != history.clearGeneration) _preview = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    history.removeListener(_changed);
    super.dispose();
  }

  Future<void> _enableDetailed() async {
    final confirmed = await widget.confirmDetailed?.call() ?? true;
    if (mounted && confirmed) history.enableDetailed();
  }

  Future<void> _export(bool share) async {
    final text = _preview;
    if (_busy || text == null) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      if (share) {
        final box = context.findRenderObject() as RenderBox?;
        await widget.exporter.share(
          text,
          box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        );
      } else if (await widget.exporter.save(
        text,
        '${widget.application}-diagnostics.txt',
      )) {
        if (mounted) _status = widget.labels.saved;
      }
    } catch (_) {
      if (mounted) _status = widget.labels.failed;
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.labels;
    final mobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.title),
        SizedBox(height: widget.spacing),
        Text(l.description),
        SizedBox(height: widget.spacing),
        Wrap(
          spacing: widget.spacing,
          runSpacing: widget.spacing,
          children: [
            widget.button(
              history.detailed ? l.disable : l.enable,
              _busy
                  ? null
                  : () {
                      if (history.detailed) {
                        history.disableDetailed();
                      } else {
                        unawaited(_enableDetailed());
                      }
                    },
            ),
            widget.button(
              l.clear,
              _busy
                  ? null
                  : () {
                      history.clear();
                      setState(() {
                        _preview = null;
                        _status = null;
                      });
                    },
            ),
            widget.button(
              l.preview,
              _busy
                  ? null
                  : () {
                      setState(() {
                        _previewGeneration = history.clearGeneration;
                        _preview = history.snapshot(
                          application: widget.application,
                          version: _version,
                        );
                        _status = null;
                      });
                    },
            ),
          ],
        ),
        if (_preview != null) ...[
          SizedBox(height: widget.spacing),
          SizedBox(
            height: widget.previewHeight,
            child: SingleChildScrollView(child: Text(_preview!)),
          ),
          Wrap(
            spacing: widget.spacing,
            runSpacing: widget.spacing,
            children: [
              if (!mobile)
                widget.button(
                  l.save,
                  _busy ? null : () => unawaited(_export(false)),
                ),
              if (!kIsWeb &&
                  (mobile ||
                      defaultTargetPlatform == TargetPlatform.macOS ||
                      defaultTargetPlatform == TargetPlatform.windows))
                widget.button(
                  l.share,
                  _busy ? null : () => unawaited(_export(true)),
                ),
              widget.button(
                l.cancel,
                _busy
                    ? null
                    : () => setState(() {
                        _preview = null;
                      }),
              ),
            ],
          ),
        ],
        if (_status != null) Text(_status!),
      ],
    );
  }
}

/// Connects the app's existing bridge transport to the shared history. Native
/// notifications are edge triggered; only one bounded drain runs at a time.
/// The native side never forwards arbitrary text or credentials.
final class NativeDiagnosticBridge {
  NativeDiagnosticBridge({
    required this.drain,
    required this.configure,
    required this.detach,
    DiagnosticHistory? history,
  }) : history = history ?? DiagnosticHistory.instance;
  final Future<List<String>> Function() drain;
  final Future<void> Function(bool detailed, bool clear) configure;
  final Future<void> Function() detach;
  Future<void>? _configuration;
  final DiagnosticHistory history;
  StreamSubscription<void>? _signals;
  bool _draining = false, _again = false, _closed = false;
  bool _configuring = false, _configAgain = false;
  int _clearSeen = 0;
  void start(Stream<void> signals) {
    if (_signals != null) return;
    _clearSeen = history.clearGeneration;
    history.addListener(_settingsChanged);
    _signals = signals.listen(
      (_) => _scheduleDrain(),
      onError: (Object _) {
        Logger(
          'NativeDiagnostics',
        ).warning(const DiagnosticEvent('native_hook_failed'));
      },
    );
    _settingsChanged();
  }

  void _settingsChanged() {
    if (_closed) return;
    _configAgain = true;
    if (!_configuring) {
      _configuration = _applySettings();
    }
  }

  Future<void> _applySettings() async {
    _configuring = true;
    try {
      while (_configAgain && !_closed) {
        _configAgain = false;
        final generation = history.clearGeneration;
        await configure(history.detailed, generation != _clearSeen);
        _clearSeen = generation;
      }
    } catch (_) {
      Logger(
        'NativeDiagnostics',
      ).warning(const DiagnosticEvent('native_configuration_failed'));
    } finally {
      _configuring = false;
    }
  }

  void _scheduleDrain() {
    _again = true;
    if (!_draining && !_closed) unawaited(_drain());
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (_again && !_closed) {
        _again = false;
        final clear = history.clearGeneration;
        final allowed = _clearSeen == clear;
        final entries = await drain();
        if (_closed || !allowed || clear != history.clearGeneration) continue;
        for (final line in entries.take(256)) {
          if (line.length > 1024) continue;
          final value = jsonDecode(line);
          if (value is! Map<String, dynamic> || value['code'] is! String)
            continue;
          final fields = <String, num>{};
          final raw = value['fields'];
          if (raw is List) {
            for (final field in raw.take(16)) {
              if (field is List &&
                  field.length == 2 &&
                  field[0] is String &&
                  field[1] is num) {
                fields[field[0] as String] = field[1] as num;
              }
            }
          }
          final level = switch (value['level']) {
            'SEVERE' => Level.SEVERE,
            'WARNING' => Level.WARNING,
            'FINE' => Level.FINE,
            _ => Level.INFO,
          };
          Logger('NativeDiagnostics').log(
            level,
            DiagnosticEvent(value['code'] as String, fields: fields),
          );
        }
      }
    } catch (_) {
      Logger(
        'NativeDiagnostics',
      ).warning(const DiagnosticEvent('native_drain_failed'));
    } finally {
      _draining = false;
    }
  }

  Future<void>? _closing;
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    if (_closed) return;
    final clearAtClose = history.clearGeneration;
    _closed = true;
    history.removeListener(_settingsChanged);
    await _configuration;
    await configure(false, clearAtClose != _clearSeen);
    // Rust must drop its StreamSink before FRB can finish stream cancellation.
    await detach();
    await _signals?.cancel();
  }
}

/// Convenience entry point for reviewed numeric diagnostic events.
void recordDiagnostic(DiagnosticEvent event, {bool warning = false}) =>
    Logger('Diagnostics').log(warning ? Level.WARNING : Level.INFO, event);

DiagnosticLease? _processLease;

/// Own error hooks and history before fallible application bootstrap. The
/// process lease intentionally lasts until engine exit, preserving retry data.
void installDiagnosticErrorHooks() {
  _processLease ??= DiagnosticHistory.instance.acquire();
  FlutterError.onError = (details) {
    recordDiagnostic(const DiagnosticEvent('flutter_error'), warning: true);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    recordDiagnostic(const DiagnosticEvent('platform_error'), warning: true);
    return true;
  };
  recordDiagnostic(const DiagnosticEvent('process_start'));
}

/// Platform export adapter, injectable for cancellation and failure tests.
/// Text sharing uses no application-owned temporary file. Save writes only to
/// the destination chosen in the platform dialog.
class DiagnosticExporter {
  const DiagnosticExporter();
  Future<bool> save(String text, String suggestedName) async {
    final location = await getSaveLocation(suggestedName: suggestedName);
    if (location == null) return false;
    await XFile.fromData(
      Uint8List.fromList(utf8.encode(text)),
      mimeType: 'text/plain',
    ).saveTo(location.path);
    return true;
  }

  Future<void> share(String text, Rect? origin) async {
    await SharePlus.instance.share(
      ShareParams(text: text, sharePositionOrigin: origin),
    );
  }
}
