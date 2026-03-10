sealed class AppError implements Exception {
  const AppError(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

class AuthenticationError extends AppError {
  const AuthenticationError(super.message);
}

class HostKeyError extends AppError {
  const HostKeyError(super.message, {required this.fingerprint});
  final String fingerprint;
}

class NetworkError extends AppError {
  const NetworkError(super.message);
}

class PermissionError extends AppError {
  const PermissionError(super.message);
}

class TmuxError extends AppError {
  const TmuxError(super.message, {this.reason = TmuxErrorReason.unknown});
  final TmuxErrorReason reason;
}

enum TmuxErrorReason {
  notInstalled,
  sessionNotFound,
  unknown,
}
