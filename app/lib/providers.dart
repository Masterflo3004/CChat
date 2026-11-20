import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data/models.dart';
import 'services/chat_service.dart';
import 'services/cosmetics_service.dart';
import 'services/gif_service.dart';
import 'services/session.dart';

final supabaseProvider = Provider<SupabaseClient>((ref) => Supabase.instance.client);

/// Overridden in main() with the app-wide session instance.
final appSessionProvider = Provider<AppSession>((ref) => throw UnimplementedError());

final chatServiceProvider = Provider<ChatService>(
  (ref) => ChatService(ref.watch(supabaseProvider), ref.watch(appSessionProvider)),
);

final cosmeticsProvider = Provider<CosmeticsService>(
  (ref) => CosmeticsService(ref.watch(supabaseProvider), ref.watch(appSessionProvider)),
);

final gifServiceProvider = Provider<GifService>((ref) => GifService(ref.watch(supabaseProvider)));

final conversationsProvider = StreamProvider.autoDispose<List<Conversation>>(
  (ref) => ref.watch(chatServiceProvider).watchConversations(),
);

final messagesProvider = StreamProvider.autoDispose.family<List<RawMessage>, String>(
  (ref, conversationId) => ref.watch(chatServiceProvider).watchMessages(conversationId),
);

final mySkinsProvider = FutureProvider.autoDispose<List<MessageSkin>>((ref) => ref.watch(cosmeticsProvider).mySkins());

final myFontsProvider = FutureProvider.autoDispose<List<UserFont>>((ref) => ref.watch(cosmeticsProvider).myFonts());
