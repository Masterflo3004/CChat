import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../providers.dart';
import '../services/session.dart';

class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(appSessionProvider);
    return Scaffold(
      body: Center(
        child: ListenableBuilder(
          listenable: session,
          builder: (context, _) {
            if (session.stage != SessionStage.error) return const CircularProgressIndicator();
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off, size: 48),
                  const SizedBox(height: 16),
                  Text('Could not load your account.\n${session.errorMessage ?? ''}', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: session.retry, child: const Text('Retry')),
                  TextButton(onPressed: session.signOut, child: const Text('Sign out')),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
