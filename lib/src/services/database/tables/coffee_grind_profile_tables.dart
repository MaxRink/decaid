import 'package:drift/drift.dart';
import 'package:reaprime/src/services/database/converters/json_converters.dart';

/// Persisted coffee/recipe-specific grinder settings.
///
/// The setting is stored as versioned JSON so named dials, numeric E64 DD
/// values, and future grinder domains can coexist without schema churn.
class CoffeeGrindProfiles extends Table {
  TextColumn get id => text()();
  TextColumn get beanId => text().nullable()();
  TextColumn get beanBatchId => text().nullable()();
  TextColumn get recipeId => text().nullable()();
  TextColumn get grinderDeviceId => text()();
  TextColumn get setting => text().map(const JsonMapConverter())();
  TextColumn get algorithmVersion => text()();
  TextColumn get firmwareBuild => text().nullable()();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get extras =>
      text().map(const NullableJsonMapConverter()).nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
