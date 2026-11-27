import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver/request_host.dart';

void main() {
  test('only names a rebinding page cannot own are admitted', () {
    const allowed = {'decent.lan'};
    for (final host in [
      '192.168.1.5',
      '2001:db8::5',
      '::ffff:10.0.0.7',
      'localhost',
      'LocalHost.',
      'app.localhost',
      'decent.local',
      'decent.local.',
      'decent.lan',
      'Decent.LAN.',
    ]) {
      expect(isAdmittedHost(host, allowed), isTrue, reason: host);
    }
    for (final host in [
      'rebind.attacker.example',
      'decent.lan.evil.example',
      'local',
      'evil-local',
      '0.0.0.0',
      '::',
      '::ffff:0.0.0.0',
      'fe80::1%en0',
      '',
      'a b',
    ]) {
      expect(isAdmittedHost(host, allowed), isFalse, reason: host);
    }
  });

  test('host names are normalized and validated', () {
    expect(normalizeHostName(' Decent.LAN. '), 'decent.lan');
    expect(normalizeHostName('192.168.1.5'), isNull);
    expect(normalizeHostName('evil example'), isNull);
    expect(normalizeHostName('a/b'), isNull);
    expect(
      hostNameAllowlist(['Decent.LAN', 'bad name']),
      contains('decent.lan'),
    );
    expect(hostNameAllowlist(const []), isNot(contains('bad name')));
  });

  test('an ambiguous device address is resolved by the peer subnet', () {
    expect(
      onLinkPageHost(
        peer: InternetAddress('192.168.12.50'),
        addresses: {'10.0.0.7', '192.168.12.64'},
      ),
      '192.168.12.64',
      reason: 'Wi-Fi and Ethernet: the address on the peer subnet wins',
    );
    expect(
      onLinkPageHost(
        peer: InternetAddress('2001:db8:1::7'),
        addresses: {'2001:db8:2::5', '2001:db8:1::5', '2001:db8:1::abcd'},
      ),
      anyOf('2001:db8:1::5', '2001:db8:1::abcd'),
      reason: 'stable and privacy addresses on the peer /64 both work',
    );
    expect(
      onLinkPageHost(
        peer: InternetAddress('172.16.5.9'),
        addresses: {'10.0.0.7', '192.168.12.64'},
      ),
      isNull,
      reason: 'no address shares the peer subnet, so the name is kept',
    );
    expect(
      onLinkPageHost(
        peer: InternetAddress('192.168.12.50'),
        addresses: {'127.0.0.1', '0.0.0.0', 'fe80::1'},
      ),
      isNull,
    );
  });
}
