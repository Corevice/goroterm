// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $ConnectionsTable extends Connections
    with TableInfo<$ConnectionsTable, Connection> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConnectionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _labelMeta = const VerificationMeta('label');
  @override
  late final GeneratedColumn<String> label = GeneratedColumn<String>(
      'label', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _hostMeta = const VerificationMeta('host');
  @override
  late final GeneratedColumn<String> host = GeneratedColumn<String>(
      'host', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _portMeta = const VerificationMeta('port');
  @override
  late final GeneratedColumn<int> port = GeneratedColumn<int>(
      'port', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(22));
  static const VerificationMeta _usernameMeta =
      const VerificationMeta('username');
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
      'username', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _authMethodMeta =
      const VerificationMeta('authMethod');
  @override
  late final GeneratedColumn<String> authMethod = GeneratedColumn<String>(
      'auth_method', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('password'));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns =>
      [id, label, host, port, username, authMethod, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'connections';
  @override
  VerificationContext validateIntegrity(Insertable<Connection> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('label')) {
      context.handle(
          _labelMeta, label.isAcceptableOrUnknown(data['label']!, _labelMeta));
    } else if (isInserting) {
      context.missing(_labelMeta);
    }
    if (data.containsKey('host')) {
      context.handle(
          _hostMeta, host.isAcceptableOrUnknown(data['host']!, _hostMeta));
    } else if (isInserting) {
      context.missing(_hostMeta);
    }
    if (data.containsKey('port')) {
      context.handle(
          _portMeta, port.isAcceptableOrUnknown(data['port']!, _portMeta));
    }
    if (data.containsKey('username')) {
      context.handle(_usernameMeta,
          username.isAcceptableOrUnknown(data['username']!, _usernameMeta));
    } else if (isInserting) {
      context.missing(_usernameMeta);
    }
    if (data.containsKey('auth_method')) {
      context.handle(
          _authMethodMeta,
          authMethod.isAcceptableOrUnknown(
              data['auth_method']!, _authMethodMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Connection map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Connection(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      label: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}label'])!,
      host: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}host'])!,
      port: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}port'])!,
      username: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}username'])!,
      authMethod: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}auth_method'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $ConnectionsTable createAlias(String alias) {
    return $ConnectionsTable(attachedDatabase, alias);
  }
}

class Connection extends DataClass implements Insertable<Connection> {
  final int id;
  final String label;
  final String host;
  final int port;
  final String username;
  final String authMethod;
  final DateTime createdAt;
  const Connection(
      {required this.id,
      required this.label,
      required this.host,
      required this.port,
      required this.username,
      required this.authMethod,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['label'] = Variable<String>(label);
    map['host'] = Variable<String>(host);
    map['port'] = Variable<int>(port);
    map['username'] = Variable<String>(username);
    map['auth_method'] = Variable<String>(authMethod);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  ConnectionsCompanion toCompanion(bool nullToAbsent) {
    return ConnectionsCompanion(
      id: Value(id),
      label: Value(label),
      host: Value(host),
      port: Value(port),
      username: Value(username),
      authMethod: Value(authMethod),
      createdAt: Value(createdAt),
    );
  }

  factory Connection.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Connection(
      id: serializer.fromJson<int>(json['id']),
      label: serializer.fromJson<String>(json['label']),
      host: serializer.fromJson<String>(json['host']),
      port: serializer.fromJson<int>(json['port']),
      username: serializer.fromJson<String>(json['username']),
      authMethod: serializer.fromJson<String>(json['authMethod']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'label': serializer.toJson<String>(label),
      'host': serializer.toJson<String>(host),
      'port': serializer.toJson<int>(port),
      'username': serializer.toJson<String>(username),
      'authMethod': serializer.toJson<String>(authMethod),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  Connection copyWith(
          {int? id,
          String? label,
          String? host,
          int? port,
          String? username,
          String? authMethod,
          DateTime? createdAt}) =>
      Connection(
        id: id ?? this.id,
        label: label ?? this.label,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        authMethod: authMethod ?? this.authMethod,
        createdAt: createdAt ?? this.createdAt,
      );
  Connection copyWithCompanion(ConnectionsCompanion data) {
    return Connection(
      id: data.id.present ? data.id.value : this.id,
      label: data.label.present ? data.label.value : this.label,
      host: data.host.present ? data.host.value : this.host,
      port: data.port.present ? data.port.value : this.port,
      username: data.username.present ? data.username.value : this.username,
      authMethod:
          data.authMethod.present ? data.authMethod.value : this.authMethod,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Connection(')
          ..write('id: $id, ')
          ..write('label: $label, ')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('username: $username, ')
          ..write('authMethod: $authMethod, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, label, host, port, username, authMethod, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Connection &&
          other.id == this.id &&
          other.label == this.label &&
          other.host == this.host &&
          other.port == this.port &&
          other.username == this.username &&
          other.authMethod == this.authMethod &&
          other.createdAt == this.createdAt);
}

class ConnectionsCompanion extends UpdateCompanion<Connection> {
  final Value<int> id;
  final Value<String> label;
  final Value<String> host;
  final Value<int> port;
  final Value<String> username;
  final Value<String> authMethod;
  final Value<DateTime> createdAt;
  const ConnectionsCompanion({
    this.id = const Value.absent(),
    this.label = const Value.absent(),
    this.host = const Value.absent(),
    this.port = const Value.absent(),
    this.username = const Value.absent(),
    this.authMethod = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  ConnectionsCompanion.insert({
    this.id = const Value.absent(),
    required String label,
    required String host,
    this.port = const Value.absent(),
    required String username,
    this.authMethod = const Value.absent(),
    this.createdAt = const Value.absent(),
  })  : label = Value(label),
        host = Value(host),
        username = Value(username);
  static Insertable<Connection> custom({
    Expression<int>? id,
    Expression<String>? label,
    Expression<String>? host,
    Expression<int>? port,
    Expression<String>? username,
    Expression<String>? authMethod,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (label != null) 'label': label,
      if (host != null) 'host': host,
      if (port != null) 'port': port,
      if (username != null) 'username': username,
      if (authMethod != null) 'auth_method': authMethod,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  ConnectionsCompanion copyWith(
      {Value<int>? id,
      Value<String>? label,
      Value<String>? host,
      Value<int>? port,
      Value<String>? username,
      Value<String>? authMethod,
      Value<DateTime>? createdAt}) {
    return ConnectionsCompanion(
      id: id ?? this.id,
      label: label ?? this.label,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (label.present) {
      map['label'] = Variable<String>(label.value);
    }
    if (host.present) {
      map['host'] = Variable<String>(host.value);
    }
    if (port.present) {
      map['port'] = Variable<int>(port.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (authMethod.present) {
      map['auth_method'] = Variable<String>(authMethod.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConnectionsCompanion(')
          ..write('id: $id, ')
          ..write('label: $label, ')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('username: $username, ')
          ..write('authMethod: $authMethod, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ConnectionsTable connections = $ConnectionsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [connections];
}

typedef $$ConnectionsTableCreateCompanionBuilder = ConnectionsCompanion
    Function({
  Value<int> id,
  required String label,
  required String host,
  Value<int> port,
  required String username,
  Value<String> authMethod,
  Value<DateTime> createdAt,
});
typedef $$ConnectionsTableUpdateCompanionBuilder = ConnectionsCompanion
    Function({
  Value<int> id,
  Value<String> label,
  Value<String> host,
  Value<int> port,
  Value<String> username,
  Value<String> authMethod,
  Value<DateTime> createdAt,
});

class $$ConnectionsTableFilterComposer
    extends Composer<_$AppDatabase, $ConnectionsTable> {
  $$ConnectionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get label => $composableBuilder(
      column: $table.label, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get host => $composableBuilder(
      column: $table.host, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get port => $composableBuilder(
      column: $table.port, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get username => $composableBuilder(
      column: $table.username, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get authMethod => $composableBuilder(
      column: $table.authMethod, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));
}

class $$ConnectionsTableOrderingComposer
    extends Composer<_$AppDatabase, $ConnectionsTable> {
  $$ConnectionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get label => $composableBuilder(
      column: $table.label, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get host => $composableBuilder(
      column: $table.host, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get port => $composableBuilder(
      column: $table.port, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get username => $composableBuilder(
      column: $table.username, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get authMethod => $composableBuilder(
      column: $table.authMethod, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
}

class $$ConnectionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ConnectionsTable> {
  $$ConnectionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get label =>
      $composableBuilder(column: $table.label, builder: (column) => column);

  GeneratedColumn<String> get host =>
      $composableBuilder(column: $table.host, builder: (column) => column);

  GeneratedColumn<int> get port =>
      $composableBuilder(column: $table.port, builder: (column) => column);

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get authMethod => $composableBuilder(
      column: $table.authMethod, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$ConnectionsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $ConnectionsTable,
    Connection,
    $$ConnectionsTableFilterComposer,
    $$ConnectionsTableOrderingComposer,
    $$ConnectionsTableAnnotationComposer,
    $$ConnectionsTableCreateCompanionBuilder,
    $$ConnectionsTableUpdateCompanionBuilder,
    (Connection, BaseReferences<_$AppDatabase, $ConnectionsTable, Connection>),
    Connection,
    PrefetchHooks Function()> {
  $$ConnectionsTableTableManager(_$AppDatabase db, $ConnectionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConnectionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConnectionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConnectionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> label = const Value.absent(),
            Value<String> host = const Value.absent(),
            Value<int> port = const Value.absent(),
            Value<String> username = const Value.absent(),
            Value<String> authMethod = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
          }) =>
              ConnectionsCompanion(
            id: id,
            label: label,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            createdAt: createdAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String label,
            required String host,
            Value<int> port = const Value.absent(),
            required String username,
            Value<String> authMethod = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
          }) =>
              ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            createdAt: createdAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ConnectionsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $ConnectionsTable,
    Connection,
    $$ConnectionsTableFilterComposer,
    $$ConnectionsTableOrderingComposer,
    $$ConnectionsTableAnnotationComposer,
    $$ConnectionsTableCreateCompanionBuilder,
    $$ConnectionsTableUpdateCompanionBuilder,
    (Connection, BaseReferences<_$AppDatabase, $ConnectionsTable, Connection>),
    Connection,
    PrefetchHooks Function()>;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ConnectionsTableTableManager get connections =>
      $$ConnectionsTableTableManager(_db, _db.connections);
}
