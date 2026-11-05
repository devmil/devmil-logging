import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:devmil_logging/devmil_logging.dart';

void main() {
  test('bounded bytes/count; unsafe payloads never reach history', () async {
    final history = DiagnosticHistory(maxEvents: 2, maxBytes: 200);
    final lease = history.acquire();
    final log = Logger('test');
    log.info('private sentinel');
    log.severe('password=secret-sentinel', StateError('private-error'));
    log.info(const DiagnosticEvent('stage_one'));
    log.info(const DiagnosticEvent('stage_two'));
    await Future<void>.delayed(Duration.zero);
    final text = history.snapshot(application: 'test', version: '1');
    expect(text, contains('stage_two'));
    expect(text, isNot(contains('sentinel')));
    expect(text, isNot(contains('private-error')));
    expect(history.count, lessThanOrEqualTo(2));
    expect(history.bytes, lessThanOrEqualTo(200));
    await lease.close();
  });
  test(
    'details expire, disabling stops capture, clear erases, leases survive peers',
    () async {
      var now = DateTime.utc(2026);
      final history = DiagnosticHistory(now: () => now);
      final a = history.acquire(), b = history.acquire();
      final log = Logger('test');
      log.info(const DiagnosticEvent('detail_before', detailed: true));
      history.enableDetailed();
      log.fine(const DiagnosticEvent('detail_during', detailed: true));
      now = now.add(const Duration(minutes: 16));
      log.info(const DiagnosticEvent('detail_expired', detailed: true));
      await Future<void>.delayed(Duration.zero);
      var text = history.snapshot(application: 'test', version: '1');
      expect(text, contains('detail_during'));
      expect(text, isNot(contains('detail_before')));
      expect(text, isNot(contains('detail_expired')));
      await a.close();
      await a.close();
      log.info(const DiagnosticEvent('peer_survives'));
      await Future<void>.delayed(Duration.zero);
      expect(
        history.snapshot(application: 'test', version: '1'),
        contains('peer_survives'),
      );
      history.clear();
      expect(history.count, 0);
      await b.close();
      history.enableDetailed();
      final c = history.acquire();
      await c.close();
      expect(history.detailed, false);
      final d = history.acquire();
      expect(history.detailed, false);
      await d.close();
    },
  );
  test('snapshot is detached, oversized unicode events are bounded', () async {
    final history = DiagnosticHistory(maxEventBytes: 100);
    history.formatReviewedRecord = (_) => 'é' * 100;
    final lease = history.acquire();
    Logger('test').info('safe');
    await Future<void>.delayed(Duration.zero);
    expect(history.count, 0);
    history.formatReviewedRecord = null;
    Logger('test').info(const DiagnosticEvent('snapshot'));
    await Future<void>.delayed(Duration.zero);
    final before = history.snapshot(application: 'test', version: '1');
    history.clear();
    expect(before, contains('snapshot'));
    expect(utf8.encode(before).length, greaterThan(0));
    expect(
      history.snapshot(application: 'test', version: '1'),
      isNot(contains('INFO snapshot')),
    );
    await lease.close();
  });
  test('developer console echoes sanitized below-INFO lines only', () async {
    final console = <String>[];
    final history = DiagnosticHistory(developerConsole: console.add);
    final lease = history.acquire();
    final log = Logger('test');
    log.fine(const DiagnosticEvent('operation_completed', fields: {'ms': 3}));
    log.fine('password=secret-sentinel');
    log.fine(const DiagnosticEvent('detail_only', detailed: true));
    log.info(const DiagnosticEvent('retained'));
    await Future<void>.delayed(Duration.zero);
    expect(console, hasLength(2));
    expect(console.first, endsWith('FINE operation_completed ms=3'));
    expect(console.last, endsWith('INFO retained'));
    expect(console.join(), isNot(contains('sentinel')));
    expect(console.join(), isNot(contains('detail_only')));
    final text = history.snapshot(application: 'test', version: '1');
    expect(text, contains('retained'));
    expect(text, isNot(contains('operation_completed')));
    history.enableDetailed();
    log.fine(const DiagnosticEvent('detail_only', detailed: true));
    await Future<void>.delayed(Duration.zero);
    expect(console.last, endsWith('FINE detail_only'));
    expect(
      history.snapshot(application: 'test', version: '1'),
      contains('detail_only'),
    );
    await lease.close();
  });
  test('without a developer console below-INFO records are dropped', () async {
    final history = DiagnosticHistory();
    final lease = history.acquire();
    Logger('test').fine(const DiagnosticEvent('quiet'));
    await Future<void>.delayed(Duration.zero);
    expect(history.count, 0);
    await lease.close();
  });
}
