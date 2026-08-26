import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/coffee_grind_profile.dart' as domain;
import 'package:reaprime/src/models/device/grinder_setting.dart';
import 'package:reaprime/src/services/database/database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  domain.CoffeeGrindProfile profile({
    String id = 'profile-1',
    String? beanId,
    String? beanBatchId,
    String? recipeId,
    int revision = 0,
    DateTime? updatedAt,
    double value = 42,
  }) => domain.CoffeeGrindProfile(
    id: id,
    beanId: beanId,
    beanBatchId: beanBatchId,
    recipeId: recipeId,
    grinderDeviceId: 'e64-sim-1',
    setting: NumericGrinderSetting(
      domain: 'e64.dd-dum',
      value: value,
      unit: 'dd_dum',
    ),
    algorithmVersion: 'gbs-static-v1',
    firmwareBuild: 'simulator',
    revision: revision,
    updatedAt: updatedAt ?? DateTime.utc(2026, 8, 26),
    extras: const {'source': 'test'},
  );

  test(
    'round-trips a profile and resolves the most specific coffee match',
    () async {
      await db.coffeeGrindProfileDao.saveProfile(
        profile(id: 'fallback', updatedAt: DateTime.utc(2026, 8, 27)),
      );
      await db.coffeeGrindProfileDao.saveProfile(
        profile(
          id: 'exact',
          beanId: 'bean-1',
          beanBatchId: 'batch-1',
          recipeId: 'recipe-1',
          value: 38,
        ),
      );

      final resolved = await db.coffeeGrindProfileDao.resolveProfile(
        const domain.CoffeeSelection(
          grinderDeviceId: 'e64-sim-1',
          beanId: 'bean-1',
          beanBatchId: 'batch-1',
          recipeId: 'recipe-1',
        ),
      );

      expect(resolved, isNotNull);
      expect(resolved!.id, 'exact');
      expect(resolved.setting, isA<NumericGrinderSetting>());
      expect((resolved.setting as NumericGrinderSetting).value, 38);
      expect(resolved.extras, {'source': 'test'});
    },
  );

  test('increments revisions and rejects stale updates', () async {
    await db.coffeeGrindProfileDao.saveProfile(profile());

    await db.coffeeGrindProfileDao.saveProfile(profile(revision: 0, value: 43));
    final current = (await db.coffeeGrindProfileDao.findProfiles(
      const domain.CoffeeSelection(grinderDeviceId: 'e64-sim-1'),
    )).single;
    expect(current.revision, 1);
    expect((current.setting as NumericGrinderSetting).value, 43);

    expect(
      () =>
          db.coffeeGrindProfileDao.saveProfile(profile(revision: 0, value: 44)),
      throwsStateError,
    );

    await db.coffeeGrindProfileDao.saveProfile(profile(revision: 1, value: 45));
    final latest = (await db.coffeeGrindProfileDao.findProfiles(
      const domain.CoffeeSelection(grinderDeviceId: 'e64-sim-1'),
    )).single;
    expect(latest.revision, 2);
    expect((latest.setting as NumericGrinderSetting).value, 45);
  });

  test('requires revision zero for a new profile', () async {
    expect(
      () => db.coffeeGrindProfileDao.saveProfile(profile(revision: 1)),
      throwsStateError,
    );
  });
}
