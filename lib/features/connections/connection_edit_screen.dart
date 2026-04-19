import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_provider.dart';

class ConnectionEditScreen extends ConsumerStatefulWidget {
  const ConnectionEditScreen({super.key, this.connectionId});

  final int? connectionId;

  @override
  ConsumerState<ConnectionEditScreen> createState() =>
      _ConnectionEditScreenState();
}

class _ConnectionEditScreenState extends ConsumerState<ConnectionEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _labelController = TextEditingController();
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '22');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _privateKeyController = TextEditingController();
  final _passphraseController = TextEditingController();
  String _authMethod = 'password';
  bool _isLoading = false;
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    if (widget.connectionId != null) {
      _isEditing = true;
      _loadConnection();
    }
  }

  Future<void> _loadConnection() async {
    final repo = ref.read(connectionRepositoryProvider);
    final conn = await repo.getById(widget.connectionId!);
    if (conn != null && mounted) {
      _labelController.text = conn.label;
      _hostController.text = conn.host;
      _portController.text = conn.port.toString();
      _usernameController.text = conn.username;
      setState(() {
        _authMethod = conn.authMethod;
      });

      final secureStorage = ref.read(secureStorageProvider);
      final password = await secureStorage.loadPassword(conn.id);
      if (password != null && mounted) {
        _passwordController.text = password;
      }

      final privateKey = await secureStorage.loadPrivateKey(conn.id);
      if (privateKey != null && mounted) {
        _privateKeyController.text = privateKey;
      }

      final passphrase = await secureStorage.loadPassphrase(conn.id);
      if (passphrase != null && mounted) {
        _passphraseController.text = passphrase;
      }
    }
  }

  @override
  void dispose() {
    _labelController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _privateKeyController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  Future<void> _pickKeyFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null) return;
      final content = await File(path).readAsString();
      if (mounted) {
        _privateKeyController.text = content;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).failedToReadFile(e.toString()))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? l.editConnection : l.newConnection),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _labelController,
              decoration: InputDecoration(
                labelText: l.labelLabel,
                hintText: l.labelHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _hostController,
              decoration: InputDecoration(
                labelText: l.hostLabel,
                hintText: l.hostHint,
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l.hostRequired;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _portController,
              decoration: InputDecoration(
                labelText: l.portLabel,
                border: const OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (value) {
                if (value == null || value.isEmpty) return l.portRequired;
                final port = int.tryParse(value);
                if (port == null || port < 1 || port > 65535) {
                  return l.portInvalid;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _usernameController,
              decoration: InputDecoration(
                labelText: l.usernameLabel,
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l.usernameRequired;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _authMethod,
              decoration: InputDecoration(
                labelText: l.authenticationLabel,
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(value: 'password', child: Text(l.authPassword)),
                DropdownMenuItem(value: 'key', child: Text(l.authSshKey)),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _authMethod = value);
                }
              },
            ),
            const SizedBox(height: 16),
            if (_authMethod == 'password')
              TextFormField(
                controller: _passwordController,
                decoration: InputDecoration(
                  labelText: l.passwordLabel,
                  border: const OutlineInputBorder(),
                ),
                obscureText: true,
              ),
            if (_authMethod == 'key') ...[
              TextFormField(
                controller: _privateKeyController,
                decoration: InputDecoration(
                  labelText: l.privateKeyLabel,
                  hintText: l.privateKeyHint,
                  border: const OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
                maxLines: 8,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  if (!value.contains('BEGIN') || !value.contains('END')) {
                    return l.invalidPemFormat;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _pickKeyFile,
                icon: const Icon(Icons.folder_open),
                label: Text(l.loadFromFile),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passphraseController,
                decoration: InputDecoration(
                  labelText: l.passphraseLabel,
                  hintText: l.passphraseHint,
                  border: const OutlineInputBorder(),
                ),
                obscureText: true,
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _isLoading ? null : _save,
              icon: _isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(_isEditing ? l.update : l.save),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final notifier = ref.read(connectionListProvider.notifier);
      final pem = _authMethod == 'key' ? _privateKeyController.text.trim() : null;
      final passphrase =
          _authMethod == 'key' ? _passphraseController.text : null;

      if (_isEditing) {
        await notifier.updateConnection(
          id: widget.connectionId!,
          label: _labelController.text.trim(),
          host: _hostController.text.trim(),
          port: int.parse(_portController.text),
          username: _usernameController.text.trim(),
          authMethod: _authMethod,
          password:
              _authMethod == 'password' ? _passwordController.text : null,
          privateKeyPem: pem,
        );
        if (passphrase != null) {
          final secureStorage = ref.read(secureStorageProvider);
          if (passphrase.isNotEmpty) {
            await secureStorage.savePassphrase(widget.connectionId!, passphrase);
          } else {
            await secureStorage.deletePassphrase(widget.connectionId!);
          }
        }
      } else {
        final id = await notifier.addConnection(
          label: _labelController.text.trim(),
          host: _hostController.text.trim(),
          port: int.parse(_portController.text),
          username: _usernameController.text.trim(),
          authMethod: _authMethod,
          password:
              _authMethod == 'password' ? _passwordController.text : null,
          privateKeyPem: pem,
        );
        if (passphrase != null && passphrase.isNotEmpty) {
          final secureStorage = ref.read(secureStorageProvider);
          await secureStorage.savePassphrase(id, passphrase);
        }
      }

      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).failedToSave(e.toString()))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
}
