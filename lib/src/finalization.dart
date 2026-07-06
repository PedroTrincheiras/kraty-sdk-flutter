import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:shared_preferences/shared_preferences.dart';

/// Client finalization catch-up — see docs/05b. Ported from the TS SDK
/// reference (packages/client/sdk-typescript/src/finalization.ts).
///
/// CORE INVARIANT: a finalization is recorded through EXACTLY ONE writer,
/// [FinalizationTracker._resolveFinalized]. Both the live SSE `finalized`
/// event AND [FinalizationTracker.checkFinalizations] route through it — so
/// the SSE path persists `status: finalized` + `reportedAt` to the registry,
/// not just fires the callback. Whichever path arrives first wins; the other
/// no-ops on `reportedAt`. That is what makes delivery exactly-once across
/// live + catch-up.

/// The kind of board a membership refers to. Reference these constants
/// instead of hardcoding the wire strings — e.g. [MembershipKind.eventBoard],
/// never `'event_board'`.
abstract final class MembershipKind {
  /// A per-event (or per-session) board a player is placed on.
  static const String eventBoard = 'event_board';

  /// A recurring shared leaderboard (catch-up deferred — see docs/05b).
  static const String sharedBoard = 'shared_board';
}

/// Why a board finalized. The precise reasons come from the live SSE stream;
/// a catch-up read reports [finalized] only when the backend couldn't supply
/// one.
abstract final class FinalizationReason {
  /// A session/lobby inside an event terminated early.
  static const String sessionTerminated = 'session_terminated';

  /// The event window closed.
  static const String windowClosed = 'window_closed';

  /// A recurring shared board rolled to a new period.
  static const String periodRolled = 'period_rolled';

  /// Ended, but the precise cause is unknown.
  static const String finalized = 'finalized';
}

/// Whether a final standing belongs to a real player or a bot.
abstract final class StandingKind {
  static const String player = 'player';
  static const String bot = 'bot';
}

/// Tracked-membership lifecycle status.
abstract final class MembershipStatus {
  static const String active = 'active';
  static const String finalized = 'finalized';
}

/// A tracked board reference — either a per-event board (UUID) or a
/// configurable/shared board (key + period).
class MembershipRef {
  final String kind;
  final String? leaderboardId;
  final String? eventKey;
  final String? key;
  final String? period;

  const MembershipRef({
    required this.kind,
    this.leaderboardId,
    this.eventKey,
    this.key,
    this.period,
  });

  factory MembershipRef.eventBoard(String leaderboardId, {String? eventKey}) =>
      MembershipRef(
        kind: MembershipKind.eventBoard,
        leaderboardId: leaderboardId,
        eventKey: eventKey,
      );

  bool sameAs(MembershipRef o) {
    if (kind != o.kind) return false;
    if (kind == MembershipKind.eventBoard) {
      return leaderboardId == o.leaderboardId;
    }
    if (kind == MembershipKind.sharedBoard) {
      return key == o.key && period == o.period;
    }
    return false;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind,
        if (leaderboardId != null) 'leaderboardId': leaderboardId,
        if (eventKey != null) 'eventKey': eventKey,
        if (key != null) 'key': key,
        if (period != null) 'period': period,
      };

  factory MembershipRef.fromJson(Map<String, Object?> json) => MembershipRef(
        kind: json['kind'] as String? ?? MembershipKind.eventBoard,
        leaderboardId: json['leaderboardId'] as String?,
        eventKey: json['eventKey'] as String?,
        key: json['key'] as String?,
        period: json['period'] as String?,
      );
}

class TrackedMembership {
  final MembershipRef ref;
  String status;
  final String joinedAt;

  /// Set when [FinalizationTracker.onFinalized] has fired — the dedupe guard.
  String? reportedAt;
  final String? label;

  TrackedMembership({
    required this.ref,
    required this.status,
    required this.joinedAt,
    this.reportedAt,
    this.label,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'ref': ref.toJson(),
        'status': status,
        'joinedAt': joinedAt,
        if (reportedAt != null) 'reportedAt': reportedAt,
        if (label != null) 'label': label,
      };

  factory TrackedMembership.fromJson(Map<String, Object?> json) =>
      TrackedMembership(
        ref: MembershipRef.fromJson(
            (json['ref'] as Map).cast<String, Object?>()),
        status: json['status'] as String? ?? MembershipStatus.active,
        joinedAt: json['joinedAt'] as String? ?? '',
        reportedAt: json['reportedAt'] as String?,
        label: json['label'] as String?,
      );
}

class FinalStanding {
  final String participantId;
  final int rank;
  final double score;
  final String name;

  /// One of the [StandingKind] constants.
  final String kind;

  const FinalStanding({
    required this.participantId,
    required this.rank,
    required this.score,
    required this.name,
    required this.kind,
  });

  factory FinalStanding.fromJson(Map<String, Object?> json) => FinalStanding(
        participantId: json['participantId'] as String? ?? '',
        rank: (json['rank'] as num?)?.toInt() ?? 0,
        score: (json['score'] as num?)?.toDouble() ?? 0,
        name: json['name'] as String? ?? '',
        kind: json['kind'] as String? ?? StandingKind.player,
      );
}

/// The caller's own placement on a finalized board.
class SelfEntry {
  final int rank;
  final double score;
  const SelfEntry({required this.rank, required this.score});
}

class FinalizationResult {
  final MembershipRef ref;

  /// One of the [FinalizationReason] constants.
  final String reason;
  final SelfEntry? self;
  final List<FinalStanding>? standings;
  final String? eventKey;

  const FinalizationResult({
    required this.ref,
    required this.reason,
    this.self,
    this.standings,
    this.eventKey,
  });
}

/// Board-status probe the tracker asks the client for. [reason] is one of the
/// [FinalizationReason] constants, or null when the backend didn't supply one.
class EventBoardStatus {
  final bool finalized;
  final String? reason;
  final SelfEntry? self;
  const EventBoardStatus({
    required this.finalized,
    this.reason,
    this.self,
  });
}

/// Persisted registry, keyed per active player. Injectable per platform.
abstract class MembershipStore {
  Future<List<TrackedMembership>> load(String playerId);
  Future<void> save(String playerId, List<TrackedMembership> entries);
}

/// Volatile, process-local. Catch-up won't survive a restart.
class InMemoryMembershipStore implements MembershipStore {
  final Map<String, List<TrackedMembership>> _byPlayer = {};

  @override
  Future<List<TrackedMembership>> load(String playerId) async =>
      (_byPlayer[playerId] ?? const []).map(_clone).toList();

  @override
  Future<void> save(String playerId, List<TrackedMembership> entries) async {
    _byPlayer[playerId] = entries.map(_clone).toList();
  }

  static TrackedMembership _clone(TrackedMembership e) =>
      TrackedMembership.fromJson(e.toJson());
}

/// Durable store backed by `shared_preferences`. Key namespace mirrors the TS
/// SDK: `kraty.memberships.<playerId>`.
class SharedPreferencesMembershipStore implements MembershipStore {
  static const String _keyPrefix = 'kraty.memberships.';
  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  @override
  Future<List<TrackedMembership>> load(String playerId) async {
    final prefs = await _prefs;
    final raw = prefs.getString('$_keyPrefix$playerId');
    if (raw == null || raw.isEmpty) return [];
    try {
      final v = jsonDecode(raw);
      if (v is! List) return [];
      return v
          .map((e) => TrackedMembership.fromJson((e as Map).cast<String, Object?>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> save(String playerId, List<TrackedMembership> entries) async {
    final prefs = await _prefs;
    await prefs.setString(
      '$_keyPrefix$playerId',
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }
}

/// Lazily-resolved default store — `shared_preferences` when the Flutter
/// binding is live, in-memory otherwise. Mirrors `DefaultSecretStore`.
class DefaultMembershipStore implements MembershipStore {
  MembershipStore? _delegate;
  Future<MembershipStore>? _resolving;

  Future<MembershipStore> _resolve() {
    final cached = _delegate;
    if (cached != null) return Future.value(cached);
    final pending = _resolving;
    if (pending != null) return pending;
    final future = _probe();
    _resolving = future;
    return future;
  }

  Future<MembershipStore> _probe() async {
    try {
      await SharedPreferences.getInstance();
      return _delegate = SharedPreferencesMembershipStore();
    } on MissingPluginException {
      return _delegate = InMemoryMembershipStore();
    } catch (_) {
      return _delegate = InMemoryMembershipStore();
    } finally {
      _resolving = null;
    }
  }

  @override
  Future<List<TrackedMembership>> load(String playerId) async =>
      (await _resolve()).load(playerId);

  @override
  Future<void> save(String playerId, List<TrackedMembership> entries) async =>
      (await _resolve()).save(playerId, entries);
}

typedef FinalizationListener = void Function(FinalizationResult result);

/// Async board-status probe: returns null when the board can't be read (treat
/// as still-active).
typedef ReadEventBoard = Future<EventBoardStatus?> Function(String leaderboardId);

class FinalizationTracker {
  final MembershipStore _store;
  final Future<String?> Function() _getActivePlayerId;
  final ReadEventBoard _readEventBoard;
  final Duration _pruneAfter;
  final List<FinalizationListener> _listeners = [];

  // Serializes all registry read-modify-write so a live SSE event and a
  // checkFinalizations() poll can't both pass the reportedAt guard.
  Future<void> _chain = Future<void>.value();

  FinalizationTracker({
    required MembershipStore store,
    required Future<String?> Function() getActivePlayerId,
    required ReadEventBoard readEventBoard,
    Duration pruneAfter = const Duration(days: 7),
  })  : _store = store,
        _getActivePlayerId = getActivePlayerId,
        _readEventBoard = readEventBoard,
        _pruneAfter = pruneAfter;

  /// Register a finalization handler. Returns an unsubscribe function.
  void Function() onFinalized(FinalizationListener cb) {
    _listeners.add(cb);
    return () => _listeners.remove(cb);
  }

  /// Serialize a critical section onto the writer chain.
  Future<T> _serialize<T>(Future<T> Function() fn) {
    final completer = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        completer.complete(await fn());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Record that the player joined a board (idempotent upsert).
  Future<void> track(MembershipRef ref, {String? label}) async {
    final playerId = await _getActivePlayerId();
    if (playerId == null) return;
    await _serialize(() async {
      final entries = _prune(await _store.load(playerId));
      if (!entries.any((e) => e.ref.sameAs(ref))) {
        entries.add(TrackedMembership(
          ref: ref,
          status: MembershipStatus.active,
          joinedAt: DateTime.now().toUtc().toIso8601String(),
          label: label,
        ));
      }
      await _store.save(playerId, entries);
    });
  }

  // The SINGLE writer. Persists status + reportedAt THEN fires the callback.
  // Returns true iff this call resolved the entry. No-ops if the entry is
  // unknown or already reported.
  Future<bool> _resolveFinalized(
    String playerId,
    MembershipRef ref,
    FinalizationResult result,
  ) {
    return _serialize<bool>(() async {
      final entries = await _store.load(playerId);
      final idx = entries.indexWhere((e) => e.ref.sameAs(ref));
      if (idx < 0 || entries[idx].reportedAt != null) return false;
      entries[idx].status = MembershipStatus.finalized;
      entries[idx].reportedAt = DateTime.now().toUtc().toIso8601String();
      await _store.save(playerId, entries); // persist BEFORE firing
      _emit(result);
      return true;
    });
  }

  /// Live SSE path: a `finalized` stream event arrived. Routes through the
  /// same writer as catch-up — persists to the registry AND fires. (This is
  /// the invariant in docs/05b.)
  Future<void> onStreamFinalized(
    String leaderboardId,
    Map<String, Object?>? data,
  ) async {
    final playerId = await _getActivePlayerId();
    if (playerId == null) return;
    final reasonRaw = data?['reason'];
    final reason = (reasonRaw == FinalizationReason.sessionTerminated ||
            reasonRaw == FinalizationReason.windowClosed)
        ? reasonRaw as String
        : FinalizationReason.finalized;
    final ref = MembershipRef.eventBoard(leaderboardId);
    final standingsRaw = data?['standings'];
    await _resolveFinalized(
      playerId,
      ref,
      FinalizationResult(
        ref: ref,
        reason: reason,
        // The self entry isn't in the stream payload; match self in
        // `standings` by participantId.
        self: null,
        standings: standingsRaw is List
            ? standingsRaw
                .map((e) => FinalStanding.fromJson((e as Map).cast<String, Object?>()))
                .toList()
            : null,
      ),
    );
  }

  /// Catch-up path: poll still-active tracked boards and report any that
  /// finalized (through the same writer). Returns the newly-finalized results
  /// (also delivered via [onFinalized]). Cheap when the registry is empty.
  Future<List<FinalizationResult>> checkFinalizations() async {
    final playerId = await _getActivePlayerId();
    if (playerId == null) return const [];
    final entries = await _store.load(playerId);
    final active =
        entries.where((e) => e.status == MembershipStatus.active).toList();
    final out = <FinalizationResult>[];
    for (final e in active) {
      // shared_board catch-up: see docs/05b (deferred)
      if (e.ref.kind != MembershipKind.eventBoard ||
          e.ref.leaderboardId == null) {
        continue;
      }
      final read = await _readEventBoard(e.ref.leaderboardId!);
      if (read == null || !read.finalized) continue;
      final result = FinalizationResult(
        ref: e.ref,
        // The board now persists WHY it finalized, so a catch-up read can tell
        // a terminated session from a closed window. `finalized` is only the
        // fallback if the backend didn't supply a reason.
        reason: read.reason ?? FinalizationReason.finalized,
        self: read.self,
        eventKey: e.ref.eventKey,
      );
      if (await _resolveFinalized(playerId, e.ref, result)) out.add(result);
    }
    return out;
  }

  /// Acknowledge a finalization once the app has shown it — removes that
  /// membership from the registry so it never surfaces again. No-op if the ref
  /// isn't tracked.
  Future<void> dismiss(MembershipRef ref) async {
    final playerId = await _getActivePlayerId();
    if (playerId == null) return;
    await _serialize(() async {
      final entries = await _store.load(playerId);
      final kept = entries.where((e) => !e.ref.sameAs(ref)).toList();
      if (kept.length != entries.length) await _store.save(playerId, kept);
    });
  }

  /// Bulk cleanup — drop every already-reported entry. Returns how many were
  /// removed.
  Future<int> clearReported() async {
    final playerId = await _getActivePlayerId();
    if (playerId == null) return 0;
    return _serialize<int>(() async {
      final entries = await _store.load(playerId);
      final kept = entries.where((e) => e.reportedAt == null).toList();
      if (kept.length != entries.length) await _store.save(playerId, kept);
      return entries.length - kept.length;
    });
  }

  List<TrackedMembership> _prune(List<TrackedMembership> entries) {
    final cutoff = DateTime.now().toUtc().subtract(_pruneAfter);
    return entries.where((e) {
      final ts = DateTime.tryParse(e.reportedAt ?? e.joinedAt);
      return ts == null || !ts.toUtc().isBefore(cutoff);
    }).toList();
  }

  void _emit(FinalizationResult result) {
    for (final l in List<FinalizationListener>.from(_listeners)) {
      try {
        l(result);
      } catch (_) {
        // a listener throwing must not break the writer
      }
    }
  }
}
