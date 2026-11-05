import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:devmil_logging/devmil_logging.dart';

class FakeExporter extends DiagnosticExporter {
  String? saved;
  bool fail = false;
  @override
  Future<bool> save(String text, String suggestedName) async {
    if (fail) throw StateError('private-storage-error');
    saved = text;
    return false; // Platform dialog cancellation.
  }

  @override
  Future<void> share(String text, Rect? origin) async {
    saved = text;
  }
}

const labels = DiagnosticLabels(
  title: 'Diagnostics',
  description: 'Memory only; details last 15 minutes; export is separate.',
  enable: 'Enable',
  disable: 'Disable',
  clear: 'Clear',
  preview: 'Preview',
  cancel: 'Cancel',
  save: 'Save',
  share: 'Share',
  failed: 'Failed',
  saved: 'Saved',
);
void main() {
  testWidgets(
    'preview gates export, cancellation and failures stay local, clear erases preview',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final history = DiagnosticHistory();
      final lease = history.acquire();
      final exporter = FakeExporter();
      Logger('test').info(const DiagnosticEvent('before_failure'));
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DiagnosticControls(
                application: 'test',
                version: '1',
                history: history,
                exporter: exporter,
                labels: labels,
                spacing: 8,
                previewHeight: 100,
                button: (label, action) =>
                    TextButton(onPressed: action, child: Text(label)),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Save'), findsNothing);
      await tester.tap(find.text('Enable'));
      await tester.pump();
      expect(history.detailed, true);
      expect(exporter.saved, null);
      await tester.tap(find.text('Preview'));
      await tester.pump();
      expect(find.textContaining('before_failure'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(exporter.saved, contains('before_failure'));
      expect(find.text('Saved'), findsNothing);
      exporter.fail = true;
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Failed'), findsOneWidget);
      expect(find.textContaining('private-storage-error'), findsNothing);
      await tester.tap(find.text('Clear'));
      await tester.pump();
      expect(history.count, 0);
      expect(find.text('Save'), findsNothing);
      await tester.tap(find.text('Disable'));
      await tester.pump();
      expect(history.detailed, false);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(lease.close);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
