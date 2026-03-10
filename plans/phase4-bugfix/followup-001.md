# Phase 4 Followup: Add Missing SecureStorage Test

## What Went Wrong
Phase 4 plan (Step 5) explicitly required `test/core/storage/secure_storage_test.dart` with unit tests
for passphrase save/load/delete. This file was never created.

All other requirements are complete and verified:
- flutter analyze: No issues found
- flutter test: 172 tests pass
- flutter build apk --debug: success
- All features (sqlite3_flutter_libs, connection flow, SSH key UI, passphrase dialogs) implemented

## What Needs to Be Done

Create `test/core/storage/secure_storage_test.dart` with tests for:
1. `savePassphrase` / `loadPassphrase` — save and read back a passphrase
2. `loadPassphrase` returns null when not set
3. `deletePassphrase` — value is null after deletion
4. `deleteAllForConnection` — deletes password, private key, AND passphrase together

## Implementation Details

`SecureStorageService` is in `lib/core/storage/secure_storage.dart`.
It accepts a `FlutterSecureStorage? storage` parameter in its constructor,
so tests can inject a mock or fake.

The existing `test/core/storage/secure_storage_test.dart` pattern can be modeled after
`test/core/` if any exist — or use mocktail to mock `FlutterSecureStorage`.

Key prefix for passphrase: `conn_pp_{connectionId}`

## Expected Outcome
- `test/core/storage/secure_storage_test.dart` exists with at least 4 test cases
- `~/flutter/bin/flutter test` passes with all tests (172 + new tests)
- `~/flutter/bin/flutter analyze` still reports no issues

## Constraints
- Flutter SDK: `~/flutter/bin/flutter` (full path required)
- Only create `test/core/storage/secure_storage_test.dart`; do not modify other files
