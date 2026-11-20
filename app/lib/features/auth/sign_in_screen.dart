import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui.dart';
import '../../providers.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _username = TextEditingController();
  bool _signUp = false;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _username.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final auth = ref.read(supabaseProvider).auth;
    try {
      if (_signUp) {
        final res = await auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
          data: {'username': _username.text.trim().toLowerCase()},
        );
        if (res.session == null && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Check your email to confirm your account, then sign in.')));
          setState(() => _signUp = false);
        }
      } else {
        await auth.signInWithPassword(email: _email.text.trim(), password: _password.text);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Narrow(
        maxWidth: 420,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.lock_outline, size: 56, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 12),
                Text('CChat', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 4),
                const Text('End-to-end encrypted chat', textAlign: TextAlign.center),
                const SizedBox(height: 32),
                TextFormField(
                  controller: _email,
                  decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
                ),
                const SizedBox(height: 12),
                if (_signUp) ...[
                  TextFormField(
                    controller: _username,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      helperText: '3–24 characters: a–z, 0–9, _',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => RegExp(r'^[a-z0-9_]{3,24}$').hasMatch((v ?? '').trim().toLowerCase())
                        ? null
                        : 'Invalid username',
                  ),
                  const SizedBox(height: 12),
                ],
                TextFormField(
                  controller: _password,
                  decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  validator: (v) => (v == null || v.length < 8) ? 'At least 8 characters' : null,
                  onFieldSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_signUp ? 'Create account' : 'Sign in'),
                ),
                TextButton(
                  onPressed: _busy ? null : () => setState(() => _signUp = !_signUp),
                  child: Text(_signUp ? 'I already have an account' : 'Create a new account'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
