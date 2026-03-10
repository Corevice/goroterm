import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
          SnackBar(content: Text('Failed to read file: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Connection' : 'New Connection'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: 'Label',
                hintText: 'My Server',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _hostController,
              decoration: const InputDecoration(
                labelText: 'Host *',
                hintText: 'example.com or 192.168.1.1',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Host is required';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: 'Port',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (value) {
                if (value == null || value.isEmpty) return 'Port is required';
                final port = int.tryParse(value);
                if (port == null || port < 1 || port > 65535) {
                  return 'Invalid port (1-65535)';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Username *',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Username is required';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _authMethod,
              decoration: const InputDecoration(
                labelText: 'Authentication',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'password', child: Text('Password')),
                DropdownMenuItem(value: 'key', child: Text('SSH Key')),
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
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
            if (_authMethod == 'key') ...[
              TextFormField(
                controller: _privateKeyController,
                decoration: const InputDecoration(
                  labelText: 'Private Key (PEM)',
                  hintText:
                      '-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
                maxLines: 8,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  if (!value.contains('BEGIN') || !value.contains('END')) {
                    return 'Invalid PEM format';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _pickKeyFile,
                icon: const Icon(Icons.folder_open),
                label: const Text('Load from file'),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passphraseController,
                decoration: const InputDecoration(
                  labelText: 'Passphrase (optional)',
                  hintText: 'Passphrase for encrypted key',
                  border: OutlineInputBorder(),
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
              label: Text(_isEditing ? 'Update' : 'Save'),
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
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
}
