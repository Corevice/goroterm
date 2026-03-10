import 'package:freezed_annotation/freezed_annotation.dart';

part 'connection_config.freezed.dart';
part 'connection_config.g.dart';

enum AuthMethod {
  password,
  key,
}

@freezed
abstract class ConnectionConfig with _$ConnectionConfig {
  const factory ConnectionConfig({
    String? id,
    required String label,
    required String host,
    @Default(22) int port,
    required String username,
    @Default(AuthMethod.password) AuthMethod authMethod,
    DateTime? createdAt,
  }) = _ConnectionConfig;

  factory ConnectionConfig.fromJson(Map<String, dynamic> json) =>
      _$ConnectionConfigFromJson(json);
}
