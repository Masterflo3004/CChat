import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/env.dart';
import 'core/router.dart';
import 'providers.dart';
import 'services/session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!Env.isConfigured) {
    runApp(const _MissingConfigApp());
    return;
  }

  await Supabase.initialize(url: Env.supabaseUrl, publishableKey: Env.supabaseKey);
  final session = AppSession(Supabase.instance.client);

  runApp(
    ProviderScope(
      overrides: [appSessionProvider.overrideWithValue(session)],
      child: CChatApp(session: session),
    ),
  );
}

class CChatApp extends StatefulWidget {
  const CChatApp({super.key, required this.session});
  final AppSession session;

  @override
  State<CChatApp> createState() => _CChatAppState();
}

class _CChatAppState extends State<CChatApp> {
  late final router = buildRouter(widget.session);

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF5B5BD6);
    return MaterialApp.router(
      title: 'CChat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      routerConfig: router,
    );
  }
}

class _MissingConfigApp extends StatelessWidget {
  const _MissingConfigApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Supabase is not configured.\n\n'
              'Run with: flutter run --dart-define-from-file=env.json\n'
              '(copy env.example.json to env.json and fill in your project URL and publishable key)',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
