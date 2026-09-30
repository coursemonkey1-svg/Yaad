import 'package:flutter_test/flutter_test.dart';
import 'package:yaad/models/settings.dart';

void main() {
  group('AppSettings.activityView', () {
    test('defaults to detailed', () {
      const s = AppSettings();
      expect(s.activityView, AppSettings.viewDetailed);
      expect(s.activityView, 'detailed');
    });

    test('toMap/fromMap round-trips the chosen view', () {
      const detailed = AppSettings(activityView: 'detailed');
      expect(AppSettings.fromMap(detailed.toMap()).activityView,
          'detailed');

      const compact = AppSettings(activityView: 'compact');
      expect(AppSettings.fromMap(compact.toMap()).activityView,
          'compact');
    });

    test('fromMap fills the default when the key is missing', () {
      final map = const AppSettings().toMap()..remove('activityView');
      expect(AppSettings.fromMap(map).activityView, 'detailed');
    });

    test('fromMap falls back to detailed for unknown values', () {
      final map = const AppSettings().toMap()
        ..['activityView'] = 'wallOfText';
      expect(AppSettings.fromMap(map).activityView, 'detailed');
    });

    test('copyWith preserves and changes activityView', () {
      const base = AppSettings();
      expect(base.copyWith().activityView, 'detailed');
      expect(base.copyWith(activityView: 'compact').activityView,
          'compact');
      expect(
          base
              .copyWith(activityView: 'compact')
              .copyWith(currency: 'USD')
              .activityView,
          'compact');
    });
  });
}
