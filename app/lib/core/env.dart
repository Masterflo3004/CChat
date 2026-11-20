/// Build-time configuration, passed with `--dart-define-from-file=env.json`.
class Env {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');

  /// Publishable (anon) key. Never put the secret / service-role key in the app.
  static const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty;
}
