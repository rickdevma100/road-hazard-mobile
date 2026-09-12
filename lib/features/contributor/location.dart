class LocationFix {
  LocationFix(this.latitude, this.longitude, this.accuracy, this.at,
      {this.course, this.courseAccuracy, this.speed, this.speedAccuracy});
  final double latitude, longitude, accuracy;
  final DateTime at;
  final double? course, courseAccuracy, speed, speedAccuracy;
  factory LocationFix.fromMap(Map<dynamic, dynamic> m) => LocationFix(
      (m['latitude'] as num).toDouble(), (m['longitude'] as num).toDouble(),
      (m['accuracy'] as num).toDouble(), DateTime.parse(m['timestamp'] as String),
      course: (m['course'] as num?)?.toDouble(),
      courseAccuracy: (m['courseAccuracy'] as num?)?.toDouble(),
      speed: (m['speed'] as num?)?.toDouble(),
      speedAccuracy: (m['speedAccuracy'] as num?)?.toDouble());
  Map<String, dynamic> get point => {'latitude': latitude, 'longitude': longitude, 'timestamp': at.toUtc().toIso8601String()};
}

class TrajectoryBuffer {
  final List<LocationFix> _fixes = [];
  void add(LocationFix fix) {
    if (!fix.latitude.isFinite || !fix.longitude.isFinite || !fix.accuracy.isFinite ||
        fix.latitude.abs() > 90 || fix.longitude.abs() > 180 || fix.accuracy < 0) { return; }
    _fixes.add(fix);
    _fixes.sort((a, b) => a.at.compareTo(b.at));
    final newest = _fixes.last.at;
    _fixes.removeWhere((p) => newest.difference(p.at).inSeconds > 30);
    if (_fixes.length > 100) _fixes.removeRange(0, _fixes.length - 100);
  }
  LocationFix? nearest(DateTime frame, {double maxAccuracy = 30}) {
    LocationFix? result;
    for (final p in _fixes) {
      if (p.accuracy > maxAccuracy || p.at.difference(frame).abs() > const Duration(seconds: 3)) continue;
      if (result == null || p.at.difference(frame).abs() < result.at.difference(frame).abs()) result = p;
    }
    return result;
  }
  List<Map<String, dynamic>> trace(DateTime frame) => _fixes
      .where((p) => p.at.difference(frame) <= const Duration(seconds: 3) &&
          frame.difference(p.at) <= const Duration(seconds: 30))
      .map((p) => p.point).toList();
}
