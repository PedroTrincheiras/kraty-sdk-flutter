/// Public response types for the `/sdk/v1` surface, mirroring the
/// OpenAPI spec at `apps/backend/openapi.json` and the hand-authored
/// TypeScript types in `@kraty/sdk`. Dart classes with `fromJson`
/// factories — manual rather than generated so contributors can read
/// the file standalone and so the SDK doesn't carry a code-gen
/// dependency.
library;

typedef JsonMap = Map<String, Object?>;

String _readString(JsonMap json, String key) =>
    json[key] is String ? json[key]! as String : '';

String? _readNullableString(JsonMap json, String key) {
  final v = json[key];
  return v is String ? v : null;
}

double _readDouble(JsonMap json, String key) {
  final v = json[key];
  if (v is num) return v.toDouble();
  return 0;
}

int _readInt(JsonMap json, String key) {
  final v = json[key];
  if (v is int) return v;
  if (v is num) return v.toInt();
  return 0;
}

bool _readBool(JsonMap json, String key) =>
    json[key] is bool ? json[key]! as bool : false;

Map<String, double> _readDoubleMap(JsonMap json, String key) {
  final v = json[key];
  if (v is Map) {
    return v.map((k, val) => MapEntry(k as String, (val as num).toDouble()));
  }
  return <String, double>{};
}

Map<String, Object?> _readObjectMap(JsonMap json, String key) {
  final v = json[key];
  if (v is Map) {
    return v.map((k, val) => MapEntry(k as String, val as Object?));
  }
  return <String, Object?>{};
}

/// A single attempt at an event. The SDK consumer holds onto the
/// `id` between `/start` and `/progress` calls.
class Attempt {
  final String id;
  final String eventId;
  final String eventWindowId;
  final String leaderboardId;
  final String playerId;
  final String startedAt;
  final String endsAt;
  final String? completedAt;
  final Map<String, double> metrics;
  final Map<String, double> metricsRaw;
  final double score;

  /// One of `in_progress`, `completed`, `expired`, `force_completed`.
  final String status;

  const Attempt({
    required this.id,
    required this.eventId,
    required this.eventWindowId,
    required this.leaderboardId,
    required this.playerId,
    required this.startedAt,
    required this.endsAt,
    required this.completedAt,
    required this.metrics,
    required this.metricsRaw,
    required this.score,
    required this.status,
  });

  factory Attempt.fromJson(JsonMap json) => Attempt(
        id: _readString(json, 'id'),
        eventId: _readString(json, 'eventId'),
        eventWindowId: _readString(json, 'eventWindowId'),
        leaderboardId: _readString(json, 'leaderboardId'),
        playerId: _readString(json, 'playerId'),
        startedAt: _readString(json, 'startedAt'),
        endsAt: _readString(json, 'endsAt'),
        completedAt: _readNullableString(json, 'completedAt'),
        metrics: _readDoubleMap(json, 'metrics'),
        metricsRaw: _readDoubleMap(json, 'metricsRaw'),
        score: _readDouble(json, 'score'),
        status: _readString(json, 'status'),
      );
}

class StartAttemptResponse {
  final Attempt attempt;
  final String leaderboardId;
  final String windowEndsAt;

  const StartAttemptResponse({
    required this.attempt,
    required this.leaderboardId,
    required this.windowEndsAt,
  });

  factory StartAttemptResponse.fromJson(JsonMap json) => StartAttemptResponse(
        attempt: Attempt.fromJson(json['attempt'] as JsonMap),
        leaderboardId: _readString(json, 'leaderboardId'),
        windowEndsAt: _readString(json, 'windowEndsAt'),
      );
}

/// One slot in an event's `entryCost.currencies` list — paid from
/// the player's wallet on attempt start. Lifted from the server-
/// side `EntryCost` shape verbatim.
class EntryCostCurrency {
  final String key;
  final int amount;
  const EntryCostCurrency({required this.key, required this.amount});
  factory EntryCostCurrency.fromJson(JsonMap j) => EntryCostCurrency(
        key: _readString(j, 'key'),
        amount: _readInt(j, 'amount'),
      );
}

/// One slot in an event's `entryCost.items` list — consumed from
/// inventory on attempt start.
class EntryCostItem {
  final String key;
  final int quantity;
  const EntryCostItem({required this.key, required this.quantity});
  factory EntryCostItem.fromJson(JsonMap j) => EntryCostItem(
        key: _readString(j, 'key'),
        quantity: _readInt(j, 'quantity'),
      );
}

/// Transactional cost paid on `events.start`. Server atomically
/// debits + creates the attempt in a single tx — partial debits
/// never persist. Missing entry triggers a `KratyApiError` with
/// code `insufficient_entry_cost`.
class EntryCost {
  final List<EntryCostCurrency> currencies;
  final List<EntryCostItem> items;

  const EntryCost({this.currencies = const [], this.items = const []});

  bool get isEmpty => currencies.isEmpty && items.isEmpty;

  factory EntryCost.fromJson(JsonMap j) => EntryCost(
        currencies: ((j['currencies'] as List?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((e) => EntryCostCurrency.fromJson(e.cast<String, Object?>()))
            .toList(growable: false),
        items: ((j['items'] as List?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((e) => EntryCostItem.fromJson(e.cast<String, Object?>()))
            .toList(growable: false),
      );
}

/// One slot inside a reward bundle or milestone reward payload.
/// Carry one of three shapes discriminated by [type]: `currency`,
/// `item`, or `crate`. Stored as a [JsonMap] so consumers can read
/// any of those shapes without N typed subclasses; helper getters
/// surface the common fields.
class RewardEntryPreview {
  final Map<String, Object?> raw;
  const RewardEntryPreview(this.raw);
  factory RewardEntryPreview.fromJson(JsonMap json) => RewardEntryPreview(json);

  /// One of `currency` | `item` | `crate`.
  String get type => raw['type'] is String ? raw['type'] as String : '';

  /// Set when [type] == `currency`. Empty otherwise.
  String get currencyKey =>
      raw['currencyKey'] is String ? raw['currencyKey'] as String : '';

  /// Set when [type] == `item`. Empty otherwise.
  String get itemKey =>
      raw['itemKey'] is String ? raw['itemKey'] as String : '';

  /// Set when [type] == `crate`. Empty otherwise.
  String get crateItemKey =>
      raw['crateItemKey'] is String ? raw['crateItemKey'] as String : '';

  /// Quantity (for `item` / `crate`) or amount (for `currency`).
  num get quantity {
    final v = raw[type == 'currency' ? 'amount' : 'quantity'];
    return v is num ? v : 0;
  }
}

/// Inline preview of a reward bundle's contents. Surfaced on
/// [EventListing.rewardPolicy] so the studio can render "you'll win
/// X" without resolving bundle IDs against a separate endpoint.
class RewardBundlePreview {
  final String key;
  final Object? name;
  final List<RewardEntryPreview> entries;
  const RewardBundlePreview({
    required this.key,
    required this.name,
    required this.entries,
  });
  factory RewardBundlePreview.fromJson(JsonMap json) => RewardBundlePreview(
        key: _readString(json, 'key'),
        name: json['name'],
        entries: ((json['entries'] as List?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((e) => RewardEntryPreview.fromJson(e.cast<String, Object?>()))
            .toList(growable: false),
      );
}

/// One milestone reward — fires when the player crosses [threshold]
/// on [metricKey] during a single attempt. Use this to render
/// "next milestone: 5 rabbits → 200 cash + 5 bullets" in your UI.
class MilestoneRewardPreview {
  final String key;
  final String metricKey;
  final num threshold;
  final List<RewardEntryPreview> entries;
  const MilestoneRewardPreview({
    required this.key,
    required this.metricKey,
    required this.threshold,
    required this.entries,
  });
  factory MilestoneRewardPreview.fromJson(JsonMap json) => MilestoneRewardPreview(
        key: _readString(json, 'key'),
        metricKey: _readString(json, 'metricKey'),
        threshold: (json['threshold'] is num) ? json['threshold']! as num : 0,
        entries: ((json['entries'] as List?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((e) => RewardEntryPreview.fromJson(e.cast<String, Object?>()))
            .toList(growable: false),
      );
}

/// One tier in a `rank_scaled` reward policy.
class RewardPolicyTier {
  final int fromRank;
  final int toRank;
  final RewardBundlePreview? bundle;
  const RewardPolicyTier({
    required this.fromRank,
    required this.toRank,
    required this.bundle,
  });
  factory RewardPolicyTier.fromJson(JsonMap json) => RewardPolicyTier(
        fromRank: _readInt(json, 'fromRank'),
        toRank: _readInt(json, 'toRank'),
        bundle: json['bundle'] is Map
            ? RewardBundlePreview.fromJson((json['bundle']! as Map).cast<String, Object?>())
            : null,
      );
}

/// Reward policy summary with inline bundle previews. Mirrors the
/// four sealed policy types the backend supports:
///
///  - `none` — event has no rewards (training / practice modes).
///  - `fixed_bundle` — everyone who completes gets [bundle].
///  - `rank_scaled` — bundle picked by leaderboard rank; see [tiers].
///  - `shared_pool` — currency pool split among winners; see [pool]
///    and [currencyKey].
class RewardPolicySummary {
  final String type;
  final RewardBundlePreview? bundle;
  final List<RewardPolicyTier> tiers;
  final num? pool;
  final String? currencyKey;
  const RewardPolicySummary({
    required this.type,
    required this.bundle,
    required this.tiers,
    required this.pool,
    required this.currencyKey,
  });
  factory RewardPolicySummary.fromJson(JsonMap json) => RewardPolicySummary(
        type: _readString(json, 'type').isEmpty ? 'none' : _readString(json, 'type'),
        bundle: json['bundle'] is Map
            ? RewardBundlePreview.fromJson((json['bundle']! as Map).cast<String, Object?>())
            : null,
        tiers: ((json['tiers'] as List?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((e) => RewardPolicyTier.fromJson(e.cast<String, Object?>()))
            .toList(growable: false),
        pool: json['pool'] is num ? json['pool']! as num : null,
        currencyKey: _readNullableString(json, 'currencyKey'),
      );
}

class EventListing {
  final String eventKey;

  /// LocalizedString — either a plain string or a map (see backend
  /// docs/02 § English-only v1). The SDK stores the raw JSON value
  /// so consumers can inspect the shape without a forced cast.
  final Object? name;
  final String windowId;
  final String startsAt;
  final String endsAt;
  final String? leaderboardId;
  final String? currentAttemptId;

  /// `single_metric` | `multi_metric` (and any future event-type
  /// registry entries). Lets the SDK pick the right UI without a
  /// hardcoded per-event catalog.
  final String type;

  /// `global` | `global_segmented` | `grouped` | `lobby_matched`.
  /// Combined with [leaderboardId] tells the SDK whether to expect
  /// `lobby_forming` on `events.start`.
  final String leaderboardMode;

  /// Free-form metric definitions from the event row (key, target,
  /// cap, scoreWeight, …). Same shape the server stores.
  final List<Map<String, Object?>> metrics;

  /// Player-condition tree — null when there's no join gate.
  final Map<String, Object?>? entryRequirement;

  /// Cost paid on attempt start. `null` (and `EntryCost.isEmpty`)
  /// both mean "free to enter".
  final EntryCost? entryCost;

  /// Studio-defined free-form blob. Event-level metadata merged with
  /// the active window's metadata (window keys win). Use for UI
  /// hints — banner image keys, theme colors, special-event copy.
  final Map<String, Object?> metadata;

  /// Mid-attempt milestone rewards. Empty list when none configured.
  final List<MilestoneRewardPreview> milestoneRewards;

  /// Reward policy summary with inline bundle previews. `null` only
  /// for legacy responses that pre-date the rewards-preview feature
  /// — modern backends always set it (`{ type: 'none' }` at minimum).
  final RewardPolicySummary? rewardPolicy;

  const EventListing({
    required this.eventKey,
    required this.name,
    required this.windowId,
    required this.startsAt,
    required this.endsAt,
    required this.leaderboardId,
    required this.currentAttemptId,
    required this.type,
    required this.leaderboardMode,
    required this.metrics,
    required this.entryRequirement,
    required this.entryCost,
    required this.metadata,
    required this.milestoneRewards,
    required this.rewardPolicy,
  });

  /// True when [leaderboardMode] is `lobby_matched`. Convenience
  /// flag the UI uses to switch into a lobby-waiting view.
  bool get isLobbyMatched => leaderboardMode == 'lobby_matched';

  factory EventListing.fromJson(JsonMap json) => EventListing(
        eventKey: _readString(json, 'eventKey'),
        name: json['name'],
        windowId: _readString(json, 'windowId'),
        startsAt: _readString(json, 'startsAt'),
        endsAt: _readString(json, 'endsAt'),
        leaderboardId: _readNullableString(json, 'leaderboardId'),
        currentAttemptId: _readNullableString(json, 'currentAttemptId'),
        type: _readString(json, 'type').isEmpty ? 'single_metric' : _readString(json, 'type'),
        leaderboardMode:
            _readString(json, 'leaderboardMode').isEmpty ? 'global' : _readString(json, 'leaderboardMode'),
        metrics: ((json['metrics'] as List?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((e) => e.cast<String, Object?>())
            .toList(growable: false),
        entryRequirement: json['entryRequirement'] is Map
            ? (json['entryRequirement']! as Map).cast<String, Object?>()
            : null,
        entryCost: json['entryCost'] is Map
            ? EntryCost.fromJson((json['entryCost']! as Map).cast<String, Object?>())
            : null,
        metadata: _readObjectMap(json, 'metadata'),
        milestoneRewards: ((json['milestoneRewards'] as List?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((e) => MilestoneRewardPreview.fromJson(e.cast<String, Object?>()))
            .toList(growable: false),
        rewardPolicy: json['rewardPolicy'] is Map
            ? RewardPolicySummary.fromJson((json['rewardPolicy']! as Map).cast<String, Object?>())
            : null,
      );
}

/// One item row as exposed to game clients via the catalog endpoint.
/// Display-relevant fields only — internal config / archival
/// timestamps stay off the SDK wire format.
class CatalogItem {
  final String key;
  final Object? name;
  final String? iconUrl;
  final Object? description;
  final String itemTypeKey;
  final List<String> tags;
  final String? rarity;
  final Map<String, Object?> attributes;
  const CatalogItem({
    required this.key,
    required this.name,
    required this.iconUrl,
    required this.description,
    required this.itemTypeKey,
    required this.tags,
    required this.rarity,
    required this.attributes,
  });
  factory CatalogItem.fromJson(JsonMap json) => CatalogItem(
        key: _readString(json, 'key'),
        name: json['name'],
        iconUrl: _readNullableString(json, 'iconUrl'),
        description: json['description'],
        itemTypeKey: _readString(json, 'itemTypeKey'),
        tags: ((json['tags'] as List?) ?? const [])
            .whereType<String>()
            .toList(growable: false),
        rarity: _readNullableString(json, 'rarity'),
        attributes: _readObjectMap(json, 'attributes'),
      );
}

/// One currency row as exposed to game clients. [kind] distinguishes
/// spendable currencies (`'currency'`) from progression resources
/// (`'progression'`).
class CatalogCurrency {
  final String key;
  final Object? name;
  final String? iconUrl;
  final Object? description;
  final String kind;
  const CatalogCurrency({
    required this.key,
    required this.name,
    required this.iconUrl,
    required this.description,
    required this.kind,
  });
  factory CatalogCurrency.fromJson(JsonMap json) => CatalogCurrency(
        key: _readString(json, 'key'),
        name: json['name'],
        iconUrl: _readNullableString(json, 'iconUrl'),
        description: json['description'],
        kind: _readString(json, 'kind').isEmpty ? 'currency' : _readString(json, 'kind'),
      );
}

class Catalog {
  final List<CatalogItem> items;
  final List<CatalogCurrency> currencies;
  const Catalog({required this.items, required this.currencies});
  factory Catalog.fromJson(JsonMap json) => Catalog(
        items: ((json['items'] as List?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((e) => CatalogItem.fromJson(e.cast<String, Object?>()))
            .toList(growable: false),
        currencies: ((json['currencies'] as List?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((e) => CatalogCurrency.fromJson(e.cast<String, Object?>()))
            .toList(growable: false),
      );
}

class LeaderboardEntry {
  final String participantId;

  /// One of `player`, `bot`.
  final String kind;
  final String? name;
  final String? avatarUrl;
  final double score;
  final int rank;

  /// `true` when this entry is the player calling the API (resolved from
  /// the `externalId` passed via `includeSelf`). Highlight rows off this
  /// rather than matching `participantId` to the external id yourself —
  /// the server surfaces the internal player UUID, not the external one.
  /// Always `false` on entries without a self-context request, and on
  /// bot entries regardless.
  final bool isSelf;

  const LeaderboardEntry({
    required this.participantId,
    required this.kind,
    required this.name,
    required this.avatarUrl,
    required this.score,
    required this.rank,
    required this.isSelf,
  });

  factory LeaderboardEntry.fromJson(JsonMap json) => LeaderboardEntry(
        participantId: _readString(json, 'participantId'),
        kind: _readString(json, 'kind'),
        name: _readNullableString(json, 'name'),
        avatarUrl: _readNullableString(json, 'avatarUrl'),
        score: _readDouble(json, 'score'),
        rank: _readInt(json, 'rank'),
        // `isSelf` was added in v0.X — server defaults missing fields to
        // false anyway, and a missing key here would throw, so default
        // to `false` when absent to keep older payloads parseable.
        isSelf: json['isSelf'] is bool ? json['isSelf'] as bool : false,
      );
}

class LeaderboardSelf {
  final int rank;
  final double score;

  const LeaderboardSelf({required this.rank, required this.score});

  factory LeaderboardSelf.fromJson(JsonMap json) => LeaderboardSelf(
        rank: _readInt(json, 'rank'),
        score: _readDouble(json, 'score'),
      );
}

/// The auto-generated per-event-window leaderboard, addressed by the
/// UUID returned in `events.start(...)`'s `attempt.leaderboardId`. For
/// the dashboard-configured cross-event boards, see [Leaderboard].
class EventLeaderboard {
  final String leaderboardId;
  final String mode;
  final bool finalized;
  final List<LeaderboardEntry> entries;
  final LeaderboardSelf? self;

  const EventLeaderboard({
    required this.leaderboardId,
    required this.mode,
    required this.finalized,
    required this.entries,
    required this.self,
  });

  factory EventLeaderboard.fromJson(JsonMap json) => EventLeaderboard(
        leaderboardId: _readString(json, 'leaderboardId'),
        mode: _readString(json, 'mode'),
        finalized: _readBool(json, 'finalized'),
        entries: (json['entries'] as List? ?? const [])
            .map((e) => LeaderboardEntry.fromJson(e as JsonMap))
            .toList(),
        self: json['self'] is Map
            ? LeaderboardSelf.fromJson(json['self']! as JsonMap)
            : null,
      );
}

/// The dashboard-configured cross-event leaderboard, addressed by its
/// game-scoped `key` (e.g. `"weekly_global"`). The primary surface for
/// most game UI. For the auto-created per-event-window boards, see
/// [EventLeaderboard].
class Leaderboard {
  /// The board's stable game-scoped key.
  final String key;

  /// UUID of the leaderboard config row.
  final String sharedLeaderboardId;

  final String? scope;
  final String? resetCadence;
  final String? scoreAggregation;

  /// Resolved segment bucket for segmented boards; `null` on unsegmented.
  final String? segment;

  /// ISO timestamp of the period this snapshot is from.
  final String period;

  final List<LeaderboardEntry> entries;
  final LeaderboardSelf? self;

  const Leaderboard({
    required this.key,
    required this.sharedLeaderboardId,
    required this.scope,
    required this.resetCadence,
    required this.scoreAggregation,
    required this.segment,
    required this.period,
    required this.entries,
    required this.self,
  });

  factory Leaderboard.fromJson(JsonMap json) => Leaderboard(
        key: _readString(json, 'key'),
        sharedLeaderboardId: _readString(json, 'sharedLeaderboardId'),
        scope: _readNullableString(json, 'scope'),
        resetCadence: _readNullableString(json, 'resetCadence'),
        scoreAggregation: _readNullableString(json, 'scoreAggregation'),
        segment: _readNullableString(json, 'segment'),
        period: _readString(json, 'period'),
        entries: (json['entries'] as List? ?? const [])
            .map((e) => LeaderboardEntry.fromJson(e as JsonMap))
            .toList(),
        self: json['self'] is Map
            ? LeaderboardSelf.fromJson(json['self']! as JsonMap)
            : null,
      );
}

class LeaderboardPeriod {
  final String periodStartedAt;
  final String periodEndedAt;

  const LeaderboardPeriod({
    required this.periodStartedAt,
    required this.periodEndedAt,
  });

  factory LeaderboardPeriod.fromJson(JsonMap json) => LeaderboardPeriod(
        periodStartedAt: _readString(json, 'periodStartedAt'),
        periodEndedAt: _readString(json, 'periodEndedAt'),
      );
}

class LeaderboardPeriods {
  final String key;
  final String sharedLeaderboardId;
  final String currentPeriodStartedAt;
  final List<LeaderboardPeriod> periods;

  const LeaderboardPeriods({
    required this.key,
    required this.sharedLeaderboardId,
    required this.currentPeriodStartedAt,
    required this.periods,
  });

  factory LeaderboardPeriods.fromJson(JsonMap json) => LeaderboardPeriods(
        key: _readString(json, 'key'),
        sharedLeaderboardId: _readString(json, 'sharedLeaderboardId'),
        currentPeriodStartedAt: _readString(json, 'currentPeriodStartedAt'),
        periods: (json['periods'] as List? ?? const [])
            .map((e) => LeaderboardPeriod.fromJson(e as JsonMap))
            .toList(),
      );
}

class Grant {
  final String id;

  /// One of `reward`, `crate`.
  final String kind;
  final Map<String, Object?> contents;
  final String sourceKind;
  final String? sourceRefId;
  final String? parentGrantId;

  /// One of `pending`, `claimed`, `expired`.
  final String status;
  final String? rolledAt;
  final String? claimedAt;
  final String? expiresAt;
  final String createdAt;

  const Grant({
    required this.id,
    required this.kind,
    required this.contents,
    required this.sourceKind,
    required this.sourceRefId,
    required this.parentGrantId,
    required this.status,
    required this.rolledAt,
    required this.claimedAt,
    required this.expiresAt,
    required this.createdAt,
  });

  factory Grant.fromJson(JsonMap json) => Grant(
        id: _readString(json, 'id'),
        kind: _readString(json, 'kind'),
        contents: _readObjectMap(json, 'contents'),
        sourceKind: _readString(json, 'sourceKind'),
        sourceRefId: _readNullableString(json, 'sourceRefId'),
        parentGrantId: _readNullableString(json, 'parentGrantId'),
        status: _readString(json, 'status'),
        rolledAt: _readNullableString(json, 'rolledAt'),
        claimedAt: _readNullableString(json, 'claimedAt'),
        expiresAt: _readNullableString(json, 'expiresAt'),
        createdAt: _readString(json, 'createdAt'),
      );
}

class OpenCrateResponse {
  final Grant crate;
  final Grant contents;

  const OpenCrateResponse({required this.crate, required this.contents});

  factory OpenCrateResponse.fromJson(JsonMap json) => OpenCrateResponse(
        crate: Grant.fromJson(json['crate'] as JsonMap),
        contents: Grant.fromJson(json['contents'] as JsonMap),
      );
}

/// One milestone that fired during a single `progress()` call. The
/// designer-defined [key] identifies which threshold tripped — surface
/// it in a toast or trigger a celebration animation. [grants] carries
/// the concrete rewards (same shape `/grants/pending` returns).
class MilestoneFired {
  final String key;
  final List<Grant> grants;

  const MilestoneFired({required this.key, required this.grants});

  factory MilestoneFired.fromJson(JsonMap json) => MilestoneFired(
        key: _readString(json, 'key'),
        grants: ((json['grants'] as List<Object?>?) ?? const [])
            .map((g) => Grant.fromJson(g as JsonMap))
            .toList(growable: false),
      );
}

/// Response from `EventsClient.progress`. Always includes
/// [milestonesFired] (empty list when nothing fired) so callers can
/// iterate without a null check.
class ProgressResponse {
  final Attempt attempt;
  final List<MilestoneFired> milestonesFired;

  const ProgressResponse({
    required this.attempt,
    required this.milestonesFired,
  });

  factory ProgressResponse.fromJson(JsonMap json) => ProgressResponse(
        attempt: Attempt.fromJson(json['attempt'] as JsonMap),
        milestonesFired: ((json['milestonesFired'] as List<Object?>?) ?? const [])
            .map((m) => MilestoneFired.fromJson(m as JsonMap))
            .toList(growable: false),
      );
}

class Lobby {
  final String id;
  final String eventId;
  final String eventWindowId;
  final String? leaderboardId;
  final String mode;

  /// One of `forming`, `active`, `closed`.
  final String status;
  final int capacity;
  final String? fillBy;
  final int participantCount;

  /// Projected bot count at read time — derived server-side from
  /// the lobby's age and the matchmaking drip interval. Grows
  /// monotonically while the lobby is `forming`. UI typically
  /// renders `participantCount + botSlots` filled cells out of
  /// `capacity` for a smooth fill animation.
  final int botSlots;

  final String? startedAt;
  final String? endsAt;

  const Lobby({
    required this.id,
    required this.eventId,
    required this.eventWindowId,
    required this.leaderboardId,
    required this.mode,
    required this.status,
    required this.capacity,
    required this.fillBy,
    required this.participantCount,
    required this.botSlots,
    required this.startedAt,
    required this.endsAt,
  });

  /// Total filled cells (humans + projected bots). Cap at capacity in
  /// case server + client clocks ever disagree mid-drip.
  int get filledSlots {
    final total = participantCount + botSlots;
    return total > capacity ? capacity : total;
  }

  factory Lobby.fromJson(JsonMap json) => Lobby(
        id: _readString(json, 'id'),
        eventId: _readString(json, 'eventId'),
        eventWindowId: _readString(json, 'eventWindowId'),
        leaderboardId: _readNullableString(json, 'leaderboardId'),
        mode: _readString(json, 'mode'),
        status: _readString(json, 'status'),
        capacity: _readInt(json, 'capacity'),
        fillBy: _readNullableString(json, 'fillBy'),
        participantCount: _readInt(json, 'participantCount'),
        botSlots: _readInt(json, 'botSlots'),
        startedAt: _readNullableString(json, 'startedAt'),
        endsAt: _readNullableString(json, 'endsAt'),
      );
}

/// Input for `EventsClient.progress`. Supply either [metricValue]
/// (single-metric events) or [metrics] (multi-metric).
/// [idempotencyKey] is auto-generated by the client if you leave it
/// null.
class ProgressInput {
  /// `set` writes the value as the new metric; `increment` adds.
  final String mode;
  final double? metricValue;
  final Map<String, double>? metrics;
  final String? occurredAt;
  final String? idempotencyKey;

  const ProgressInput({
    this.mode = 'set',
    this.metricValue,
    this.metrics,
    this.occurredAt,
    this.idempotencyKey,
  });

  JsonMap toJson() => <String, Object?>{
        'mode': mode,
        if (metricValue != null) 'metricValue': metricValue,
        if (metrics != null) 'metrics': metrics,
        if (occurredAt != null) 'occurredAt': occurredAt,
        if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
      };
}

/// One row in the player's platform-managed inventory. Returned by
/// `GET /sdk/v1/players/:externalId/inventory`. The item's display
/// name and other catalog metadata live on the `items` table — the
/// SDK only carries the per-player quantity + free-form metadata
/// stamped on deposits (e.g. a granted potion's roll details).
class PlayerItemHolding {
  final String itemKey;
  final int quantity;
  final Map<String, Object?> metadata;
  final String createdAt;
  final String updatedAt;

  const PlayerItemHolding({
    required this.itemKey,
    required this.quantity,
    required this.metadata,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PlayerItemHolding.fromJson(JsonMap json) => PlayerItemHolding(
        itemKey: _readString(json, 'itemKey'),
        quantity: _readInt(json, 'quantity'),
        metadata: _readObjectMap(json, 'metadata'),
        createdAt: _readString(json, 'createdAt'),
        updatedAt: _readString(json, 'updatedAt'),
      );
}

/// One row in the player's wallet. Wallets are kind-agnostic: a
/// `gold` currency entry sits beside a `trophies` progression entry
/// with the same shape. The owning currency's `kind` lives on the
/// catalog row, not here.
class PlayerWalletHolding {
  final String economyKey;
  final int balance;
  final Map<String, Object?> metadata;
  final String createdAt;
  final String updatedAt;

  const PlayerWalletHolding({
    required this.economyKey,
    required this.balance,
    required this.metadata,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PlayerWalletHolding.fromJson(JsonMap json) => PlayerWalletHolding(
        economyKey: _readString(json, 'economyKey'),
        balance: _readInt(json, 'balance'),
        metadata: _readObjectMap(json, 'metadata'),
        createdAt: _readString(json, 'createdAt'),
        updatedAt: _readString(json, 'updatedAt'),
      );
}

/// Input for `InventoryClient.consume`. The server requires
/// [idempotencyKey] for consume — the SDK auto-generates one if you
/// leave it null, matching the auto-stamping behavior on every other
/// POST endpoint.
class ConsumeItemInput {
  /// Positive integer — the SDK does NOT enforce; the server
  /// validates and returns 400 on zero/negative.
  final int quantity;

  /// Free-form tag persisted on the ledger row only. Surfaces in the
  /// admin audit screen.
  final String? reason;

  /// Optional override — leave null to let the client auto-stamp one.
  final String? idempotencyKey;

  const ConsumeItemInput({
    required this.quantity,
    this.reason,
    this.idempotencyKey,
  });

  JsonMap toJson() => <String, Object?>{
        'quantity': quantity,
        if (reason != null) 'reason': reason,
        if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
      };
}

/// Result of `InventoryClient.consume`. [applied] distinguishes a
/// fresh mutation from an idempotent replay (the server returns the
/// prior state when the same key arrives twice).
class ConsumeItemResult {
  final String itemKey;
  final int quantity;
  final bool applied;

  const ConsumeItemResult({
    required this.itemKey,
    required this.quantity,
    required this.applied,
  });

  factory ConsumeItemResult.fromJson(JsonMap json) => ConsumeItemResult(
        itemKey: _readString(json, 'itemKey'),
        quantity: _readInt(json, 'quantity'),
        applied: _readBool(json, 'applied'),
      );
}

/// Input for `WalletClient.debit`. Same idempotency story as
/// [ConsumeItemInput]. Credits are intentionally NOT in the SDK —
/// only the studio's backend (`/server/v1/...`) can mint balance, so
/// a client SDK that exposed `credit` would invite money printing.
class DebitWalletInput {
  final int amount;
  final String? reason;
  final String? idempotencyKey;

  const DebitWalletInput({
    required this.amount,
    this.reason,
    this.idempotencyKey,
  });

  JsonMap toJson() => <String, Object?>{
        'amount': amount,
        if (reason != null) 'reason': reason,
        if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
      };
}

class DebitWalletResult {
  final String economyKey;
  final int balance;
  final bool applied;

  const DebitWalletResult({
    required this.economyKey,
    required this.balance,
    required this.applied,
  });

  factory DebitWalletResult.fromJson(JsonMap json) => DebitWalletResult(
        economyKey: _readString(json, 'economyKey'),
        balance: _readInt(json, 'balance'),
        applied: _readBool(json, 'applied'),
      );
}

/// Result of `players.register()`. The plaintext [secret] is only
/// ever surfaced HERE — store it locally on the device immediately
/// (e.g. shared_preferences in Flutter). The next call to
/// `register()` for the same player returns 409
/// `player_already_registered`; lost-secret recovery is a studio-
/// side admin flow, not a client capability.
class PlayerRegistration {
  final String playerId;
  final String externalPlayerId;
  final String secret;
  final String? secretPrefix;
  final String? registeredAt;

  const PlayerRegistration({
    required this.playerId,
    required this.externalPlayerId,
    required this.secret,
    required this.secretPrefix,
    required this.registeredAt,
  });

  factory PlayerRegistration.fromJson(JsonMap json) => PlayerRegistration(
        playerId: _readString(json, 'playerId'),
        externalPlayerId: _readString(json, 'externalPlayerId'),
        secret: _readString(json, 'secret'),
        secretPrefix: _readNullableString(json, 'secretPrefix'),
        registeredAt: _readNullableString(json, 'registeredAt'),
      );
}

/// Per-call options for `LeaderboardsClient.read`.
class LeaderboardReadOptions {
  /// 1–200, default 50 server-side.
  final int? limit;

  /// Bucket value for segmented boards. Required when the board has
  /// `segmentation.key` set.
  final String? segment;

  /// `"current"` (default) reads the live ranks. An ISO timestamp from
  /// `listPeriods(...)` reads the historical snapshot.
  final String? period;

  /// When true, response includes `self: { rank, score }` (live only).
  final bool includeSelf;

  /// Required when [includeSelf] is true.
  final String? externalId;

  const LeaderboardReadOptions({
    this.limit,
    this.segment,
    this.period,
    this.includeSelf = false,
    this.externalId,
  });
}

/// Per-call options for `EventLeaderboardsClient.read`.
class EventLeaderboardReadOptions {
  /// 1–200, default 50 server-side.
  final int? limit;

  /// When true, response includes `self: { rank, score }`.
  final bool includeSelf;

  /// Required when [includeSelf] is true.
  final String? externalId;

  const EventLeaderboardReadOptions({
    this.limit,
    this.includeSelf = false,
    this.externalId,
  });
}
