import 'package:go_router/go_router.dart';

import '../features/auth/sign_in_screen.dart';
import '../features/chat/chat_screen.dart';
import '../features/chat/conversation_info_screen.dart';
import '../features/community/gallery_screen.dart';
import '../features/community/moderation_screen.dart';
import '../features/conversations/conversation_list_screen.dart';
import '../features/conversations/new_chat_screen.dart';
import '../features/customize/customize_screen.dart';
import '../features/keys/key_setup_screen.dart';
import '../features/splash_screen.dart';
import '../services/session.dart';

GoRouter buildRouter(AppSession session) {
  // Where the user wanted to go before being sent to splash / sign-in / keys.
  String? pending;
  const gates = {'/splash', '/sign-in', '/keys'};

  return GoRouter(
    initialLocation: '/',
    refreshListenable: session,
    redirect: (context, state) {
      final loc = state.matchedLocation;
      String? only(String path) {
        if (loc == path) return null;
        if (!gates.contains(loc)) pending = state.uri.toString();
        return path;
      }

      switch (session.stage) {
        case SessionStage.loading:
        case SessionStage.error:
          return only('/splash');
        case SessionStage.signedOut:
          return only('/sign-in');
        case SessionStage.needsKeySetup:
        case SessionStage.needsUnlock:
          return only('/keys');
        case SessionStage.ready:
          if (gates.contains(loc)) {
            final target = pending ?? '/';
            pending = null;
            return target;
          }
          return null;
      }
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
      GoRoute(path: '/keys', builder: (_, _) => const KeySetupScreen()),
      GoRoute(
        path: '/',
        builder: (_, _) => const ConversationListScreen(),
        routes: [
          GoRoute(path: 'new', builder: (_, _) => const NewChatScreen()),
          GoRoute(path: 'customize', builder: (_, _) => const CustomizeScreen()),
          GoRoute(path: 'gallery', builder: (_, _) => const GalleryScreen()),
          GoRoute(path: 'moderation', builder: (_, _) => const ModerationScreen()),
          GoRoute(
            path: 'chat/:id',
            builder: (_, s) => ChatScreen(conversationId: s.pathParameters['id']!),
            routes: [
              GoRoute(
                path: 'info',
                builder: (_, s) => ConversationInfoScreen(conversationId: s.pathParameters['id']!),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}
