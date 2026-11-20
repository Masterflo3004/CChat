import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data/models.dart';
import 'services/chat_service.dart';
import 'services/cosmetics_service.dart';
import 'services/community_service.dart';
import 'services/gif_service.dart';
import 'services/media_service.dart';
import 'services/moderation_service.dart';
import 'services/session.dart';

final supabaseProvider = Provider<SupabaseClient>((ref) => Supabase.instance.client);

/// Overridden in main() with the app-wide session instance.
final appSessionProvider = Provider<AppSession>((ref) => throw UnimplementedError());

final chatServiceProvider = Provider<ChatService>(
  (ref) => ChatService(ref.watch(supabaseProvider), ref.watch(appSessionProvider)),
);

final mediaProvider = Provider<MediaService>((ref) => MediaService(ref.watch(supabaseProvider)));

final cosmeticsProvider = Provider<CosmeticsService>(
  (ref) => CosmeticsService(ref.watch(supabaseProvider), ref.watch(appSessionProvider), ref.watch(mediaProvider)),
);

final communityProvider = Provider<CommunityService>(
  (ref) => CommunityService(ref.watch(supabaseProvider), ref.watch(appSessionProvider), ref.watch(mediaProvider)),
);

final moderationProvider = Provider<ModerationService>((ref) => ModerationService(ref.watch(supabaseProvider)));

final isModeratorProvider = FutureProvider.autoDispose<bool>(
  (ref) => ref.watch(moderationProvider).isModerator().catchError((_) => false),
);

/// Your own skins plus the ones you saved from the gallery.
final librarySkinsProvider = FutureProvider.autoDispose<List<MessageSkin>>((ref) async {
  final own = await ref.watch(cosmeticsProvider).mySkins();
  final saved = await ref.watch(communityProvider).savedSkins();
  final ownIds = {for (final s in own) s.id};
  return [...own, ...saved.where((s) => !ownIds.contains(s.id))];
});

/// Your own fonts plus the ones you saved from the gallery.
final libraryFontsProvider = FutureProvider.autoDispose<List<UserFont>>((ref) async {
  final own = await ref.watch(cosmeticsProvider).myFonts();
  final saved = await ref.watch(communityProvider).savedFonts();
  final ownIds = {for (final f in own) f.id};
  return [...own, ...saved.where((f) => !ownIds.contains(f.id))];
});

final gifServiceProvider = Provider<GifService>((ref) => GifService(ref.watch(supabaseProvider)));

final conversationsProvider = StreamProvider.autoDispose<List<Conversation>>(
  (ref) => ref.watch(chatServiceProvider).watchConversations(),
);

final messagesProvider = StreamProvider.autoDispose.family<List<RawMessage>, String>(
  (ref, conversationId) => ref.watch(chatServiceProvider).watchMessages(conversationId),
);
