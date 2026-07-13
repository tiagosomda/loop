import 'package:dev_loop/models/models.dart';
import 'package:dev_loop/widgets/brand_logo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('status universe is stable', () {
    expect(itemStatuses, [
      'open',
      'in-progress',
      'needs-review',
      'completed',
      'closed',
    ]);
  });

  group('schedule-aware logo speed', () {
    test('accelerates inside the schedule window', () {
      final now = DateTime(2026, 7, 13, 10, 12, 1);

      expect(isNearScheduledTime(now, const ['10:15']), isTrue);
      expect(
        isNearScheduledTime(now.subtract(const Duration(seconds: 2)), const [
          '10:15',
        ]),
        isFalse,
      );
    });

    test('handles schedule windows across midnight', () {
      final now = DateTime(2026, 7, 13, 23, 59);

      expect(isNearScheduledTime(now, const ['00:01']), isTrue);
    });

    test('ignores malformed schedule values', () {
      final now = DateTime(2026, 7, 13, 10, 15);

      expect(isNearScheduledTime(now, const ['noon', '25:00']), isFalse);
    });
  });
}
