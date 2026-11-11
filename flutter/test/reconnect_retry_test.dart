import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reconnect delay doubles up to the limit', () {
    expect(nextReconnectDelay(1), 2);
    expect(nextReconnectDelay(4), 8);
    expect(nextReconnectDelay(8), kMaxReconnectDelaySecs);
  });

  test('a reset of an established session is retried', () {
    expect(
        isLostSessionReset('relay-hint',
            'An existing connection was forcibly closed by the remote host. (os error 10054)'),
        isTrue);
    expect(isLostSessionReset('relay-hint', 'Connection refused'), isFalse);
    expect(isLostSessionReset('error', 'os error 10054'), isFalse);
  });

  test('connect failures of a lost session are retried', () {
    for (final text in [
      'Failed to connect to 192.0.2.1:21118: Please try later',
      'Failed to connect via relay server: Please try later',
      'Failed to make direct connection to remote desktop: Please try later',
    ]) {
      expect(isLostSessionConnectFailure('error', 'Connection Error', text),
          isTrue,
          reason: text);
    }
    expect(
        isLostSessionConnectFailure(
            'error', 'Connection Error', 'Wrong password'),
        isFalse);
  });
}
