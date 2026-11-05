import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:devmil_logging/devmil_logging.dart';

void main() {
  test(
    'native hook drains numeric events, coalesces work and mirrors consent/clear',
    () async {
      final history = DiagnosticHistory();
      final lease = history.acquire();
      // Model the native owner: stream cancellation cannot finish until its
      // callback releases the sink. This catches the real FRB shutdown order.
      final nativeDetached = Completer<void>();
      final signals = StreamController<void>(
        onCancel: () => nativeDetached.future,
      );
      final settings = <(bool, bool)>[];
      var active = 0, maximum = 0;
      var detached = false;
      final bridge = NativeDiagnosticBridge(
        detach: () async {
          detached = true;
          nativeDetached.complete();
        },
        history: history,
        drain: () async {
          active++;
          if (active > maximum) maximum = active;
          await Future<void>.delayed(Duration.zero);
          active--;
          return [
            '{"code":"native.capture_failed","level":"WARNING","fields":[["stage",3]]}',
          ];
        },
        configure: (detailed, clear) async {
          settings.add((detailed, clear));
        },
      );
      bridge.start(signals.stream);
      signals.add(null);
      signals.add(null);
      signals.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(maximum, 1);
      expect(
        history.snapshot(application: 'test', version: '1'),
        contains('native.capture_failed stage=3'),
      );
      history.enableDetailed();
      await Future<void>.delayed(Duration.zero);
      expect(settings.last.$1, true);
      history.clear();
      await Future<void>.delayed(Duration.zero);
      expect(settings.last.$2, true);
      final closing = bridge.close();
      expect(bridge.close(), same(closing));
      await closing.timeout(const Duration(seconds: 5));
      expect(settings.last.$1, false);
      expect(detached, true);
      await signals.close();
      await lease.close();
    },
  );
  test(
    'close honors Clear queued behind an in-flight native configuration',
    () async {
      final history = DiagnosticHistory();
      final signals = StreamController<void>();
      final pending = Completer<void>();
      final calls = <(bool, bool)>[];
      var detached = false;
      final bridge = NativeDiagnosticBridge(
        history: history,
        drain: () async => [],
        detach: () async {
          detached = true;
        },
        configure: (detailed, clear) async {
          calls.add((detailed, clear));
          if (calls.length == 1) await pending.future;
        },
      );
      bridge.start(signals.stream);
      history.clear();
      final closing = bridge.close();
      pending.complete();
      await closing;
      expect(calls.last, (false, true));
      expect(detached, true);
      await signals.close();
    },
  );
}
