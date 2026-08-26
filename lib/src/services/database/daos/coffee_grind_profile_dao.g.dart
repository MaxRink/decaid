// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'coffee_grind_profile_dao.dart';

// ignore_for_file: type=lint
mixin _$CoffeeGrindProfileDaoMixin on DatabaseAccessor<AppDatabase> {
  $CoffeeGrindProfilesTable get coffeeGrindProfiles =>
      attachedDatabase.coffeeGrindProfiles;
  CoffeeGrindProfileDaoManager get managers =>
      CoffeeGrindProfileDaoManager(this);
}

class CoffeeGrindProfileDaoManager {
  final _$CoffeeGrindProfileDaoMixin _db;
  CoffeeGrindProfileDaoManager(this._db);
  $$CoffeeGrindProfilesTableTableManager get coffeeGrindProfiles =>
      $$CoffeeGrindProfilesTableTableManager(
        _db.attachedDatabase,
        _db.coffeeGrindProfiles,
      );
}
