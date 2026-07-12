import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'errors.dart';
import 'finalization.dart';
import 'secret_store.dart';
import 'types.dart' show EventLeaderboard;

/// SDK name + version, sent as `X-Kraty-SDK: <name>/<version>` on
/// every request. Lets the backend tell which SDK + version sent a
/// given request, useful for debugging stale-SDK deployments and
/// for graceful deprecation handling. Bump in lockstep with
/// `pubspec.yaml` `version`.
const String _sdkName = 'kraty-flutter';
const String _sdkVersion = '0.9.0';
const String _sdkUserAgent = '$_sdkName/$_sdkVersion';

/// Telemetry record fired after every HTTP attempt.
@immutable
class KratyRequestInfo {
  final String method;
  final String url;
  final int attempt;
  final String? idempotencyKey;
  final Duration duration;
  final int? status;
  final bool ok;

  const KratyRequestInfo({
    required this.method,
    required this.url,
    required this.attempt,
    required this.idempotencyKey,
    required this.duration,
    required this.status,
    required this.ok,
  });
}

@immutable
class KratyRetryConfig {
  /// TOTAL number of HTTP attempts (1 = no retry).
  final int attempts;
  final Duration initialDelay;
  final Duration maxDelay;

  /// Jitter factor in [0, 1]. Default 0.2.
  final double jitter;

  const KratyRetryConfig({
    this.attempts = 4,
    this.initialDelay = const Duration(milliseconds: 100),
    this.maxDelay = const Duration(seconds: 5),
    this.jitter = 0.2,
  });
}

/// Options the consumer passes to `KratyClient(options: ...)`.
@immutable
class KratyClientOptions {
  /// API key in the `{prefix}.{secret}` form returned by the portal.
  final String apiKey;

  /// Defaults to `https://api.kraty.io`. Override for staging /
  /// local development.
  final String baseUrl;

  /// Per-request timeout. Defaults to 10s.
  final Duration timeout;

  final KratyRetryConfig retry;

  /// Optional HTTP client: tests inject `MockClient`; production can
  /// layer a custom `BaseClient` for instrumentation. Defaults to a
  /// fresh `http.Client()`.
  final http.Client? httpClient;

  /// Idempotency-key generator. Defaults to a 16-byte hex random.
  final String Function()? generateIdempotencyKey;

  /// Fires after every HTTP attempt; useful for telemetry.
  final void Function(KratyRequestInfo info)? onRequest;

  /// Per-player secret. When set, the client attaches
  /// `X-Player-Secret: <value>` on every request. Required by every
  /// player-scoped route. Leave unset and the SDK lazily mints one
  /// on the first player-scoped call via [KratyClient.ensureIdentity].
  final String? playerSecret;

  /// The `externalPlayerId` this SDK instance is authenticated as.
  /// When set together with [playerSecret], player-scoped methods
  /// skip the lazy-register round-trip and use this id directly.
  /// Leave unset for self-serve signups; the SDK auto-generates a
  /// `kp_<uuid>` id on first use and persists it in [secretStore].
  final String? activeExternalPlayerId;

  /// Persistence backend for the player secret + active id. When
  /// omitted, the SDK auto-selects a durable default: a
  /// `shared_preferences`-backed store inside Flutter apps, an
  /// in-memory store in pure-Dart CLIs (where the Flutter binding
  /// isn't available). For higher-value economies, plug a Keychain
  /// or `flutter_secure_storage`-backed implementation here.
  final SecretStore? secretStore;

  /// Persisted registry of the boards the player is in, powering the
  /// finalization catch-up (see docs/05b + [KratyClient.onFinalized]). When
  /// omitted, the SDK auto-selects a durable default the same way as
  /// [secretStore]: `shared_preferences` inside Flutter, in-memory in
  /// pure-Dart CLIs.
  final MembershipStore? membershipStore;

  const KratyClientOptions({
    required this.apiKey,
    this.baseUrl = 'https://api.kraty.io',
    this.timeout = const Duration(seconds: 10),
    this.retry = const KratyRetryConfig(),
    this.httpClient,
    this.generateIdempotencyKey,
    this.onRequest,
    this.playerSecret,
    this.activeExternalPlayerId,
    this.secretStore,
    this.membershipStore,
  });
}

/// Set of methods we auto-stamp with `idempotencyKey` if the body
/// doesn't already include one. `GET` is naturally idempotent so we
/// skip it.
const _idempotentMethods = <String>{'POST', 'PUT', 'PATCH'};

/// Statuses we retry. Mirrors the TypeScript reference.
const _retryableStatuses = <int>{408, 425, 429, 500, 502, 503, 504};

/// HTTP client for the Kraty `/sdk/v1` surface. Bearer auth,
/// auto-`idempotencyKey` stamping on POST/PUT/PATCH (preserved across
/// retries so the server's idempotency check dedupes a replayed
/// call), exponential backoff + jitter on 408/425/429/5xx + network
/// failures, special-cases the backend's 202+`lobby_forming`
/// response shape.
///
/// Resource clients (`EventsClient`, `LeaderboardsClient`, ...)
/// compose over an instance; the convenience facade [Kraty] wires
/// them all up.
class KratyClient {
  final String _baseUrl;
  final Duration _timeout;
  final KratyRetryConfig _retry;
  final http.Client _http;
  final bool _ownsHttp;
  final String _authHeader;
  // Identity is mutable on purpose: `ensureIdentity()` may register
  // or restore a player after construction and writes back here so
  // subsequent calls skip the round-trip.
  String? _playerSecret;
  String? _activeExternalPlayerId;
  final SecretStore _secretStore;
  final MembershipStore _membershipStore;
  late final FinalizationTracker _finalization;
  final String Function() _generateIdempotencyKey;
  final void Function(KratyRequestInfo)? _onRequest;
  final math.Random _jitterRng = math.Random();
  // Concurrent first-touch dedupe: two simultaneous player-scoped
  // calls share one register round-trip.
  Future<({String externalPlayerId, String secret})>? _identityInit;

  KratyClient(KratyClientOptions options)
      : _baseUrl = _stripTrailingSlash(options.baseUrl),
        _timeout = options.timeout,
        _retry = options.retry,
        _http = options.httpClient ?? http.Client(),
        _ownsHttp = options.httpClient == null,
        _authHeader = 'Bearer ${_validateApiKey(options.apiKey)}',
        _playerSecret = (options.playerSecret != null &&
                options.playerSecret!.isNotEmpty)
            ? options.playerSecret
            : null,
        _activeExternalPlayerId = (options.activeExternalPlayerId != null &&
                options.activeExternalPlayerId!.isNotEmpty)
            ? options.activeExternalPlayerId
            : null,
        _secretStore = options.secretStore ?? DefaultSecretStore(),
        _membershipStore = options.membershipStore ?? DefaultMembershipStore(),
        _generateIdempotencyKey =
            options.generateIdempotencyKey ?? _defaultIdempotencyKey,
        _onRequest = options.onRequest {
    _finalization = FinalizationTracker(
      store: _membershipStore,
      // Never force-register during catch-up: only the current active player.
      getActivePlayerId: () async => _activeExternalPlayerId,
      readEventLeaderboard: _readEventLeaderboardStatus,
    );
  }

  // Probe an event board's finalized status + reason + the caller's self
  // entry for the finalization catch-up. Returns null (treated as
  // still-active) when there's no active player or the read fails.
  Future<EventLeaderboardStatus?> _readEventLeaderboardStatus(String leaderboardId) async {
    final ext = _activeExternalPlayerId;
    if (ext == null || ext.isEmpty) return null;
    try {
      final qs = 'includeSelf=true&externalId=${Uri.encodeComponent(ext)}&limit=1';
      final env = await request(
        method: 'GET',
        path: '/sdk/v1/event-leaderboards/${Uri.encodeComponent(leaderboardId)}?$qs',
      );
      final data = env['data'];
      if (data is! Map) return null;
      final lb = EventLeaderboard.fromJson(data.cast<String, Object?>());
      return EventLeaderboardStatus(
        finalized: lb.finalized,
        reason: lb.finalizedReason,
        self: lb.self != null
            ? SelfEntry(rank: lb.self!.rank, score: lb.self!.score)
            : null,
      );
    } catch (_) {
      return null; // unreadable → treat as still-active
    }
  }

  static String _validateApiKey(String apiKey) {
    if (apiKey.isEmpty) {
      throw ArgumentError.value(apiKey, 'apiKey', 'KratyClient: apiKey is required');
    }
    return apiKey;
  }

  static String _stripTrailingSlash(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  /// Releases the underlying HTTP client, but only if this instance
  /// owns it (consumer didn't pass one in).
  void close() {
    if (_ownsHttp) _http.close();
  }

  /// Low-level accessors for the leaderboard SSE client, which needs
  /// a long-lived `http.send` rather than the bounded request/response
  /// shape `request()` provides. NOT intended for general consumer
  /// use; prefer the per-resource clients.
  String get baseUrlForStreaming => _baseUrl;
  String get authHeaderForStreaming => _authHeader;
  String? get playerSecretForStreaming => _playerSecret;
  http.Client get httpForStreaming => _http;
  String get sdkUserAgentForStreaming => _sdkUserAgent;

  /// The active player this client is authenticated as. Resource
  /// methods fall back to this id when the caller omits `as:`.
  /// Returns null until [ensureIdentity] has run at least once.
  String? get activeExternalPlayerId => _activeExternalPlayerId;

  /// The current per-player secret. Null until [ensureIdentity] has
  /// resolved (or the constructor was given one).
  String? get playerSecret => _playerSecret;

  /// The store this client is backed by. Exposed so callers can read
  /// the persisted active id without going through the SDK.
  SecretStore get secretStore => _secretStore;

  /// Resolve the active player, registering a fresh one if none
  /// exists. Called transparently by every player-scoped resource
  /// method; game code rarely needs to invoke this directly.
  ///
  /// Resolution order:
  ///  1. Constructor `activeExternalPlayerId` + `playerSecret` if
  ///     both were supplied (explicit, no I/O).
  ///  2. SecretStore's persisted active id + matching secret, the
  ///     "resume previous session" path.
  ///  3. Fresh self-serve signup: generate a `kp_<uuid>` id, POST
  ///     /sdk/v1/players/:id/register, persist the secret, install
  ///     it on the client.
  ///
  /// Concurrent first-touch calls share one inflight future.
  Future<({String externalPlayerId, String secret})> ensureIdentity() async {
    final activeId = _activeExternalPlayerId;
    final secret = _playerSecret;
    if (activeId != null && secret != null) {
      return (externalPlayerId: activeId, secret: secret);
    }
    final pending = _identityInit;
    if (pending != null) return pending;
    final future = _resolveIdentity();
    _identityInit = future;
    try {
      return await future;
    } finally {
      _identityInit = null;
    }
  }

  Future<({String externalPlayerId, String secret})> _resolveIdentity() async {
    final explicitActive = _activeExternalPlayerId;
    final storedActive = await _secretStore.readActiveExternalPlayerId();
    final candidate = explicitActive ?? storedActive;
    if (candidate != null && candidate.isNotEmpty) {
      final stored = await _secretStore.read(candidate);
      if (stored != null && stored.isNotEmpty) {
        _activeExternalPlayerId = candidate;
        _playerSecret = stored;
        await _secretStore.writeActiveExternalPlayerId(candidate);
        return (externalPlayerId: candidate, secret: stored);
      }
    }
    final newId = explicitActive ?? _generateExternalPlayerId();
    final res = await request(
      method: 'POST',
      path: '/sdk/v1/players/${Uri.encodeComponent(newId)}/register',
      body: const <String, Object?>{},
    );
    final data = res['data'];
    final mintedSecret = data is Map && data['secret'] is String
        ? data['secret']! as String
        : '';
    await _secretStore.write(newId, mintedSecret);
    await _secretStore.writeActiveExternalPlayerId(newId);
    _activeExternalPlayerId = newId;
    _playerSecret = mintedSecret;
    return (externalPlayerId: newId, secret: mintedSecret);
  }

  /// Forget the persisted identity (secret + active id). The next
  /// player-scoped call triggers a fresh [ensureIdentity] and either
  /// resumes from a different stored id or registers a new player.
  /// Use this on "switch user" / "sign out" flows.
  Future<void> logout() async {
    final id = _activeExternalPlayerId;
    if (id != null) {
      try {
        await _secretStore.remove(id);
      } catch (_) {
        // best-effort
      }
    }
    await _secretStore.clearActiveExternalPlayerId();
    _activeExternalPlayerId = null;
    _playerSecret = null;
  }

  /// Install an explicit identity on this client (and persist it via
  /// the SecretStore so subsequent launches resume to it). Use when
  /// a player signs in via your own auth on a new device and you've
  /// fetched their secret out of your own backend.
  Future<void> signIn({
    required String externalPlayerId,
    required String secret,
  }) async {
    await _secretStore.write(externalPlayerId, secret);
    await _secretStore.writeActiveExternalPlayerId(externalPlayerId);
    _activeExternalPlayerId = externalPlayerId;
    _playerSecret = secret;
  }

  // ── Finalization catch-up (docs/05b) ─────────────────────────────
  // onFinalized fires when a board the player is in ends: live over SSE
  // while subscribed, OR via checkFinalizations() for boards that finalized
  // while they were away. Both paths deliver exactly once.

  /// Register a finalization handler. Returns an unsubscribe function.
  void Function() onFinalized(FinalizationListener cb) =>
      _finalization.onFinalized(cb);

  /// Poll tracked boards; report + return any that finalized while away.
  /// Call on app foreground / reconnect.
  Future<List<FinalizationResult>> checkFinalizations() =>
      _finalization.checkFinalizations();

  /// Acknowledge a handled finalization; drop it from the registry.
  Future<void> dismiss(MembershipRef ref) => _finalization.dismiss(ref);

  /// Bulk-drop every already-reported membership. Returns the count.
  Future<int> clearReported() => _finalization.clearReported();

  /// Record the board the player just joined (called by [EventsClient.start]).
  /// Fire-and-forget; never add latency or throw into start.
  Future<void> trackMembership(MembershipRef ref) => _finalization.track(ref);

  /// Route a live `finalized` SSE event through the same single writer as
  /// catch-up so the registry is updated (not just the callback). See docs/05b.
  Future<void> routeFinalized(String leaderboardId, Map<String, Object?>? data) =>
      _finalization.onStreamFinalized(leaderboardId, data);

  /// Low-level: fire a JSON request. Resource clients call this;
  /// consumers usually go through the per-resource wrappers
  /// instead.
  ///
  /// `T` is whatever JSON shape the endpoint returns. Pass
  /// `Map<String, Object?>` and decode manually with the type's
  /// `fromJson` factory.
  Future<Map<String, Object?>> request({
    required String method,
    required String path,
    Object? body,
    String? idempotencyKeyOverride,
  }) async {
    final url = '$_baseUrl${path.startsWith('/') ? path : '/$path'}';
    final upperMethod = method.toUpperCase();
    final idempotencyKey = _resolveIdempotencyKey(
      method: upperMethod,
      body: body,
      explicit: idempotencyKeyOverride,
    );
    final requestBody = _attachIdempotencyKey(body, idempotencyKey);

    Object? lastErr;
    for (int attempt = 1; attempt <= _retry.attempts; attempt++) {
      final sw = Stopwatch()..start();
      try {
        final res = await _fireOnce(upperMethod, url, requestBody)
            .timeout(_timeout);
        sw.stop();
        _onRequest?.call(KratyRequestInfo(
          method: upperMethod,
          url: url,
          attempt: attempt,
          idempotencyKey: idempotencyKey,
          duration: sw.elapsed,
          status: res.statusCode,
          ok: res.statusCode >= 200 && res.statusCode < 300,
        ));

        if (res.statusCode >= 200 && res.statusCode < 300) {
          final parsed = _parseJson(res);
          // The backend uses 202 + `{ error: { code, message } }` to
          // signal "valid request, not ready yet"; currently only
          // `lobby_forming`. Surface as a `KratyApiError` so
          // consumers `switch (err.code)` uniformly across statuses.
          final maybeErr = _tryReadErrorEnvelope(parsed);
          if (maybeErr != null) {
            throw KratyApiError(
              status: res.statusCode,
              code: maybeErr.code,
              message: maybeErr.message,
              details: maybeErr.details,
            );
          }
          return parsed ?? <String, Object?>{};
        }

        final apiErr = _asApiError(res);
        if (_retryableStatuses.contains(res.statusCode) &&
            attempt < _retry.attempts) {
          await _sleepBackoff(attempt, res);
          lastErr = apiErr;
          continue;
        }
        throw apiErr;
      } on KratyApiError {
        rethrow;
      } catch (err, stack) {
        sw.stop();
        if (err is TimeoutException || err is http.ClientException || err is Exception) {
          _onRequest?.call(KratyRequestInfo(
            method: upperMethod,
            url: url,
            attempt: attempt,
            idempotencyKey: idempotencyKey,
            duration: sw.elapsed,
            status: null,
            ok: false,
          ));
          final wrapped = KratyNetworkError(
            err is Error ? err.toString() : err.toString(),
            err,
          );
          if (attempt < _retry.attempts) {
            await _sleepBackoff(attempt, null);
            lastErr = wrapped;
            continue;
          }
          throw wrapped;
        }
        // Genuinely unexpected; rethrow with original stack.
        Error.throwWithStackTrace(err, stack);
      }
    }
    if (lastErr != null) throw lastErr;
    throw const KratyNetworkError('exhausted retries');
  }

  Future<http.Response> _fireOnce(
    String method,
    String url,
    Object? body,
  ) async {
    final secret = _playerSecret;
    final headers = <String, String>{
      'authorization': _authHeader,
      'accept': 'application/json',
      'x-kraty-sdk': _sdkUserAgent,
      if (body != null) 'content-type': 'application/json',
      if (secret != null && secret.isNotEmpty) 'x-player-secret': secret,
    };
    final bodyBytes = body == null ? null : utf8.encode(jsonEncode(body));
    final req = http.Request(method, Uri.parse(url));
    req.headers.addAll(headers);
    if (bodyBytes != null) req.bodyBytes = bodyBytes;
    final streamed = await _http.send(req);
    return http.Response.fromStream(streamed);
  }

  String? _resolveIdempotencyKey({
    required String method,
    required Object? body,
    required String? explicit,
  }) {
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (!_idempotentMethods.contains(method)) return null;
    if (body is Map && body['idempotencyKey'] is String) {
      final v = body['idempotencyKey'] as String;
      if (v.isNotEmpty) return v;
    }
    return _generateIdempotencyKey();
  }

  Object? _attachIdempotencyKey(Object? body, String? key) {
    if (key == null) return body;
    if (body == null) return <String, Object?>{'idempotencyKey': key};
    if (body is Map<String, Object?>) {
      if (body.containsKey('idempotencyKey')) return body;
      return <String, Object?>{...body, 'idempotencyKey': key};
    }
    // Fallback: encode and splice. The HTTP layer JSON-encodes the
    // result either way; this keeps the body well-formed without
    // introducing a Map clone surprise.
    final asJson = jsonDecode(jsonEncode(body));
    if (asJson is Map) {
      if (asJson.containsKey('idempotencyKey')) return asJson;
      asJson['idempotencyKey'] = key;
      return asJson;
    }
    return body;
  }

  Future<void> _sleepBackoff(int attempt, http.Response? res) async {
    // Honor Retry-After when present (429s in particular).
    final retryAfter = res?.headers['retry-after'];
    if (retryAfter != null) {
      final seconds = double.tryParse(retryAfter);
      if (seconds != null && seconds >= 0) {
        final ms = (seconds * 1000).round();
        final capped = ms > _retry.maxDelay.inMilliseconds
            ? _retry.maxDelay
            : Duration(milliseconds: ms);
        await Future<void>.delayed(capped);
        return;
      }
    }
    final baseMs = math.min(
      _retry.initialDelay.inMilliseconds * math.pow(2, attempt - 1),
      _retry.maxDelay.inMilliseconds.toDouble(),
    );
    final jitter = _retry.jitter;
    final rand = _jitterRng.nextDouble() * 2 - 1; // [-1, 1)
    final jittered = (baseMs * (1 + rand * jitter)).clamp(0, double.infinity);
    await Future<void>.delayed(Duration(milliseconds: jittered.round()));
  }

  static Map<String, Object?>? _parseJson(http.Response res) {
    if (res.statusCode == 204) return null;
    final text = res.body;
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k as String, v));
      }
      // Top-level array or scalar isn't expected from the SDK
      // surface, so wrap it so the caller's `[key]` access doesn't NPE.
      return <String, Object?>{'__nonObject': decoded};
    } on FormatException {
      throw KratyApiError(
        status: res.statusCode,
        code: KratyErrorCode.internalError,
        message: 'response body was not valid JSON: ${text.length > 200 ? text.substring(0, 200) : text}',
      );
    }
  }

  static KratyErrorPayload? _tryReadErrorEnvelope(Map<String, Object?>? json) {
    if (json == null) return null;
    final err = json['error'];
    if (err is! Map) return null;
    final code = err['code'];
    final message = err['message'];
    if (code is! String || code.isEmpty) return null;
    return KratyErrorPayload(
      code: code,
      message: message is String ? message : '',
      details: err['details'],
    );
  }

  static KratyApiError _asApiError(http.Response res) {
    Map<String, Object?>? parsed;
    try {
      final decoded = res.body.isEmpty ? null : jsonDecode(res.body);
      if (decoded is Map<String, Object?>) parsed = decoded;
    } on FormatException {
      // fall through; we synthesize below
    }
    final env = _tryReadErrorEnvelope(parsed);
    if (env != null) {
      return KratyApiError(
        status: res.statusCode,
        code: env.code,
        message: env.message,
        details: env.details,
      );
    }
    return KratyApiError(
      status: res.statusCode,
      code: KratyErrorCode.internalError,
      message:
          'non-2xx response without an error envelope (status=${res.statusCode})',
    );
  }
}

String _defaultIdempotencyKey() {
  // 16 random bytes as hex: not RFC 4122 v4 but unique enough for
  // request dedup. (We'd use `Uuid().v4()` here but want zero
  // additional pub deps for a single helper.)
  final rng = math.Random.secure();
  final buf = StringBuffer();
  for (int i = 0; i < 32; i++) {
    buf.write(rng.nextInt(16).toRadixString(16));
  }
  return buf.toString();
}

/// Mints a fresh `kp_<32-hex>` external player id for self-serve
/// signups. Prefixed so a glance at the audit log distinguishes
/// SDK-minted ids from your own (which typically come from your auth
/// backend). Collision resistance is fine for the lifetime of a
/// device; security rests on the per-player secret, not on the id
/// being unguessable.
String _generateExternalPlayerId() {
  final rng = math.Random.secure();
  final buf = StringBuffer('kp_');
  for (int i = 0; i < 32; i++) {
    buf.write(rng.nextInt(16).toRadixString(16));
  }
  return buf.toString();
}
