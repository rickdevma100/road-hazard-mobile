import 'package:flutter_test/flutter_test.dart';
import 'package:road_hazard/features/contributor/location.dart';

void main() {
  test('uses the fix closest to frame time, not the latest fix', () {
    final buffer = TrajectoryBuffer();
    final at = DateTime.utc(2026, 9, 11, 10);
    final closest = LocationFix(17, 78, 4, at);
    buffer.add(closest);
    buffer.add(LocationFix(18, 78, 4, at.add(const Duration(seconds: 2))));
    expect(buffer.nearest(at.add(const Duration(milliseconds: 100))), same(closest));
  });
  test('rejects stale, invalid and inaccurate fixes', () {
    final buffer = TrajectoryBuffer();
    final at = DateTime.utc(2026, 9, 11, 10);
    buffer.add(LocationFix(17, 78, -1, at));
    buffer.add(LocationFix(17, 78, 100, at));
    expect(buffer.nearest(at), isNull);
    buffer.add(LocationFix(17, 78, 4, at));
    expect(buffer.nearest(at.add(const Duration(seconds: 4))), isNull);
  });
}
