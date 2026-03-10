// dart format width=80
// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'connection_config.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ConnectionConfig {
  String? get id;
  String get label;
  String get host;
  int get port;
  String get username;
  AuthMethod get authMethod;
  DateTime? get createdAt;

  /// Create a copy of ConnectionConfig
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $ConnectionConfigCopyWith<ConnectionConfig> get copyWith =>
      _$ConnectionConfigCopyWithImpl<ConnectionConfig>(
          this as ConnectionConfig, _$identity);

  /// Serializes this ConnectionConfig to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is ConnectionConfig &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.label, label) || other.label == label) &&
            (identical(other.host, host) || other.host == host) &&
            (identical(other.port, port) || other.port == port) &&
            (identical(other.username, username) ||
                other.username == username) &&
            (identical(other.authMethod, authMethod) ||
                other.authMethod == authMethod) &&
            (identical(other.createdAt, createdAt) ||
                other.createdAt == createdAt));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType, id, label, host, port, username, authMethod, createdAt);

  @override
  String toString() {
    return 'ConnectionConfig(id: $id, label: $label, host: $host, port: $port, username: $username, authMethod: $authMethod, createdAt: $createdAt)';
  }
}

/// @nodoc
abstract mixin class $ConnectionConfigCopyWith<$Res> {
  factory $ConnectionConfigCopyWith(
          ConnectionConfig value, $Res Function(ConnectionConfig) _then) =
      _$ConnectionConfigCopyWithImpl;
  @useResult
  $Res call(
      {String? id,
      String label,
      String host,
      int port,
      String username,
      AuthMethod authMethod,
      DateTime? createdAt});
}

/// @nodoc
class _$ConnectionConfigCopyWithImpl<$Res>
    implements $ConnectionConfigCopyWith<$Res> {
  _$ConnectionConfigCopyWithImpl(this._self, this._then);

  final ConnectionConfig _self;
  final $Res Function(ConnectionConfig) _then;

  /// Create a copy of ConnectionConfig
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = freezed,
    Object? label = null,
    Object? host = null,
    Object? port = null,
    Object? username = null,
    Object? authMethod = null,
    Object? createdAt = freezed,
  }) {
    return _then(_self.copyWith(
      id: freezed == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as String?,
      label: null == label
          ? _self.label
          : label // ignore: cast_nullable_to_non_nullable
              as String,
      host: null == host
          ? _self.host
          : host // ignore: cast_nullable_to_non_nullable
              as String,
      port: null == port
          ? _self.port
          : port // ignore: cast_nullable_to_non_nullable
              as int,
      username: null == username
          ? _self.username
          : username // ignore: cast_nullable_to_non_nullable
              as String,
      authMethod: null == authMethod
          ? _self.authMethod
          : authMethod // ignore: cast_nullable_to_non_nullable
              as AuthMethod,
      createdAt: freezed == createdAt
          ? _self.createdAt
          : createdAt // ignore: cast_nullable_to_non_nullable
              as DateTime?,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _ConnectionConfig implements ConnectionConfig {
  const _ConnectionConfig(
      {this.id,
      required this.label,
      required this.host,
      this.port = 22,
      required this.username,
      this.authMethod = AuthMethod.password,
      this.createdAt});
  factory _ConnectionConfig.fromJson(Map<String, dynamic> json) =>
      _$ConnectionConfigFromJson(json);

  @override
  final String? id;
  @override
  final String label;
  @override
  final String host;
  @override
  @JsonKey()
  final int port;
  @override
  final String username;
  @override
  @JsonKey()
  final AuthMethod authMethod;
  @override
  final DateTime? createdAt;

  /// Create a copy of ConnectionConfig
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$ConnectionConfigCopyWith<_ConnectionConfig> get copyWith =>
      __$ConnectionConfigCopyWithImpl<_ConnectionConfig>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$ConnectionConfigToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _ConnectionConfig &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.label, label) || other.label == label) &&
            (identical(other.host, host) || other.host == host) &&
            (identical(other.port, port) || other.port == port) &&
            (identical(other.username, username) ||
                other.username == username) &&
            (identical(other.authMethod, authMethod) ||
                other.authMethod == authMethod) &&
            (identical(other.createdAt, createdAt) ||
                other.createdAt == createdAt));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType, id, label, host, port, username, authMethod, createdAt);

  @override
  String toString() {
    return 'ConnectionConfig(id: $id, label: $label, host: $host, port: $port, username: $username, authMethod: $authMethod, createdAt: $createdAt)';
  }
}

/// @nodoc
abstract mixin class _$ConnectionConfigCopyWith<$Res>
    implements $ConnectionConfigCopyWith<$Res> {
  factory _$ConnectionConfigCopyWith(
          _ConnectionConfig value, $Res Function(_ConnectionConfig) _then) =
      __$ConnectionConfigCopyWithImpl;
  @override
  @useResult
  $Res call(
      {String? id,
      String label,
      String host,
      int port,
      String username,
      AuthMethod authMethod,
      DateTime? createdAt});
}

/// @nodoc
class __$ConnectionConfigCopyWithImpl<$Res>
    implements _$ConnectionConfigCopyWith<$Res> {
  __$ConnectionConfigCopyWithImpl(this._self, this._then);

  final _ConnectionConfig _self;
  final $Res Function(_ConnectionConfig) _then;

  /// Create a copy of ConnectionConfig
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? id = freezed,
    Object? label = null,
    Object? host = null,
    Object? port = null,
    Object? username = null,
    Object? authMethod = null,
    Object? createdAt = freezed,
  }) {
    return _then(_ConnectionConfig(
      id: freezed == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as String?,
      label: null == label
          ? _self.label
          : label // ignore: cast_nullable_to_non_nullable
              as String,
      host: null == host
          ? _self.host
          : host // ignore: cast_nullable_to_non_nullable
              as String,
      port: null == port
          ? _self.port
          : port // ignore: cast_nullable_to_non_nullable
              as int,
      username: null == username
          ? _self.username
          : username // ignore: cast_nullable_to_non_nullable
              as String,
      authMethod: null == authMethod
          ? _self.authMethod
          : authMethod // ignore: cast_nullable_to_non_nullable
              as AuthMethod,
      createdAt: freezed == createdAt
          ? _self.createdAt
          : createdAt // ignore: cast_nullable_to_non_nullable
              as DateTime?,
    ));
  }
}

// dart format on
