import 'package:drift/drift.dart';

part 'database.g.dart';

class Connections extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get label => text()();
  TextColumn get host => text()();
  IntColumn get port => integer().withDefault(const Constant(22))();
  TextColumn get username => text()();
  TextColumn get authMethod => text().withDefault(const Constant('password'))();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();
}

class PortTunnels extends Table {
  TextColumn get id => text()();
  IntColumn get connectionId =>
      integer().references(Connections, #id, onDelete: KeyAction.cascade)();
  TextColumn get label => text()();
  TextColumn get remoteHost => text()();
  IntColumn get remotePort => integer()();
  IntColumn get preferredLocalPort => integer().nullable()();
  TextColumn get containerName => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Connections, PortTunnels])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        if (from < 2) {
          await m.createTable(portTunnels);
        }
      },
      // sqlite ships with foreign-key enforcement disabled per-connection.
      // Enabling here makes the [PortTunnels.connectionId] cascade delete
      // actually fire when a Connections row is removed.
      beforeOpen: (details) async {
        await customStatement('PRAGMA foreign_keys = ON');
      },
    );
  }
}
