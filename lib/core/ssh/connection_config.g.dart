// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'connection_config.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_ConnectionConfig _$ConnectionConfigFromJson(Map<String, dynamic> json) =>
    _ConnectionConfig(
      id: json['id'] as String?,
      label: json['label'] as String,
      host: json['host'] as String,
      port: (json['port'] as num?)?.toInt() ?? 22,
      username: json['username'] as String,
      authMethod:
          $enumDecodeNullable(_$AuthMethodEnumMap, json['authMethod']) ??
              AuthMethod.password,
      createdAt: json['createdAt'] == null
          ? null
          : DateTime.parse(json['createdAt'] as String),
    );

Map<String, dynamic> _$ConnectionConfigToJson(_ConnectionConfig instance) =>
    <String, dynamic>{
      'id': instance.id,
      'label': instance.label,
      'host': instance.host,
      'port': instance.port,
      'username': instance.username,
      'authMethod': _$AuthMethodEnumMap[instance.authMethod]!,
      'createdAt': instance.createdAt?.toIso8601String(),
    };

const _$AuthMethodEnumMap = {
  AuthMethod.password: 'password',
  AuthMethod.key: 'key',
};
