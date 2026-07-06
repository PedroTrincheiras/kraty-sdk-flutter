# Kraty Flutter SDK — public surface (v0.6.0)

Canonical method + type listing for `kraty` (Dart package). Update this
file in the same commit as any signature change.

All methods sit on the `Kraty` facade unless noted. Every async method
returns a `Future`. The optional `as` field on resource calls is for
server-side tooling.

## `Kraty` facade

```dart
Kraty(KratyClientOptions options)

String? get activeExternalPlayerId
Future<(String externalPlayerId, String secret)> ensureIdentity()
Future<void> signIn(String externalPlayerId, String secret)
Future<void> logout()
Future<void> close()  // dispose resources

// Finalization catch-up (docs/05b). Fires exactly once per board across the
// live SSE `finalized` event AND boards that ended while the player was away.
void Function() onFinalized(FinalizationListener cb)      // returns unsubscribe
Future<List<FinalizationResult>> checkFinalizations()     // call on app foreground/reconnect
Future<void> dismiss(MembershipRef ref)                   // ack one handled result
Future<int> clearReported()                               // bulk-drop delivered entries
```

`FinalizationResult` = `{ MembershipRef ref; String reason; SelfEntry? self; List<FinalStanding>? standings; String? eventKey }`; `reason` uses the `FinalizationReason` consts (`sessionTerminated` \| `windowClosed` \| `periodRolled` \| `finalized`). Registry persistence is injectable via `KratyClientOptions.membershipStore` (`SharedPreferencesMembershipStore` in Flutter, `InMemoryMembershipStore` in pure-Dart).

## `kraty.events` — `EventsClient`

```dart
Future<List<EventListing>> listForPlayer({String? as})
Future<StartAttemptResponse> start(String eventKey, {Map<String, Object?>? playerContext, String? idempotencyKey, String? as})
Future<ProgressResponse> progress(String eventKey, String attemptId, ProgressInput input, {String? as})
```

## `kraty.leaderboards` — `LeaderboardsClient`

The dashboard-configured cross-event boards. Addressed by stable
game-scoped **key**. Wire endpoints:

- `GET /sdk/v1/leaderboards/:key`
- `GET /sdk/v1/leaderboards/:key/standings`
- `GET /sdk/v1/leaderboards/:key/periods`
- `POST /sdk/v1/players/:externalId/leaderboards/:key/join`
- `POST /sdk/v1/players/:externalId/leaderboards/:key/score`

```dart
Future<Leaderboard>            read(String key, {LeaderboardReadOptions? options})
Future<Leaderboard>            join(String key, {int? limit, String? segment, String? as})
Future<BoardStandings>         standings(String key, {StandingsReadOptions? options})
Future<LeaderboardScoreResult> submitScore(String key, num value, {String? segment, String? idempotencyKey, String? as})
Future<LeaderboardPeriods>     listPeriods(String key, {int? limit})
```

`LeaderboardReadOptions`:
- `int? limit` — 1–200, default 50 server-side
- `String? segment` — bucket value; required only for `context` segmentation. Omit for `progression`-segmented boards (server derives the caller's division); unsegmented boards ignore it
- `String? period` — `"current"` (default) or an ISO timestamp from `LeaderboardPeriod.periodStartedAt`
- `bool includeSelf` — when true, response includes `self: { rank, score }` (live periods only)
- `String? externalId` — required when `includeSelf` is true; lazily resolved otherwise

`join` — enrols the active player at score 0 without submitting a score; returns the current standings with `joined: true`. Idempotent (never resets an existing score). Pass `segment` for `context` boards; omit for `progression` boards (server derives the division from the caller's balance).

`standings` — multi-segment read. Returns one `StandingsSegment` block per segment selected by `scope`. `StandingsReadOptions`:
- `String? scope` — `'self_segment'`, `'mine'`, `'segment'`, `'all'` (default `'all'`)
- `String? segment` — required when `scope == 'segment'` on a segmented board
- `String? period` — `'current'` (default) or an ISO timestamp from `listPeriods`
- `String? externalId` — auto-resolved for `self_segment` / `mine`
- `int? limit` — per-segment top-N (1..200, default 50)
- `int? maxSegments` — cap on returned segment blocks (1..100, default 20)

`BoardStandings`: `key`, `sharedLeaderboardId`, `scope`, `resetCadence`, `scoreAggregation`, `period`, `List<StandingsSegment> segments`, `bool segmentsTruncated`.
`StandingsSegment`: `String? segment`, `bool participated`, `int? selfRank`, `List<LeaderboardEntry> entries`.

`submitScore` — submit a score for the active player directly to the board, outside an event attempt. `segment` is required only for `context` segmentation; omit for `progression` boards (server derives the division); unsegmented boards ignore it. Errors: `client_scoring_disabled` (403, board is server-only), `score_not_supported` (400, progression-ranked board), `not_found` (404), `validation_failed` (400). Returns `LeaderboardScoreResult`:
- `String leaderboardId`
- `num score`
- `int? rank`

## `kraty.eventLeaderboards` — `EventLeaderboardsClient`

The auto-generated per-event-window leaderboard. Addressed by the
**UUID** returned in `events.start(...)`'s `attempt.leaderboardId`.
Includes Server-Sent Events live streaming. Wire endpoints:

- `GET /sdk/v1/event-leaderboards/:id`
- `GET /sdk/v1/event-leaderboards/:id/stream`
- `POST /sdk/v1/players/:externalId/event-leaderboards/:id/join`

```dart
Future<EventLeaderboard>       read(String leaderboardId, {EventLeaderboardReadOptions? options})
Future<EventLeaderboard>       join(String leaderboardId, {int? limit, String? as})
Future<LeaderboardStream>      live(String leaderboardId)
LiveLeaderboardSubscription   subscribe(String leaderboardId, {Duration pollInterval = const Duration(seconds: 15)})
```

`join` — enrols the active player in the current event window at score 0 without starting a scoring attempt; returns the board with `joined: true`. Idempotent. Throws `KratyApiError` with code `conflict` (409) once the window has finalized.

`EventLeaderboardReadOptions`:
- `int? limit`
- `bool includeSelf`
- `String? externalId`

`EventLeaderboard` read response includes `bool finalized` and, when finalized, `String? finalizedReason` (`session_terminated` \| `window_closed`) — powers the finalization catch-up's session-vs-window distinction.

`LiveLeaderboardSubscription`:
- `Stream<LeaderboardStreamEvent> events` — broadcast stream, deduped by `(participantId, score)`
- `Stream<Object> errors` — transport / poll failures (non-fatal)
- `Future<void> cancel()` — idempotent

Set `pollInterval: Duration.zero` to disable polling (SSE-only).

## `kraty.grants` — `GrantsClient`

```dart
Future<List<Grant>>      listPending({int? limit, String? as})
Future<Grant>            claim(String grantId, {String? idempotencyKey, String? as})
Future<OpenCrateResponse> open(String grantId, {String? idempotencyKey, String? as})
Future<CollectAllResult> collectAll({String? as})
```

`CollectAllResult`:
- `List<Grant> opened`
- `List<Grant> claimed`
- `List<CollectAllFailure> failures`
- `bool get hasFailures`

## `kraty.lobbies` — `LobbiesClient`

```dart
Future<Lobby> read(String lobbyId)
```

## `kraty.inventory` — `InventoryClient`

```dart
Future<List<PlayerItemHolding>> list({String? as})
Future<ConsumeItemResult>       consume(String itemKey, ConsumeItemInput input, {String? as})
```

## `kraty.wallet` — `WalletClient`

```dart
Future<List<PlayerWalletHolding>> list({String? as})
Future<DebitWalletResult>         debit(String economyKey, DebitWalletInput input, {String? as})
```

## `kraty.players` — `PlayersClient`

```dart
Future<PlayerRegistration> register(String externalPlayerId, {bool force = false})
```

## `kraty.catalog` — `CatalogClient`

```dart
Future<Catalog> get()
```

## Polling helpers

```dart
Stream<List<Grant>> pollPendingGrants(GrantsClient grants, {PollPendingGrantsOptions? options})
Future<Lobby>       pollLobbyUntilActive(LobbiesClient lobbies, String lobbyId, {PollLobbyOptions? options})
```

## Secret stores

```dart
abstract class SecretStore { ... }
class InMemorySecretStore implements SecretStore        // tests
class DefaultSecretStore implements SecretStore         // best-effort default
class SharedPreferencesSecretStore implements SecretStore  // wraps shared_preferences
```

## DTOs (response shapes)

`Attempt`, `StartAttemptResponse`, `ProgressInput`, `ProgressResponse`,
`MilestoneFired`, `EventListing`, `EntryCost`, `EntryCostCurrency`,
`EntryCostItem`, `Leaderboard`, `EventLeaderboard`, `LeaderboardEntry`,
`LeaderboardSelf`, `LeaderboardPeriod`, `LeaderboardPeriods`, `Grant`,
`OpenCrateResponse`, `Lobby`, `PlayerItemHolding`, `PlayerWalletHolding`,
`PlayerRegistration`, `ConsumeItemInput`, `ConsumeItemResult`,
`DebitWalletInput`, `DebitWalletResult`, `Catalog`, `CatalogItem`,
`CatalogCurrency`, `RewardBundlePreview`, `RewardEntryPreview`,
`RewardPolicySummary`, `RewardPolicyTier`.

## Errors

```dart
class KratyApiError extends Error      // non-2xx — has code, status, message
class KratyNetworkError extends Error  // transport / parse failure
```

`KratyApiError` boolean helpers:
`isLobbyForming`, `isInsufficientEntryCost`, `isPlayerSecretInvalid`,
`isPlayerAlreadyRegistered`, `isEntryRequirementFailed`,
`isNoLeaderboard`, `isNoActiveWindow`, `isMaxAttemptsReached`,
`isAttemptExpired`, `isAttemptCompleted`.
