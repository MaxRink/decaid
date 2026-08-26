import 'package:drift/drift.dart';
import 'package:reaprime/src/models/data/coffee_grind_profile.dart' as domain;
import 'package:reaprime/src/models/device/grinder_setting.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/tables/coffee_grind_profile_tables.dart';

part 'coffee_grind_profile_dao.g.dart';

@DriftAccessor(tables: [CoffeeGrindProfiles])
class CoffeeGrindProfileDao extends DatabaseAccessor<AppDatabase>
    with _$CoffeeGrindProfileDaoMixin {
  CoffeeGrindProfileDao(super.db);

  Future<List<domain.CoffeeGrindProfile>> findProfiles(
    domain.CoffeeSelection selection,
  ) async {
    final rows =
        await (select(coffeeGrindProfiles)..where(
              (profile) =>
                  profile.grinderDeviceId.equals(selection.grinderDeviceId),
            ))
            .get();
    return rows
        .map(_toDomain)
        .where((profile) => _matches(profile, selection))
        .toList(growable: false);
  }

  Future<domain.CoffeeGrindProfile?> resolveProfile(
    domain.CoffeeSelection selection,
  ) async {
    final profiles = await findProfiles(selection);
    return const domain.CoffeeGrindProfileResolver().resolve(
      profiles,
      selection,
    );
  }

  /// Saves a profile with an optimistic revision check.
  ///
  /// New profiles must use revision 0. An update must carry the revision last
  /// read by the caller; the persisted row is then incremented atomically.
  /// This prevents a stale coffee selection from silently replacing a newer
  /// dial setting.
  Future<void> saveProfile(domain.CoffeeGrindProfile profile) async {
    if (profile.revision < 0) {
      throw ArgumentError.value(profile.revision, 'revision');
    }
    await transaction(() async {
      final existing = await (select(
        coffeeGrindProfiles,
      )..where((row) => row.id.equals(profile.id))).getSingleOrNull();
      if (existing == null) {
        if (profile.revision != 0) {
          throw StateError('new coffee grind profile must start at revision 0');
        }
        await into(
          coffeeGrindProfiles,
        ).insert(_companion(profile, revision: 0));
        return;
      }
      if (existing.revision != profile.revision) {
        throw StateError(
          'stale coffee grind profile revision: expected ${existing.revision}, '
          'received ${profile.revision}',
        );
      }
      final updated =
          await (update(coffeeGrindProfiles)..where(
                (row) =>
                    row.id.equals(profile.id) &
                    row.revision.equals(profile.revision),
              ))
              .write(_companion(profile, revision: profile.revision + 1));
      if (updated != 1) {
        throw StateError(
          'coffee grind profile changed while it was being updated',
        );
      }
    });
  }

  CoffeeGrindProfilesCompanion _companion(
    domain.CoffeeGrindProfile profile, {
    required int revision,
  }) => CoffeeGrindProfilesCompanion.insert(
    id: profile.id,
    beanId: Value(profile.beanId),
    beanBatchId: Value(profile.beanBatchId),
    recipeId: Value(profile.recipeId),
    grinderDeviceId: profile.grinderDeviceId,
    setting: profile.setting.toJson(),
    algorithmVersion: profile.algorithmVersion,
    firmwareBuild: Value(profile.firmwareBuild),
    revision: Value(revision),
    updatedAt: profile.updatedAt,
    extras: Value(profile.extras.isEmpty ? null : profile.extras),
  );

  Future<void> deleteProfile(String id) {
    return (delete(
      coffeeGrindProfiles,
    )..where((profile) => profile.id.equals(id))).go();
  }

  domain.CoffeeGrindProfile _toDomain(CoffeeGrindProfile row) =>
      domain.CoffeeGrindProfile(
        id: row.id,
        beanId: row.beanId,
        beanBatchId: row.beanBatchId,
        recipeId: row.recipeId,
        grinderDeviceId: row.grinderDeviceId,
        setting: GrinderSetting.fromJson(row.setting),
        algorithmVersion: row.algorithmVersion,
        firmwareBuild: row.firmwareBuild,
        revision: row.revision,
        updatedAt: row.updatedAt,
        extras: row.extras ?? const {},
      );

  bool _matches(
    domain.CoffeeGrindProfile profile,
    domain.CoffeeSelection selection,
  ) {
    return (profile.beanBatchId == null ||
            profile.beanBatchId == selection.beanBatchId) &&
        (profile.beanId == null || profile.beanId == selection.beanId) &&
        (profile.recipeId == null || profile.recipeId == selection.recipeId);
  }
}
