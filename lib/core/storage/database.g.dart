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

class $PortTunnelsTable extends PortTunnels
    with TableInfo<$PortTunnelsTable, PortTunnel> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PortTunnelsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _connectionIdMeta =
      const VerificationMeta('connectionId');
  @override
  late final GeneratedColumn<int> connectionId = GeneratedColumn<int>(
      'connection_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES connections (id) ON DELETE CASCADE'));
  static const VerificationMeta _labelMeta = const VerificationMeta('label');
  @override
  late final GeneratedColumn<String> label = GeneratedColumn<String>(
      'label', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _remoteHostMeta =
      const VerificationMeta('remoteHost');
  @override
  late final GeneratedColumn<String> remoteHost = GeneratedColumn<String>(
      'remote_host', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _remotePortMeta =
      const VerificationMeta('remotePort');
  @override
  late final GeneratedColumn<int> remotePort = GeneratedColumn<int>(
      'remote_port', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _preferredLocalPortMeta =
      const VerificationMeta('preferredLocalPort');
  @override
  late final GeneratedColumn<int> preferredLocalPort = GeneratedColumn<int>(
      'preferred_local_port', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _containerNameMeta =
      const VerificationMeta('containerName');
  @override
  late final GeneratedColumn<String> containerName = GeneratedColumn<String>(
      'container_name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        connectionId,
        label,
        remoteHost,
        remotePort,
        preferredLocalPort,
        containerName,
        createdAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'port_tunnels';
  @override
  VerificationContext validateIntegrity(Insertable<PortTunnel> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('connection_id')) {
      context.handle(
          _connectionIdMeta,
          connectionId.isAcceptableOrUnknown(
              data['connection_id']!, _connectionIdMeta));
    } else if (isInserting) {
      context.missing(_connectionIdMeta);
    }
    if (data.containsKey('label')) {
      context.handle(
          _labelMeta, label.isAcceptableOrUnknown(data['label']!, _labelMeta));
    } else if (isInserting) {
      context.missing(_labelMeta);
    }
    if (data.containsKey('remote_host')) {
      context.handle(
          _remoteHostMeta,
          remoteHost.isAcceptableOrUnknown(
              data['remote_host']!, _remoteHostMeta));
    } else if (isInserting) {
      context.missing(_remoteHostMeta);
    }
    if (data.containsKey('remote_port')) {
      context.handle(
          _remotePortMeta,
          remotePort.isAcceptableOrUnknown(
              data['remote_port']!, _remotePortMeta));
    } else if (isInserting) {
      context.missing(_remotePortMeta);
    }
    if (data.containsKey('preferred_local_port')) {
      context.handle(
          _preferredLocalPortMeta,
          preferredLocalPort.isAcceptableOrUnknown(
              data['preferred_local_port']!, _preferredLocalPortMeta));
    }
    if (data.containsKey('container_name')) {
      context.handle(
          _containerNameMeta,
          containerName.isAcceptableOrUnknown(
              data['container_name']!, _containerNameMeta));
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
  PortTunnel map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PortTunnel(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      connectionId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}connection_id'])!,
      label: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}label'])!,
      remoteHost: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}remote_host'])!,
      remotePort: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}remote_port'])!,
      preferredLocalPort: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}preferred_local_port']),
      containerName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}container_name']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $PortTunnelsTable createAlias(String alias) {
    return $PortTunnelsTable(attachedDatabase, alias);
  }
}

class PortTunnel extends DataClass implements Insertable<PortTunnel> {
  final String id;
  final int connectionId;
  final String label;
  final String remoteHost;
  final int remotePort;
  final int? preferredLocalPort;
  final String? containerName;
  final DateTime createdAt;
  const PortTunnel(
      {required this.id,
      required this.connectionId,
      required this.label,
      required this.remoteHost,
      required this.remotePort,
      this.preferredLocalPort,
      this.containerName,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['connection_id'] = Variable<int>(connectionId);
    map['label'] = Variable<String>(label);
    map['remote_host'] = Variable<String>(remoteHost);
    map['remote_port'] = Variable<int>(remotePort);
    if (!nullToAbsent || preferredLocalPort != null) {
      map['preferred_local_port'] = Variable<int>(preferredLocalPort);
    }
    if (!nullToAbsent || containerName != null) {
      map['container_name'] = Variable<String>(containerName);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  PortTunnelsCompanion toCompanion(bool nullToAbsent) {
    return PortTunnelsCompanion(
      id: Value(id),
      connectionId: Value(connectionId),
      label: Value(label),
      remoteHost: Value(remoteHost),
      remotePort: Value(remotePort),
      preferredLocalPort: preferredLocalPort == null && nullToAbsent
          ? const Value.absent()
          : Value(preferredLocalPort),
      containerName: containerName == null && nullToAbsent
          ? const Value.absent()
          : Value(containerName),
      createdAt: Value(createdAt),
    );
  }

  factory PortTunnel.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PortTunnel(
      id: serializer.fromJson<String>(json['id']),
      connectionId: serializer.fromJson<int>(json['connectionId']),
      label: serializer.fromJson<String>(json['label']),
      remoteHost: serializer.fromJson<String>(json['remoteHost']),
      remotePort: serializer.fromJson<int>(json['remotePort']),
      preferredLocalPort: serializer.fromJson<int?>(json['preferredLocalPort']),
      containerName: serializer.fromJson<String?>(json['containerName']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'connectionId': serializer.toJson<int>(connectionId),
      'label': serializer.toJson<String>(label),
      'remoteHost': serializer.toJson<String>(remoteHost),
      'remotePort': serializer.toJson<int>(remotePort),
      'preferredLocalPort': serializer.toJson<int?>(preferredLocalPort),
      'containerName': serializer.toJson<String?>(containerName),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  PortTunnel copyWith(
          {String? id,
          int? connectionId,
          String? label,
          String? remoteHost,
          int? remotePort,
          Value<int?> preferredLocalPort = const Value.absent(),
          Value<String?> containerName = const Value.absent(),
          DateTime? createdAt}) =>
      PortTunnel(
        id: id ?? this.id,
        connectionId: connectionId ?? this.connectionId,
        label: label ?? this.label,
        remoteHost: remoteHost ?? this.remoteHost,
        remotePort: remotePort ?? this.remotePort,
        preferredLocalPort: preferredLocalPort.present
            ? preferredLocalPort.value
            : this.preferredLocalPort,
        containerName:
            containerName.present ? containerName.value : this.containerName,
        createdAt: createdAt ?? this.createdAt,
      );
  PortTunnel copyWithCompanion(PortTunnelsCompanion data) {
    return PortTunnel(
      id: data.id.present ? data.id.value : this.id,
      connectionId: data.connectionId.present
          ? data.connectionId.value
          : this.connectionId,
      label: data.label.present ? data.label.value : this.label,
      remoteHost:
          data.remoteHost.present ? data.remoteHost.value : this.remoteHost,
      remotePort:
          data.remotePort.present ? data.remotePort.value : this.remotePort,
      preferredLocalPort: data.preferredLocalPort.present
          ? data.preferredLocalPort.value
          : this.preferredLocalPort,
      containerName: data.containerName.present
          ? data.containerName.value
          : this.containerName,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PortTunnel(')
          ..write('id: $id, ')
          ..write('connectionId: $connectionId, ')
          ..write('label: $label, ')
          ..write('remoteHost: $remoteHost, ')
          ..write('remotePort: $remotePort, ')
          ..write('preferredLocalPort: $preferredLocalPort, ')
          ..write('containerName: $containerName, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, connectionId, label, remoteHost,
      remotePort, preferredLocalPort, containerName, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PortTunnel &&
          other.id == this.id &&
          other.connectionId == this.connectionId &&
          other.label == this.label &&
          other.remoteHost == this.remoteHost &&
          other.remotePort == this.remotePort &&
          other.preferredLocalPort == this.preferredLocalPort &&
          other.containerName == this.containerName &&
          other.createdAt == this.createdAt);
}

class PortTunnelsCompanion extends UpdateCompanion<PortTunnel> {
  final Value<String> id;
  final Value<int> connectionId;
  final Value<String> label;
  final Value<String> remoteHost;
  final Value<int> remotePort;
  final Value<int?> preferredLocalPort;
  final Value<String?> containerName;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const PortTunnelsCompanion({
    this.id = const Value.absent(),
    this.connectionId = const Value.absent(),
    this.label = const Value.absent(),
    this.remoteHost = const Value.absent(),
    this.remotePort = const Value.absent(),
    this.preferredLocalPort = const Value.absent(),
    this.containerName = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PortTunnelsCompanion.insert({
    required String id,
    required int connectionId,
    required String label,
    required String remoteHost,
    required int remotePort,
    this.preferredLocalPort = const Value.absent(),
    this.containerName = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        connectionId = Value(connectionId),
        label = Value(label),
        remoteHost = Value(remoteHost),
        remotePort = Value(remotePort);
  static Insertable<PortTunnel> custom({
    Expression<String>? id,
    Expression<int>? connectionId,
    Expression<String>? label,
    Expression<String>? remoteHost,
    Expression<int>? remotePort,
    Expression<int>? preferredLocalPort,
    Expression<String>? containerName,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (connectionId != null) 'connection_id': connectionId,
      if (label != null) 'label': label,
      if (remoteHost != null) 'remote_host': remoteHost,
      if (remotePort != null) 'remote_port': remotePort,
      if (preferredLocalPort != null)
        'preferred_local_port': preferredLocalPort,
      if (containerName != null) 'container_name': containerName,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PortTunnelsCompanion copyWith(
      {Value<String>? id,
      Value<int>? connectionId,
      Value<String>? label,
      Value<String>? remoteHost,
      Value<int>? remotePort,
      Value<int?>? preferredLocalPort,
      Value<String?>? containerName,
      Value<DateTime>? createdAt,
      Value<int>? rowid}) {
    return PortTunnelsCompanion(
      id: id ?? this.id,
      connectionId: connectionId ?? this.connectionId,
      label: label ?? this.label,
      remoteHost: remoteHost ?? this.remoteHost,
      remotePort: remotePort ?? this.remotePort,
      preferredLocalPort: preferredLocalPort ?? this.preferredLocalPort,
      containerName: containerName ?? this.containerName,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (connectionId.present) {
      map['connection_id'] = Variable<int>(connectionId.value);
    }
    if (label.present) {
      map['label'] = Variable<String>(label.value);
    }
    if (remoteHost.present) {
      map['remote_host'] = Variable<String>(remoteHost.value);
    }
    if (remotePort.present) {
      map['remote_port'] = Variable<int>(remotePort.value);
    }
    if (preferredLocalPort.present) {
      map['preferred_local_port'] = Variable<int>(preferredLocalPort.value);
    }
    if (containerName.present) {
      map['container_name'] = Variable<String>(containerName.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PortTunnelsCompanion(')
          ..write('id: $id, ')
          ..write('connectionId: $connectionId, ')
          ..write('label: $label, ')
          ..write('remoteHost: $remoteHost, ')
          ..write('remotePort: $remotePort, ')
          ..write('preferredLocalPort: $preferredLocalPort, ')
          ..write('containerName: $containerName, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ConnectionsTable connections = $ConnectionsTable(this);
  late final $PortTunnelsTable portTunnels = $PortTunnelsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities =>
      [connections, portTunnels];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules(
        [
          WritePropagation(
            on: TableUpdateQuery.onTableName('connections',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('port_tunnels', kind: UpdateKind.delete),
            ],
          ),
        ],
      );
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

final class $$ConnectionsTableReferences
    extends BaseReferences<_$AppDatabase, $ConnectionsTable, Connection> {
  $$ConnectionsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$PortTunnelsTable, List<PortTunnel>>
      _portTunnelsRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.portTunnels,
              aliasName: $_aliasNameGenerator(
                  db.connections.id, db.portTunnels.connectionId));

  $$PortTunnelsTableProcessedTableManager get portTunnelsRefs {
    final manager = $$PortTunnelsTableTableManager($_db, $_db.portTunnels)
        .filter((f) => f.connectionId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_portTunnelsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

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

  Expression<bool> portTunnelsRefs(
      Expression<bool> Function($$PortTunnelsTableFilterComposer f) f) {
    final $$PortTunnelsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.portTunnels,
        getReferencedColumn: (t) => t.connectionId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PortTunnelsTableFilterComposer(
              $db: $db,
              $table: $db.portTunnels,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
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

  Expression<T> portTunnelsRefs<T extends Object>(
      Expression<T> Function($$PortTunnelsTableAnnotationComposer a) f) {
    final $$PortTunnelsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.portTunnels,
        getReferencedColumn: (t) => t.connectionId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PortTunnelsTableAnnotationComposer(
              $db: $db,
              $table: $db.portTunnels,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
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
    (Connection, $$ConnectionsTableReferences),
    Connection,
    PrefetchHooks Function({bool portTunnelsRefs})> {
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
              .map((e) => (
                    e.readTable(table),
                    $$ConnectionsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({portTunnelsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (portTunnelsRefs) db.portTunnels],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (portTunnelsRefs)
                    await $_getPrefetchedData<Connection, $ConnectionsTable,
                            PortTunnel>(
                        currentTable: table,
                        referencedTable: $$ConnectionsTableReferences
                            ._portTunnelsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ConnectionsTableReferences(db, table, p0)
                                .portTunnelsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.connectionId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
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
    (Connection, $$ConnectionsTableReferences),
    Connection,
    PrefetchHooks Function({bool portTunnelsRefs})>;
typedef $$PortTunnelsTableCreateCompanionBuilder = PortTunnelsCompanion
    Function({
  required String id,
  required int connectionId,
  required String label,
  required String remoteHost,
  required int remotePort,
  Value<int?> preferredLocalPort,
  Value<String?> containerName,
  Value<DateTime> createdAt,
  Value<int> rowid,
});
typedef $$PortTunnelsTableUpdateCompanionBuilder = PortTunnelsCompanion
    Function({
  Value<String> id,
  Value<int> connectionId,
  Value<String> label,
  Value<String> remoteHost,
  Value<int> remotePort,
  Value<int?> preferredLocalPort,
  Value<String?> containerName,
  Value<DateTime> createdAt,
  Value<int> rowid,
});

final class $$PortTunnelsTableReferences
    extends BaseReferences<_$AppDatabase, $PortTunnelsTable, PortTunnel> {
  $$PortTunnelsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ConnectionsTable _connectionIdTable(_$AppDatabase db) =>
      db.connections.createAlias(
          $_aliasNameGenerator(db.portTunnels.connectionId, db.connections.id));

  $$ConnectionsTableProcessedTableManager get connectionId {
    final $_column = $_itemColumn<int>('connection_id')!;

    final manager = $$ConnectionsTableTableManager($_db, $_db.connections)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_connectionIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$PortTunnelsTableFilterComposer
    extends Composer<_$AppDatabase, $PortTunnelsTable> {
  $$PortTunnelsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get label => $composableBuilder(
      column: $table.label, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get remoteHost => $composableBuilder(
      column: $table.remoteHost, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get remotePort => $composableBuilder(
      column: $table.remotePort, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get preferredLocalPort => $composableBuilder(
      column: $table.preferredLocalPort,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get containerName => $composableBuilder(
      column: $table.containerName, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  $$ConnectionsTableFilterComposer get connectionId {
    final $$ConnectionsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.connectionId,
        referencedTable: $db.connections,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConnectionsTableFilterComposer(
              $db: $db,
              $table: $db.connections,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$PortTunnelsTableOrderingComposer
    extends Composer<_$AppDatabase, $PortTunnelsTable> {
  $$PortTunnelsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get label => $composableBuilder(
      column: $table.label, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get remoteHost => $composableBuilder(
      column: $table.remoteHost, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get remotePort => $composableBuilder(
      column: $table.remotePort, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get preferredLocalPort => $composableBuilder(
      column: $table.preferredLocalPort,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get containerName => $composableBuilder(
      column: $table.containerName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  $$ConnectionsTableOrderingComposer get connectionId {
    final $$ConnectionsTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.connectionId,
        referencedTable: $db.connections,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConnectionsTableOrderingComposer(
              $db: $db,
              $table: $db.connections,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$PortTunnelsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PortTunnelsTable> {
  $$PortTunnelsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get label =>
      $composableBuilder(column: $table.label, builder: (column) => column);

  GeneratedColumn<String> get remoteHost => $composableBuilder(
      column: $table.remoteHost, builder: (column) => column);

  GeneratedColumn<int> get remotePort => $composableBuilder(
      column: $table.remotePort, builder: (column) => column);

  GeneratedColumn<int> get preferredLocalPort => $composableBuilder(
      column: $table.preferredLocalPort, builder: (column) => column);

  GeneratedColumn<String> get containerName => $composableBuilder(
      column: $table.containerName, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$ConnectionsTableAnnotationComposer get connectionId {
    final $$ConnectionsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.connectionId,
        referencedTable: $db.connections,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConnectionsTableAnnotationComposer(
              $db: $db,
              $table: $db.connections,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$PortTunnelsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $PortTunnelsTable,
    PortTunnel,
    $$PortTunnelsTableFilterComposer,
    $$PortTunnelsTableOrderingComposer,
    $$PortTunnelsTableAnnotationComposer,
    $$PortTunnelsTableCreateCompanionBuilder,
    $$PortTunnelsTableUpdateCompanionBuilder,
    (PortTunnel, $$PortTunnelsTableReferences),
    PortTunnel,
    PrefetchHooks Function({bool connectionId})> {
  $$PortTunnelsTableTableManager(_$AppDatabase db, $PortTunnelsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PortTunnelsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PortTunnelsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PortTunnelsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<int> connectionId = const Value.absent(),
            Value<String> label = const Value.absent(),
            Value<String> remoteHost = const Value.absent(),
            Value<int> remotePort = const Value.absent(),
            Value<int?> preferredLocalPort = const Value.absent(),
            Value<String?> containerName = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PortTunnelsCompanion(
            id: id,
            connectionId: connectionId,
            label: label,
            remoteHost: remoteHost,
            remotePort: remotePort,
            preferredLocalPort: preferredLocalPort,
            containerName: containerName,
            createdAt: createdAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required int connectionId,
            required String label,
            required String remoteHost,
            required int remotePort,
            Value<int?> preferredLocalPort = const Value.absent(),
            Value<String?> containerName = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PortTunnelsCompanion.insert(
            id: id,
            connectionId: connectionId,
            label: label,
            remoteHost: remoteHost,
            remotePort: remotePort,
            preferredLocalPort: preferredLocalPort,
            containerName: containerName,
            createdAt: createdAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$PortTunnelsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({connectionId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (connectionId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.connectionId,
                    referencedTable:
                        $$PortTunnelsTableReferences._connectionIdTable(db),
                    referencedColumn:
                        $$PortTunnelsTableReferences._connectionIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$PortTunnelsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $PortTunnelsTable,
    PortTunnel,
    $$PortTunnelsTableFilterComposer,
    $$PortTunnelsTableOrderingComposer,
    $$PortTunnelsTableAnnotationComposer,
    $$PortTunnelsTableCreateCompanionBuilder,
    $$PortTunnelsTableUpdateCompanionBuilder,
    (PortTunnel, $$PortTunnelsTableReferences),
    PortTunnel,
    PrefetchHooks Function({bool connectionId})>;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ConnectionsTableTableManager get connections =>
      $$ConnectionsTableTableManager(_db, _db.connections);
  $$PortTunnelsTableTableManager get portTunnels =>
      $$PortTunnelsTableTableManager(_db, _db.portTunnels);
}
