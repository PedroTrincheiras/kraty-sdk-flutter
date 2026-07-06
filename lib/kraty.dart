/// Dart/Flutter SDK for the Kraty game-events platform.
///
/// Auto-stamped idempotency keys preserved across retries,
/// exponential retry with jitter, sealed error codes, adaptive
/// polling helpers, SSE leaderboard streaming, and a one-call
/// per-player bootstrap.
///
/// ```dart
/// import 'package:kraty/kraty.dart';
///
/// final kraty = Kraty(KratyClientOptions(apiKey: '...'));
/// final pending = await kraty.grants.listPending();
/// ```
library;

export 'src/client.dart' show
    KratyClient,
    KratyClientOptions,
    KratyRetryConfig,
    KratyRequestInfo;
export 'src/errors.dart' show
    KratyApiError,
    KratyErrorCode,
    KratyErrorPayload,
    KratyNetworkError,
    KratyApiErrorIs;
export 'src/leaderboard_stream.dart' show LeaderboardStream, LeaderboardStreamEvent;
export 'src/resources.dart' show
    CatalogClient,
    CollectAllFailure,
    CollectAllResult,
    EventLeaderboardsClient,
    EventsClient,
    GrantsClient,
    InventoryClient,
    LeaderboardsClient,
    LobbiesClient,
    PlayersClient,
    PollLobbyOptions,
    PollPendingGrantsOptions,
    WalletClient,
    pollLobbyUntilActive,
    pollPendingGrants;
export 'src/types.dart' show
    Attempt,
    BoardStandings,
    Catalog,
    CatalogCurrency,
    CatalogItem,
    ConsumeItemInput,
    ConsumeItemResult,
    DebitWalletInput,
    DebitWalletResult,
    EntryCost,
    EntryCostCurrency,
    EntryCostItem,
    EventLeaderboard,
    EventLeaderboardReadOptions,
    EventListing,
    Grant,
    Leaderboard,
    LeaderboardEntry,
    LeaderboardPeriod,
    LeaderboardPeriods,
    LeaderboardReadOptions,
    LeaderboardScoreResult,
    LeaderboardSelf,
    Lobby,
    MilestoneFired,
    MilestoneRewardPreview,
    OpenCrateResponse,
    PlayerItemHolding,
    PlayerRegistration,
    PlayerWalletHolding,
    ProgressInput,
    ProgressResponse,
    RewardBundlePreview,
    RewardEntryPreview,
    RewardPolicySummary,
    RewardPolicyTier,
    StandingsReadOptions,
    StandingsSegment;

import 'src/client.dart';
import 'src/finalization.dart';
import 'src/resources.dart';

export 'src/secret_store.dart' show
    DefaultSecretStore,
    InMemorySecretStore,
    SecretStore,
    SharedPreferencesSecretStore;
export 'src/finalization.dart' show
    DefaultMembershipStore,
    EventBoardStatus,
    FinalStanding,
    FinalizationListener,
    FinalizationReason,
    FinalizationResult,
    FinalizationTracker,
    InMemoryMembershipStore,
    MembershipKind,
    MembershipRef,
    MembershipStatus,
    MembershipStore,
    SelfEntry,
    SharedPreferencesMembershipStore,
    StandingKind,
    TrackedMembership;

/// Convenience facade — instantiate one [Kraty] instead of wiring
/// [KratyClient] + each resource client by hand. All resource clients
/// share the same underlying [KratyClient] so retry config, telemetry,
/// and the HTTP connection pool are shared.
///
/// The minimum boot is one line — the SDK lazily registers a self-
/// serve player on the first player-scoped call and persists the
/// identity via [KratyClientOptions.secretStore]:
///
/// ```dart
/// final kraty = Kraty(KratyClientOptions(apiKey: '...'));
/// final pending = await kraty.grants.listPending();
/// ```
class Kraty {
  final KratyClient client;
  final EventsClient events;
  final LeaderboardsClient leaderboards;
  final EventLeaderboardsClient eventLeaderboards;
  final GrantsClient grants;
  final LobbiesClient lobbies;
  final InventoryClient inventory;
  final WalletClient wallet;
  final PlayersClient players;
  final CatalogClient catalog;

  Kraty._({
    required this.client,
    required this.events,
    required this.leaderboards,
    required this.eventLeaderboards,
    required this.grants,
    required this.lobbies,
    required this.inventory,
    required this.wallet,
    required this.players,
    required this.catalog,
  });

  factory Kraty(KratyClientOptions options) {
    final c = KratyClient(options);
    return Kraty._(
      client: c,
      events: EventsClient(c),
      leaderboards: LeaderboardsClient(c),
      eventLeaderboards: EventLeaderboardsClient(c),
      grants: GrantsClient(c),
      lobbies: LobbiesClient(c),
      inventory: InventoryClient(c),
      wallet: WalletClient(c),
      players: PlayersClient(c),
      catalog: CatalogClient(c),
    );
  }

  /// The active player this SDK currently represents. Returns null
  /// until the first player-scoped call resolves the identity (or
  /// [ensureIdentity] is awaited explicitly).
  String? get activeExternalPlayerId => client.activeExternalPlayerId;

  /// Resolve the active player identity, lazily registering a fresh
  /// one if no persisted identity exists. Most games never call this
  /// — any player-scoped resource method triggers it transparently.
  /// Reach for it only when you need the id available before the
  /// first request (e.g. to pre-greet the player by id).
  Future<({String externalPlayerId, String secret})> ensureIdentity() =>
      client.ensureIdentity();

  /// Forget the persisted identity. The next player-scoped call
  /// lazily registers a new player (or resumes a different id if the
  /// SecretStore holds one). Drop-in for a "sign out" button.
  Future<void> logout() => client.logout();

  /// Install an explicit identity on this SDK and persist it. Use
  /// when your own auth gave you back a Kraty `externalPlayerId` +
  /// `secret` — e.g. on a new device after a server-side device-link
  /// flow.
  Future<void> signIn({
    required String externalPlayerId,
    required String secret,
  }) =>
      client.signIn(externalPlayerId: externalPlayerId, secret: secret);

  /// Finalization catch-up (docs/05b). [onFinalized] fires when a board the
  /// player is in ends — live over SSE while subscribed, OR via
  /// [checkFinalizations] for boards that finalized while they were away
  /// (call it on app foreground / reconnect). Both paths deliver exactly
  /// once. [dismiss] / [clearReported] acknowledge handled results so they
  /// leave storage. Returns an unsubscribe function.
  void Function() onFinalized(FinalizationListener cb) =>
      client.onFinalized(cb);

  /// Poll tracked boards; report + return any that finalized while away.
  Future<List<FinalizationResult>> checkFinalizations() =>
      client.checkFinalizations();

  /// Acknowledge a handled finalization — drop it from the registry.
  Future<void> dismiss(MembershipRef ref) => client.dismiss(ref);

  /// Bulk-drop every already-reported membership. Returns the count.
  Future<int> clearReported() => client.clearReported();

  /// Releases the underlying HTTP client.
  void close() => client.close();
}
