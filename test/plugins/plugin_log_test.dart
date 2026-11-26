import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_log.dart';

void main() {
  group('redactPluginLog', () {
    test('masks every current secure setting value', () {
      expect(
        redactPluginLog('key=s3cr3t-key, again s3cr3t-key; pin 123', [
          's3cr3t-key',
          '123',
        ]),
        'key=***, again ***; pin 123',
      );
    });

    test('masks the longer of two overlapping secrets first', () {
      expect(
        redactPluginLog('token abcdefgh', ['abcd', 'abcdefgh']),
        'token ***',
      );
    });

    test('masks credential shapes', () {
      expect(
        redactPluginLog('Authorization: Basic dXNlcjpwYXNz', const []),
        'Authorization: Basic ***',
      );
      expect(
        redactPluginLog('{"Authorization":"Bearer abc.def-ghi"}', const []),
        '{"Authorization":"Bearer ***"}',
      );
      expect(
        redactPluginLog('upload key vzu_AbC123_xyz used', const []),
        'upload key *** used',
      );
      expect(
        redactPluginLog(
          'checking {"username":"max","password":"p\\"w d"}',
          const [],
        ),
        'checking {"username":"max","password":"***"}',
      );
      expect(
        redactPluginLog('{"Password": "hunter2"}', const []),
        '{"Password": "***"}',
      );
    });

    test('keeps ordinary text and neutralises line breaks', () {
      expect(
        redactPluginLog('Basic setup done\nSEVERE forged', const []),
        r'Basic setup done\nSEVERE forged',
      );
    });
  });

  group('PluginLogLimiter', () {
    test(
      'admits 60 lines per minute, then reports the suppressed count once',
      () {
        var now = DateTime(2026, 11, 24, 12);
        withClock(Clock(() => now), () {
          final limiter = PluginLogLimiter();
          final first = [for (var i = 0; i < 65; i++) limiter.admit()];
          expect(first.where((r) => r.write), hasLength(60));
          expect(first.every((r) => r.suppressed == 0), isTrue);

          now = now.add(const Duration(seconds: 59));
          expect(limiter.admit().write, isFalse);

          now = now.add(const Duration(seconds: 1));
          final rolled = limiter.admit();
          expect(rolled.write, isTrue);
          expect(rolled.suppressed, 6);
          expect(limiter.admit().suppressed, 0);
        });
      },
    );

    test('drain returns lines suppressed in the open window', () {
      final limiter = PluginLogLimiter(limit: 1);
      limiter.admit();
      limiter.admit();
      limiter.admit();
      expect(limiter.drain(), 2);
      expect(limiter.drain(), 0);
    });
  });
}
