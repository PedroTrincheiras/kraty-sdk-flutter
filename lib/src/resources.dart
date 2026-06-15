import 'dart:async';

import 'client.dart';
import 'leaderboard_stream.dart';
import 'types.dart';

/// Helper: unwrap the `{ "data": T }` envelope every SDK endpoint
/// returns.
T _data<T>(Map<String, Object?> envelope, T Function(Object?) decode) {
  return decode(envelope['data']);
}

String _enc(String s) => Uri.encodeComponent(s);

/// Player-scoped resource methods accept an optional [as] override
/// instead of requiring the caller to pass an externalPlayerId on
/// every call. We resolve it from (1) the explicit [as] value, or
/// (2) `client.ensureIdentity()` — which lazily mints + persists a
/// player on the very first call when no identity is configured.
Future<String> _resolvePlayerId(KratyClient client, String? as) async {
  if (as != null && as.isNotEmpty) return as;
  final identity = await client.ensureIdentity();
  return identity.externalPlayerId;
}

/// Resource client for the `/sdk/v1/players/.../events/...` surface:
/// list, start, progress.
class EventsClient {
  final KratyClient _client;

  EventsClient(this._client);

  /// `GET /sdk/v1/players/:externalId/events` — events whose current
  /// window the active player can start now. Pass `as:` to address a
  /// different player (server-side tooling only).
  Future<List<EventListing>> listForPlayer({String? as}) async {
    final externalPlayerId = await _resolvePlayerId(_client, as);
    final env = await _client.request(
      method: 'GET',
      path: '/sdk/v1/players/${_enc(externalPlayerId)}/events',
    );
    return _data<List<EventListing>>(env, (raw) {
      if (raw is List) {
        return raw
            .whereType<Map<String, Object?>>()
            .map((e) =>EventListing.fromJson(e.cast<String, Object?>()))
            .toList();
      }
      return <EventListing>[];
    });
  }

  /// `POST /sdk/v1/players/:p/events/:e/start` — start an attempt for
  /// the active player.
  ///
  /// If the event uses matchmaking and the lobby is still forming,
  /// the server returns 202 with `error.code = 'lobby_forming'` —
  /// the SDK surfaces this as a `KratyApiError`. Consumers should
  /// poll the lobby endpoint and retry.
  Future<StartAttemptResponse> start(
    String eventKey, {
    Map<String, Object?>? playerContext,
    String? as,
  }) async {
    final externalPlayerId = await _resolvePlayerId(_client, as);
    final env = await _client.request(
      method: 'POST',
      path:
          '/sdk/v1/players/${_enc(externalPlayerId)}/events/${_enc(eventKey)}/start',
      body: <String, Object?>{
        if (playerContext != null) 'playerContext': playerContext,
      },
    );
    return _data<StartAttemptResponse>(env, (raw) {
      if (raw is Map) return StartAttemptResponse.fromJson(raw.cast<String, Object?>());
      return StartAttemptResponse(
        attempt: Attempt.fromJson(const <String, Object?>{}),
        leaderboardId: '',
        windowEndsAt: '',
      );
    });
  }

  /// `POST /sdk/v1/players/:p/events/:e/attempts/:a/progress` —
  /// push a metric update for the active player. Returns the updated
  /// attempt plus any milestones whose threshold was crossed by THIS
  /// update (empty list when nothing fired).
  Future<ProgressResponse> progress(
    String eventKey,
    String attemptId,
    ProgressInput input, {
    String? as,
  }) async {
    final externalPlayerId = await _resolvePlayerId(_client, as);
    final env = await _client.request(
      method: 'POST',
      path:
          '/sdk/v1/players/${_enc(externalPlayerId)}/events/${_enc(eventKey)}/attempts/${_enc(attemptId)}/progress',
      body: input.toJson(),
    );
    return _data<ProgressResponse>(env, (raw) {
      if (raw is Map) {
        return ProgressResponse.fromJson(raw.cast<String, Object?>());
      }
      return ProgressResponse.fromJson(<String, Object?>{
        'attempt': <String, Object?>{},
        'milestonesFired': <Object?>[],
      });
    });
  }
}

/// Resource client for `/sdk/v1/leaderboards/:id`.
class LeaderboardsClient {
  final KratyClient _client;

  LeaderboardsClient(this._client);

  Future<Leaderboard> read(
    String leaderboardId, {
    LeaderboardReadOptions? options,
  }) async {
    final opts = options ?? const LeaderboardReadOptions();
    final qs = <String>[];
    if (opts.limit != null) qs.add('limit=${opts.limit}');
    if (opts.includeSelf) {
      final selfId = (opts.externalId != null && opts.externalId!.isNotEmpty)
          ? opts.externalId!
          : await _resolvePlayerId(_client, null);
      qs.add('includeSelf=true');
      qs.add('externalId=${_enc(selfId)}');
    }
    final path = qs.isEmpty
        ? '/sdk/v1/leaderboards/${_enc(leaderboardId)}'
        : '/sdk/v1/leaderboards/${_enc(leaderboardId)}?${qs.join('&')}';
    final env = await _client.request(method: 'GET', path: path);
    return _data<Leaderboard>(env, (raw) {
      if (raw is Map) return Leaderboard.fromJson(raw.cast<String, Object?>());
      return Leaderboard.fromJson(const <String, Object?>{});
    });
  }

  /// `GET /sdk/v1/leaderboards/:id/stream` — opens a Server-Sent
  /// Events subscription that pushes score updates in real time.
  /// Returns a [LeaderboardStream] handle the caller drives via
  /// its `events` stream + `cancel()` method.
  ///
  /// Event kinds the server emits today:
  ///   - `ready` — handshake, sent once after the pub/sub
  ///     subscription is wired. Safe to start POSTing progress as
  ///     soon as this lands without missing the resulting update.
  ///   - `score_update` — a participant's score changed; payload
  ///     carries the new rank/score for the affected entry.
  ///   - `closed` — server is finalizing or closing. After this,
  ///     the stream completes and `cancel()` is a no-op.
  ///
  /// Does NOT auto-reconnect on transport drop — surface errors via
  /// the returned stream's `errors` and re-call `live()` after a
  /// backoff if you want resumption.
  ///
  /// Low-level — prefer [subscribe] for game UIs; it polls in the
  /// background so bot scores tick even when no player action would
  /// otherwise trigger a server-side read.
  Future<LeaderboardStream> live(String leaderboardId) {
    return openLeaderboardStream(
      baseUrl: _client.baseUrlForStreaming,
      leaderboardId: leaderboardId,
      authHeader: _client.authHeaderForStreaming,
      httpClient: _client.httpForStreaming,
      playerSecret: _client.playerSecretForStreaming,
      sdkUserAgent: _client.sdkUserAgentForStreaming,
    );
  }

  /// High-level live leaderboard subscription. Composes:
  ///
  /// 1. the SSE stream from [live] (real-time push for score updates
  ///    the server has published), AND
  /// 2. a periodic background [read] poll that nudges the server's
  ///    lazy bot evaluator to advance bot scores, then dedupes the
  ///    resulting deltas against the SSE feed.
  ///
  /// Why both: bot scores climb on a schedule (per the event's bot
  /// definitions) even when no player action would otherwise trigger
  /// a server-side read. Without the background poll, idle UIs never
  /// see bots tick. The SSE stream then carries the resulting
  /// `score_update` events so multiple subscribers per leaderboard
  /// share one fan-out.
  ///
  /// The returned [LiveLeaderboardSubscription] exposes a single
  /// `events` stream that interleaves SSE pushes + poll-derived
  /// updates, deduped so the same `(participantId, score)` doesn't
  /// surface twice. Call `cancel()` to tear down both transports.
  ///
  /// Defaults: `pollInterval: const Duration(seconds: 15)`. Set
  /// `pollInterval: Duration.zero` to disable polling (SSE-only).
  LiveLeaderboardSubscription subscribe(
    String leaderboardId, {
    Duration pollInterval = const Duration(seconds: 15),
  }) {
    final eventsCtrl = StreamController<LeaderboardStreamEvent>.broadcast();
    final errorsCtrl = StreamController<Object>.broadcast();
    final lastSurfacedScore = <String, double>{};
    var closed = false;
    LeaderboardStream? sseHandle;
    Timer? pollTimer;
    StreamSubscription<LeaderboardStreamEvent>? sseEventSub;
    StreamSubscription<Object>? sseErrorSub;

    void surface(LeaderboardStreamEvent ev) {
      if (closed) return;
      // Dedup score_update by (participantId, score). Other kinds
      // (ready, closed, parse-error) always pass through.
      if (ev.kind == 'score_update') {
        final pid = ev.data['participantId'];
        final score = ev.data['score'];
        if (pid is String && score is num) {
          final s = score.toDouble();
          if (lastSurfacedScore[pid] == s) return;
          lastSurfacedScore[pid] = s;
        }
      }
      eventsCtrl.add(ev);
    }

    Future<void> pollOnce() async {
      if (closed) return;
      try {
        final lb = await read(leaderboardId);
        for (final entry in lb.entries) {
          surface(LeaderboardStreamEvent(kind: 'score_update', data: <String, Object?>{
            'leaderboardId': lb.leaderboardId,
            'participantId': entry.participantId,
            'score': entry.score,
            'rank': entry.rank,
          }));
        }
      } catch (err) {
        if (!closed) errorsCtrl.add(err);
      }
    }

    // Wire SSE in the background — surface failures on the errors
    // stream but don't kill the poll loop if SSE drops.
    Future<void>(() async {
      try {
        sseHandle = await live(leaderboardId);
      } catch (err) {
        if (!closed) errorsCtrl.add(err);
        return;
      }
      sseEventSub = sseHandle!.events.listen(surface);
      sseErrorSub = sseHandle!.errors.listen((err) {
        if (!closed) errorsCtrl.add(err);
      });
    });

    // Kick off the poll loop. First read fires immediately so the
    // initial UI frame has current scores instead of waiting a full
    // interval. Repeat with Timer.periodic afterwards.
    if (pollInterval > Duration.zero) {
      Future<void>(() async {
        await pollOnce();
        if (!closed) {
          pollTimer = Timer.periodic(pollInterval, (_) => pollOnce());
        }
      });
    }

    return LiveLeaderboardSubscription._(
      eventsCtrl.stream,
      errorsCtrl.stream,
      () async {
        if (closed) return;
        closed = true;
        pollTimer?.cancel();
        await sseEventSub?.cancel();
        await sseErrorSub?.cancel();
        if (sseHandle != null) {
          try { await sseHandle!.cancel(); } catch (_) { /* swallow */ }
        }
        await eventsCtrl.close();
        await errorsCtrl.close();
      },
    );
  }
}

/// Handle to a combined live + poll subscription from
/// [LeaderboardsClient.subscribe]. Single `events` stream that
/// interleaves SSE pushes and poll-derived deltas, plus an `errors`
/// stream for transport failures. Call [cancel] to tear down both
/// transports.
class LiveLeaderboardSubscription {
  /// Merged event stream — yields `score_update` (deduped per
  /// participant) plus any other SSE event kinds (`ready`, `closed`,
  /// `parse-error`). Broadcast-style; safe for multiple listeners.
  final Stream<LeaderboardStreamEvent> events;

  /// Transport / poll failures. Non-fatal — the subscription keeps
  /// running. SSE drops don't stop the background poll, and vice
  /// versa.
  final Stream<Object> errors;

  final Future<void> Function() _cancel;

  const LiveLeaderboardSubscription._(this.events, this.errors, this._cancel);

  /// Cancels the SSE stream and the background poll. Idempotent.
  Future<void> cancel() => _cancel();
}

/// Resource client for `/sdk/v1/players/:p/{pending-grants,grants,crates}`.
class GrantsClient {
  final KratyClient _client;

  GrantsClient(this._client);

  /// Pending grants for the active player. Empty list for unknown
  /// players (not a 404). Pass `as:` to query another player
  /// (server-side tooling only).
  Future<List<Grant>> listPending({int? limit, String? as}) async {
    final externalPlayerId = await _resolvePlayerId(_client, as);
    final qs = limit != null ? '?limit=$limit' : '';
    final env = await _client.request(
      method: 'GET',
      path: '/sdk/v1/players/${_enc(externalPlayerId)}/pending-grants$qs',
    );
    return _data<List<Grant>>(env, (raw) {
      if (raw is List) {
        return raw
            .whereType<Map<String, Object?>>()
            .map((e) =>Grant.fromJson(e.cast<String, Object?>()))
            .toList();
      }
      return <Grant>[];
    });
  }

  /// Flip a pending grant to claimed for the active player.
  /// Idempotent — claiming an already-claimed grant returns the same
  /// row.
  Future<Grant> claim(String grantId, {String? as}) async {
    final externalPlayerId = await _resolvePlayerId(_client, as);
    final env = await _client.request(
      method: 'POST',
      path:
          '/sdk/v1/players/${_enc(externalPlayerId)}/grants/${_enc(grantId)}/claim',
      body: const <String, Object?>{},
    );
    return _data<Grant>(env, (raw) {
      if (raw is Map) return Grant.fromJson(raw.cast<String, Object?>());
      return Grant.fromJson(const <String, Object?>{});
    });
  }

  /// Roll a crate for the active player. Idempotent on the crate id
  /// — replays return the previously-rolled contents grant.
  Future<OpenCrateResponse> open(String grantId, {String? as}) async {
    final externalPlayerId = await _resolvePlayerId(_client, as);
    final env = await _client.request(
      method: 'POST',
      path:
          '/sdk/v1/players/${_enc(externalPlayerId)}/crates/${_enc(grantId)}/open',
      body: const <String, Object?>{},
    );
    return _data<OpenCrateResponse>(env, (raw) {
      if (raw is Map) return OpenCrateResponse.fromJson(raw.cast<String, Object?>());
      return OpenCrateResponse(
        crate: Grant.fromJson(const <String, Object?>{}),
        contents: Grant.fromJson(const <String, Object?>{}),
      );
    });
  }

  /// Burn down the pending-grants queue in one call for the active
  /// player: list everything pending, open every crate, claim every
  /// reward, return a summary. Built for the "round complete"
  /// reward-collection moment most games have.
  ///
  /// Errors per-grant are caught and surfaced in
  /// [CollectAllResult.failures] — one bad grant doesn't abort the
  /// whole sweep.
  Future<CollectAllResult> collectAll({String? as}) async {
    final pending = await listPending(as: as);
    final opened = <OpenCrateResponse>[];
    final claimed = <Grant>[];
    final failures = <CollectAllFailure>[];
    for (final g in pending) {
      try {
        if (g.kind == 'crate') {
          opened.add(await open(g.id, as: as));
        } else {
          claimed.add(await claim(g.id, as: as));
        }
      } catch (err) {
        failures.add(CollectAllFailure(grant: g, error: err));
      }
    }
    return CollectAllResult(
      processed: pending.length,
      opened: opened,
      claimed: claimed,
      failures: failures,
    );
  }
}

/// One pending grant that `collectAll` couldn't process. The other
/// grants in the same sweep still went through — inspect [error]
/// and retry the individual operation.
class CollectAllFailure {
  final Grant grant;
  final Object error;
  const CollectAllFailure({required this.grant, required this.error});
}

/// Aggregate result of [GrantsClient.collectAll]. [processed] is the
/// total pending count at the time of the call; [opened] + [claimed]
/// + [failures] sum to that.
class CollectAllResult {
  final int processed;
  final List<OpenCrateResponse> opened;
  final List<Grant> claimed;
  final List<CollectAllFailure> failures;
  const CollectAllResult({
    required this.processed,
    required this.opened,
    required this.claimed,
    required this.failures,
  });

  bool get hasFailures => failures.isNotEmpty;
}

/// Resource client for `/sdk/v1/players/:p/inventory(/...)`. Only
/// surfaces meaningful data for games whose `settings.inventoryManagement`
/// is `'platform'` — under studio-managed mode the lists come back
/// empty (the studio's own backend holds the canonical state). The
/// SDK doesn't expose grant or admin-credit endpoints; those are
/// server-API only.
class InventoryClient {
  final KratyClient _client;

  InventoryClient(this._client);

  /// `GET /sdk/v1/players/:p/inventory` — every item the player
  /// currently holds (quantity > 0). Newest-first ordering is not
  /// guaranteed; sort client-side if you need it.
  Future<List<PlayerItemHolding>> list({String? as}) async {
    final externalPlayerId = await _resolvePlayerId(_client, as);
    final env = await _client.request(
      method: 'GET',
      path: '/sdk/v1/players/${_enc(externalPlayerId)}/inventory',
    );
    return _data<List<PlayerItemHolding>>(env, (raw) {
      if (raw is Map) {
        final items = raw['items'];
        if (items is List) {
          return items
              .whereType<Map<String, Object?>>()
              .map((e) => PlayerItemHolding.fromJson(e.cast<String, Object?>()))
              .toList(growable: false);
        }
      }
      return const <PlayerItemHolding>[];
    });
  }

  /// `POST /sdk/v1/players/:p/inventory/:itemKey/consume` — atomic
  /// decrement on the active player's inventory. Auto-stamped
  /// idempotency key unless you provide one. Returns 409 (surfaced
  /// as [KratyApiError] with code `conflict`) if the player doesn't
  /// have enough of the item.
  Future<ConsumeItemResult> consume(
    String itemKey,
    ConsumeItemInput input, {
    String? as,
  }) async {
    final externalPlayerId = await _resolvePlayerId(_client, as);
    final env = await _client.request(
      method: 'POST',
      path:
          '/sdk/v1/players/${_enc(externalPlayerId)}/inventory/${_enc(itemKey)}/consume',
      body: input.toJson(),
    );
    return _data<ConsumeItemResult>(env, (raw) {
      if (raw is Map) {
        return ConsumeItemResult.fromJson(raw.cast<String, Object?>());
      }
      return ConsumeItemResult.fromJson(const <String, Object?>{});
    });
  }
}

/// Resource client for `/sdk/v1/players/:p/wallet(/...)`. Mirrors
/// [InventoryClient] for currencies + progression resources.
class WalletClient {
  final KratyClient _client;

  WalletClient(this._client);

  /// `GET /sdk/v1/players/:p/wallet` — every economy entry the
  /// player has touched. Returns zero-balance rows alongside
  /// positive ones, so a wallet that's been emptied still surfaces.
  /// Filter client-side if you only want live balances.
  Future<List<PlayerWalletHolding>> list({String? as}) async {
    final externalPlayerId = await _resolvePlayerId(_client, as);
    final env = await _client.request(
      method: 'GET',
      path: '/sdk/v1/players/${_enc(externalPlayerId)}/wallet',
    );
    return _data<List<PlayerWalletHolding>>(env, (raw) {
      if (raw is Map) {
        final wallet = raw['wallet'];
        if (wallet is List) {
          return wallet
              .whereType<Map<String, Object?>>()
              .map((e) => PlayerWalletHolding.fromJson(e.cast<String, Object?>()))
              .toList(growable: false);
        }
      }
      return const <PlayerWalletHolding>[];
    });
  }

  /// `POST /sdk/v1/players/:p/wallet/:economyKey/debit` — atomic
  /// decrement on the active player's wallet. 409 on insufficient
  /// balance. Credit is intentionally not exposed here — see
  /// [DebitWalletInput] docs.
  Future<DebitWalletResult> debit(
    String economyKey,
    DebitWalletInput input, {
    String? as,
  }) async {
    final externalPlayerId = await _resolvePlayerId(_client, as);
    final env = await _client.request(
      method: 'POST',
      path:
          '/sdk/v1/players/${_enc(externalPlayerId)}/wallet/${_enc(economyKey)}/debit',
      body: input.toJson(),
    );
    return _data<DebitWalletResult>(env, (raw) {
      if (raw is Map) {
        return DebitWalletResult.fromJson(raw.cast<String, Object?>());
      }
      return DebitWalletResult.fromJson(const <String, Object?>{});
    });
  }
}

/// Resource client for `/sdk/v1/players/:p/register` — the zero-
/// trust bootstrap. Game client calls `register()` once on first
/// launch (or after the player wipes app data), captures the
/// returned [PlayerRegistration.secret], persists it locally, and
/// re-creates the [KratyClient] with `playerSecret: <secret>` so
/// every subsequent player-scoped call carries the `X-Player-Secret`
/// header. Without it those calls return 401 `player_secret_invalid`.
class PlayersClient {
  final KratyClient _client;

  PlayersClient(this._client);

  /// `POST /sdk/v1/players/:externalId/register` — creates the
  /// player row if it doesn't exist + mints a per-player secret.
  /// Returns 409 `player_already_registered` if the player has
  /// already claimed a secret (lost-secret recovery is an admin
  /// flow on the studio side, not a client capability).
  ///
  /// Pass [force]=true to ROTATE an existing secret. Only honoured
  /// by non-`live` API keys (i.e. dev/test/staging). Useful in the
  /// "I wiped my app data and need to re-register" flow during
  /// testing — never wire this up in a production client.
  Future<PlayerRegistration> register(
    String externalPlayerId, {
    bool force = false,
  }) async {
    final qs = force ? '?force=true' : '';
    final env = await _client.request(
      method: 'POST',
      path: '/sdk/v1/players/${_enc(externalPlayerId)}/register$qs',
      body: const <String, Object?>{},
    );
    return _data<PlayerRegistration>(env, (raw) {
      if (raw is Map) {
        return PlayerRegistration.fromJson(raw.cast<String, Object?>());
      }
      return PlayerRegistration.fromJson(const <String, Object?>{});
    });
  }
}

/// Resource client for `/sdk/v1/catalog` — single-shot read of every
/// item + currency configured for the calling game. Studios call this
/// once at boot and cache locally; pairs with `events.listForPlayer`
/// (which inlines reward-bundle previews) so a UI can render names,
/// icons, rarities, and reward previews without keeping a parallel
/// catalog in the client codebase.
class CatalogClient {
  final KratyClient _client;

  CatalogClient(this._client);

  /// `GET /sdk/v1/catalog` — items + currencies for the calling
  /// game. Game is derived from the API key; no parameters.
  Future<Catalog> read() async {
    final env = await _client.request(method: 'GET', path: '/sdk/v1/catalog');
    return _data<Catalog>(env, (raw) {
      if (raw is Map) return Catalog.fromJson(raw.cast<String, Object?>());
      return Catalog.fromJson(const <String, Object?>{});
    });
  }
}

/// Resource client for `/sdk/v1/lobbies/:id`. Used after `/start`
/// returns `lobby_forming`: poll this until `status` transitions
/// out of `forming`, then retry start.
class LobbiesClient {
  final KratyClient _client;

  LobbiesClient(this._client);

  Future<Lobby> read(String lobbyId) async {
    final env = await _client.request(
      method: 'GET',
      path: '/sdk/v1/lobbies/${_enc(lobbyId)}',
    );
    return _data<Lobby>(env, (raw) {
      if (raw is Map) return Lobby.fromJson(raw.cast<String, Object?>());
      return Lobby.fromJson(const <String, Object?>{});
    });
  }
}

/// Adaptive polling helpers.

class PollPendingGrantsOptions {
  /// Initial poll interval. Defaults to 2s.
  final Duration start;

  /// Multiplier between polls when the queue is empty. Defaults to 1.5.
  final double grow;

  /// Cap on interval growth. Defaults to 30s.
  final Duration max;

  /// Fires for every batch (including empty ones).
  final void Function(List<Grant>)? onBatch;

  const PollPendingGrantsOptions({
    this.start = const Duration(seconds: 2),
    this.grow = 1.5,
    this.max = const Duration(seconds: 30),
    this.onBatch,
  });
}

/// Adaptive polling for a player's pending grants. Grows the interval
/// while the queue is empty; resets to the floor when grants land.
/// Resolves when the [signal] future completes (e.g.,
/// `Future.delayed(...).then(...)` or a `Completer.future`).
Future<void> pollPendingGrants(
  GrantsClient grants, {
  PollPendingGrantsOptions options = const PollPendingGrantsOptions(),
  Future<void>? signal,
  /// Override the active player. Server tooling only. Defaults to
  /// the active id baked into the [GrantsClient]'s `KratyClient`.
  String? as,
}) async {
  var aborted = false;
  signal?.whenComplete(() => aborted = true);
  var interval = options.start;
  while (!aborted) {
    final batch = await grants.listPending(as: as);
    options.onBatch?.call(batch);
    if (batch.isNotEmpty) {
      interval = options.start;
    } else {
      final grown = Duration(
        milliseconds:
            (interval.inMilliseconds * options.grow).round(),
      );
      interval = grown > options.max ? options.max : grown;
    }
    await Future.any<void>([
      Future<void>.delayed(interval),
      if (signal != null) signal,
    ]);
  }
}

class PollLobbyOptions {
  /// Fixed poll interval. Defaults to 1s.
  final Duration interval;

  /// Cap on total wait before throwing [TimeoutException]. Defaults to 60s.
  final Duration timeout;

  const PollLobbyOptions({
    this.interval = const Duration(seconds: 1),
    this.timeout = const Duration(seconds: 60),
  });
}

/// Polls a lobby until it transitions out of `forming`. Throws
/// [TimeoutException] when the deadline elapses.
Future<Lobby> pollLobbyUntilActive(
  LobbiesClient lobbies,
  String lobbyId, {
  PollLobbyOptions options = const PollLobbyOptions(),
}) async {
  final deadline = DateTime.now().add(options.timeout);
  while (DateTime.now().isBefore(deadline)) {
    final lobby = await lobbies.read(lobbyId);
    if (lobby.status != 'forming') return lobby;
    await Future<void>.delayed(options.interval);
  }
  throw TimeoutException(
    "pollLobbyUntilActive: lobby '$lobbyId' did not leave 'forming' within ${options.timeout}",
  );
}
