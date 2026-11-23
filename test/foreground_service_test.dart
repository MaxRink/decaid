import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/foreground_service.dart';

void main() {
  group('ForegroundServiceGraceTimer', () {
    late ForegroundServiceGraceTimer timer;
    bool stopCalled = false;
    bool startCalled = false;

    setUp(() {
      stopCalled = false;
      startCalled = false;
      timer = ForegroundServiceGraceTimer(
        gracePeriod: Duration(minutes: 5),
        onStop: () async {
          stopCalled = true;
        },
        onStart: () async {
          startCalled = true;
        },
      );
    });

    tearDown(() {
      timer.dispose();
    });

    test('does not stop immediately on disconnect', () {
      fakeAsync((async) {
        timer.onMachineDisconnected();
        expect(stopCalled, isFalse);
      });
    });

    test('stops after grace period expires', () {
      fakeAsync((async) {
        timer.onMachineDisconnected();
        async.elapse(Duration(minutes: 5, seconds: 1));
        expect(stopCalled, isTrue);
      });
    });

    test('does not stop before grace period expires', () {
      fakeAsync((async) {
        timer.onMachineDisconnected();
        async.elapse(Duration(minutes: 4));
        expect(stopCalled, isFalse);
      });
    });

    test('cancels stop if machine reconnects during grace period', () {
      fakeAsync((async) {
        timer.onMachineDisconnected();
        async.elapse(Duration(minutes: 2));
        timer.onMachineConnected();
        async.elapse(Duration(minutes: 5));
        expect(stopCalled, isFalse);
      });
    });

    test('does not call onStart on connect if service was never stopped', () {
      fakeAsync((async) {
        timer.onMachineDisconnected();
        async.elapse(Duration(minutes: 2));
        timer.onMachineConnected();
        expect(startCalled, isFalse);
      });
    });

    test('restarts service on connect if previously stopped', () {
      fakeAsync((async) {
        timer.onMachineDisconnected();
        async.elapse(Duration(minutes: 6));
        expect(stopCalled, isTrue);

        startCalled = false;
        timer.onMachineConnected();
        expect(startCalled, isTrue);
      });
    });
  });

  group('ForegroundServiceGraceTimer keepRunning', () {
    late ForegroundServiceGraceTimer timer;
    late int stopCalls;
    late int startCalls;

    ForegroundServiceGraceTimer build({bool keepRunning = false}) =>
        ForegroundServiceGraceTimer(
          keepRunning: keepRunning,
          onStop: () async => stopCalls++,
          onStart: () async => startCalls++,
        );

    setUp(() {
      stopCalls = 0;
      startCalls = 0;
    });

    tearDown(() => timer.dispose());

    test('enabled never stops the service on disconnect', () {
      fakeAsync((async) {
        timer = build(keepRunning: true);
        timer.onMachineDisconnected();
        async.elapse(const Duration(hours: 2));
        expect(stopCalls, 0);
      });
    });

    test('enabling during the grace period cancels the pending stop', () {
      fakeAsync((async) {
        timer = build();
        timer.onMachineDisconnected();
        async.elapse(const Duration(minutes: 2));
        timer.setKeepRunning(true);
        async.elapse(const Duration(hours: 1));
        expect(stopCalls, 0);
        expect(startCalls, 0);
      });
    });

    test('enabling after the grace stop restarts the service', () {
      fakeAsync((async) {
        timer = build();
        timer.onMachineDisconnected();
        async.elapse(const Duration(minutes: 6));
        expect(stopCalls, 1);
        timer.setKeepRunning(true);
        async.flushMicrotasks();
        expect(startCalls, 1);
        timer.onMachineConnected();
        expect(startCalls, 1);
      });
    });

    test('disabling while disconnected arms the grace period immediately', () {
      fakeAsync((async) {
        timer = build(keepRunning: true);
        timer.onMachineDisconnected();
        async.elapse(const Duration(minutes: 30));
        timer.setKeepRunning(false);
        async.elapse(const Duration(minutes: 4));
        expect(stopCalls, 0);
        async.elapse(const Duration(minutes: 2));
        expect(stopCalls, 1);
      });
    });

    test('disabling while connected does not stop the service', () {
      fakeAsync((async) {
        timer = build(keepRunning: true);
        timer.onMachineConnected();
        timer.setKeepRunning(false);
        async.elapse(const Duration(hours: 1));
        expect(stopCalls, 0);
      });
    });

    test('disabled keeps the existing grace behaviour', () {
      fakeAsync((async) {
        timer = build(keepRunning: true);
        timer.setKeepRunning(false);
        timer.onMachineDisconnected();
        async.elapse(const Duration(minutes: 6));
        expect(stopCalls, 1);
      });
    });
  });
}
