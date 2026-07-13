import 'package:dev_loop/models/models.dart';
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
}
