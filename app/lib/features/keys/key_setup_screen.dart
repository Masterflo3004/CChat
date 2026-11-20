import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../crypto/e2ee.dart';
import '../../providers.dart';
import '../../services/session.dart';

/// Create an encryption passphrase (first device) or unlock with it (new device).
class KeySetupScreen extends ConsumerStatefulWidget {
  const KeySetupScreen({super.key});

  @override
  ConsumerState<KeySetupScreen> createState() => _KeySetupScreenState();
}

class _KeySetupScreenState extends ConsumerState<KeySetupScreen> {
  final _form = GlobalKey<FormState>();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _resetting = false;
  String? _error;

  @override
  void dispose() {
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit(bool create) async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final session = ref.read(appSessionProvider);
    try {
      if (create) {
        final wasReset = _resetting;
        final chat = ref.read(chatServiceProvider);
        await session.createKeys(_pass.text);
        // New identity: give every conversation a fresh key wrapped for the new key.
        if (wasReset) await chat.rotateAll();
      } else {
        await session.unlock(_pass.text);
      }
    } on WrongPassphraseException {
      setState(() => _error = 'Wrong passphrase');
    } catch (e) {
      setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset encryption keys?'),
        content: const Text(
          'You will get new keys. All messages sent before the reset become '
          'permanently unreadable for you, on every device.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok == true) setState(() => _resetting = true);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(appSessionProvider);
    final create = session.stage == SessionStage.needsKeySetup || _resetting;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(create ? 'Set up encryption' : 'Unlock your messages'),
        actions: [TextButton(onPressed: session.signOut, child: const Text('Sign out'))],
      ),
      body: Narrow(
        maxWidth: 460,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(create ? Icons.key : Icons.lock_open, size: 48, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(
                  create
                      ? 'Choose an encryption passphrase. Your private keys are encrypted with it '
                            'on this device before being backed up, so you can sign in on other devices.\n\n'
                            'Nobody – not even the server – can recover it. If you forget it, your old '
                            'messages are lost.'
                      : 'Enter your encryption passphrase to unlock your keys on this device.',
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _pass,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Encryption passphrase', border: OutlineInputBorder()),
                  validator: (v) => create && (v == null || v.length < 10) ? 'Use at least 10 characters' : null,
                  onFieldSubmitted: create ? null : (_) => _submit(false),
                ),
                if (create) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _confirm,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Repeat passphrase', border: OutlineInputBorder()),
                    validator: (v) => v != _pass.text ? 'Passphrases do not match' : null,
                    onFieldSubmitted: (_) => _submit(true),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _submit(create),
                  icon: _busy
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(create ? Icons.check : Icons.lock_open),
                  label: Text(_busy ? 'Deriving key…' : (create ? 'Create keys' : 'Unlock')),
                ),
                if (!create)
                  TextButton(
                    onPressed: _busy ? null : _confirmReset,
                    child: const Text('Forgot passphrase? Reset keys'),
                  ),
                if (_resetting)
                  TextButton(
                    onPressed: _busy ? null : () => setState(() => _resetting = false),
                    child: const Text('Cancel reset'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
