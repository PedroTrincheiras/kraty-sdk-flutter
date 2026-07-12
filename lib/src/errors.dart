/// Sealed-ish set of error codes the backend returns. Mirrors
/// `api/errors.ts` on the backend side. Kept as constants (not an
/// enum) so the SDK survives the platform adding a new code without
/// a SDK release; consumers compare on strings, with the constants
/// below as the canonical names.
abstract class KratyErrorCode {
  KratyErrorCode._();

  // ── core ─────────────────────────────────────────────────────────
  static const String unauthenticated = 'unauthenticated';
  static const String sessionInvalid = 'session_invalid';
  static const String forbidden = 'forbidden';
  static const String notFound = 'not_found';
  static const String validationFailed = 'validation_failed';
  static const String conflict = 'conflict';
  static const String rateLimited = 'rate_limited';
  static const String internalError = 'internal_error';
  static const String tenantMismatch = 'tenant_mismatch';
  static const String idempotencyConflict = 'idempotency_conflict';

  // ── per-player auth ──────────────────────────────────────────────
  static const String playerSecretInvalid = 'player_secret_invalid';
  static const String playerAlreadyRegistered = 'player_already_registered';

  // ── events / attempts ────────────────────────────────────────────
  static const String eventDisabled = 'event_disabled';
  static const String noActiveWindow = 'no_active_window';
  static const String noLeaderboard = 'no_leaderboard';
  static const String maxAttemptsReached = 'max_attempts_reached';
  static const String maxDailyAttemptsReached = 'max_daily_attempts_reached';
  static const String attemptFinished = 'attempt_finished';
  static const String invalidMetric = 'invalid_metric';
  static const String unlockConditionFailed = 'unlock_condition_failed';
  static const String invalidUnlockCondition = 'invalid_unlock_condition';

  // ── entry requirements / cost ────────────────────────────────────
  static const String entryRequirementFailed = 'entry_requirement_failed';
  static const String invalidEntryRequirement = 'invalid_entry_requirement';
  static const String insufficientEntryCost = 'insufficient_entry_cost';

  // ── matchmaking ──────────────────────────────────────────────────
  static const String lobbyForming = 'lobby_forming';
}

/// Backend error envelope: every non-2xx response (and the special
/// 202 lobby-forming response) carries this shape.
class KratyErrorPayload {
  final String code;
  final String message;
  final Object? details;

  const KratyErrorPayload({
    required this.code,
    required this.message,
    this.details,
  });
}

/// Thrown for every non-2xx response (and the 202 lobby-forming
/// case). [status] is the HTTP status, [code] + [message] come from
/// the backend's `{ error: { code, message, details? } }` envelope.
///
/// Use the typed `is...` getters to switch on a code; they're cheaper
/// to read than a chain of string comparisons and immune to typos.
/// One getter exists per code in [KratyErrorCode]; if you need to
/// match a code the SDK hasn't bumped to yet, use [is].
class KratyApiError implements Exception {
  final int status;
  final String code;
  final String message;
  final Object? details;

  const KratyApiError({
    required this.status,
    required this.code,
    required this.message,
    this.details,
  });

  /// Generic code matcher. Useful when matching on a code the SDK
  /// doesn't yet have a typed getter for (e.g. a code the backend
  /// added before an SDK release).
  ///
  /// ```dart
  /// if (err.is('event_disabled')) showEventDisabledDialog();
  /// ```
  // Renamed to avoid the `is` keyword collision.
  bool isCode(String c) => code == c;

  // ── core ─────────────────────────────────────────────────────────

  /// 401: `Authorization` header missing on a protected route.
  bool get isUnauthenticated => code == KratyErrorCode.unauthenticated;

  /// 401: Bearer token is malformed, revoked, or rejected.
  bool get isSessionInvalid => code == KratyErrorCode.sessionInvalid;

  /// 403: authenticated but lacks the permission for this route.
  bool get isForbidden => code == KratyErrorCode.forbidden;

  /// 404: referenced resource doesn't exist or is archived.
  bool get isNotFound => code == KratyErrorCode.notFound;

  /// 400: request body / query failed schema validation. `details`
  /// carries the field-level errors.
  bool get isValidationFailed => code == KratyErrorCode.validationFailed;

  /// 409: generic mutation conflict. More specific 409 codes get
  /// their own getters; this catches the rest.
  bool get isConflict => code == KratyErrorCode.conflict;

  /// 429: per-key rate limit exceeded. The SDK auto-retries with
  /// backoff before surfacing this.
  bool get isRateLimited => code == KratyErrorCode.rateLimited;

  /// 500: unhandled exception. Surface a generic "something went
  /// wrong" to the player.
  bool get isInternalError => code == KratyErrorCode.internalError;

  /// 403: cross-studio access attempt. Shouldn't happen via the SDK.
  bool get isTenantMismatch => code == KratyErrorCode.tenantMismatch;

  /// 409: same `idempotencyKey` used with a different request body
  /// within the 24h cache TTL. The SDK auto-stamps fresh keys per
  /// write so you only see this when you've supplied your own key.
  bool get isIdempotencyConflict =>
      code == KratyErrorCode.idempotencyConflict;

  // ── per-player auth ──────────────────────────────────────────────

  /// 401: `X-Player-Secret` is missing, malformed, or doesn't match
  /// the stored hash. Triggers your re-authentication flow.
  bool get isPlayerSecretInvalid =>
      code == KratyErrorCode.playerSecretInvalid;

  /// 409: `register()` was called for a player who already has a
  /// secret. In dev/test, retry with `force: true`. In production,
  /// route to your account-recovery flow.
  bool get isPlayerAlreadyRegistered =>
      code == KratyErrorCode.playerAlreadyRegistered;

  // ── events / attempts ────────────────────────────────────────────

  /// 409: the event is configured but disabled.
  bool get isEventDisabled => code == KratyErrorCode.eventDisabled;

  /// 409: the event has no currently-active window.
  bool get isNoActiveWindow => code == KratyErrorCode.noActiveWindow;

  /// 503: server couldn't allocate / find the leaderboard. Usually
  /// transient, so retry after backoff.
  bool get isNoLeaderboard => code == KratyErrorCode.noLeaderboard;

  /// 429: player burned all attempts for the current event window.
  bool get isMaxAttemptsReached =>
      code == KratyErrorCode.maxAttemptsReached;

  /// 429: per-day attempt cap reached. Player should wait until
  /// midnight in the event's timezone.
  bool get isMaxDailyAttemptsReached =>
      code == KratyErrorCode.maxDailyAttemptsReached;

  /// 409: reported progress on an attempt that's already
  /// `completed` / `expired`. Refresh state.
  bool get isAttemptFinished => code == KratyErrorCode.attemptFinished;

  /// 400: `progress` referenced a metric key the event doesn't
  /// declare. SDK / game-config bug.
  bool get isInvalidMetric => code == KratyErrorCode.invalidMetric;

  /// 403: player can't see the event yet (visibility gate failed).
  bool get isUnlockConditionFailed =>
      code == KratyErrorCode.unlockConditionFailed;

  /// 500: event config has a malformed unlock condition tree.
  /// Operator should fix in the portal.
  bool get isInvalidUnlockCondition =>
      code == KratyErrorCode.invalidUnlockCondition;

  // ── entry requirements / cost ────────────────────────────────────

  /// 403: player attempted an event whose entry requirement failed
  /// (e.g. "must own item X"). Distinct from
  /// [isInsufficientEntryCost]: requirements are binary ownership
  /// checks, costs are transactional debits.
  bool get isEntryRequirementFailed =>
      code == KratyErrorCode.entryRequirementFailed;

  /// 500: event config has a malformed entry requirement.
  bool get isInvalidEntryRequirement =>
      code == KratyErrorCode.invalidEntryRequirement;

  /// 402: paid event start failed because the player couldn't
  /// cover the event's `entryCost`. The message carries the exact
  /// resource the player ran out of ("not enough cash to enter,
  /// need 50"). The server's atomic debit was rolled back, so partial
  /// spends never persist.
  bool get isInsufficientEntryCost =>
      code == KratyErrorCode.insufficientEntryCost;

  // ── matchmaking ──────────────────────────────────────────────────

  /// 202: lobby-matched event whose lobby isn't yet at capacity.
  /// Not a hard failure: poll the lobby endpoint (using
  /// `details['lobbyId']`) and retry `events.start` once it
  /// transitions out of `forming`.
  bool get isLobbyForming => code == KratyErrorCode.lobbyForming;

  @override
  String toString() => 'KratyApiError [$status] $code: $message';
}

/// Network / HTTP-layer failure that didn't produce an HTTP response
/// (DNS, socket reset, timeout, etc.).
class KratyNetworkError implements Exception {
  final String message;
  final Object? originalCause;

  const KratyNetworkError(this.message, [this.originalCause]);

  @override
  String toString() => 'KratyNetworkError: $message';
}

extension KratyApiErrorIs on Object? {
  /// Helper: `if (err.isLobbyFormingException) { ... }`; true iff
  /// this is a `KratyApiError` with `code == 'lobby_forming'`.
  bool get isLobbyFormingException {
    final self = this;
    return self is KratyApiError && self.isLobbyForming;
  }
}
