import 'dart:async';

import 'package:http/http.dart' as http;

import 'sse.dart';

/// One event emitted by the leaderboard SSE stream.
/// [kind] is the SSE `event:` line. Typically:
///   - `ready`: handshake, sent once after the subscription is wired
///   - `score_update`: a participant's score / rank changed
///   - `finalized`: the board ended (a session/lobby terminated, or the
///     event window closed). [data] carries `reason`
///     (`session_terminated` | `window_closed`) and `standings`
///     (a list of `{participantId, rank, score, name, kind}`). Find the
///     caller by `participantId` to show their placement, then stop
///     expecting `score_update`s.
///   - `closed`: server is finalizing or closing the stream
///
/// [data] is the parsed `data:` JSON line (or null if it didn't parse).
class LeaderboardStreamEvent {
  final String kind;
  final Map<String, Object?> data;
  const LeaderboardStreamEvent({required this.kind, required this.data});
}

/// Handle to an active SSE subscription. Call [cancel] to stop. Errors
/// from the underlying stream surface on [errors], and the caller can
/// decide to reconnect or give up.
class LeaderboardStream {
  /// Event stream: yields `ready` / `score_update` / `closed` /
  /// any future event kinds the server adds. Single-subscriber.
  final Stream<LeaderboardStreamEvent> events;

  /// Transport failures (network drop, server crash mid-stream).
  /// Production code typically subscribes to this and re-invokes
  /// `leaderboards.live(...)` after a backoff. The SDK does NOT
  /// auto-reconnect; that policy belongs to the consumer.
  final Stream<Object> errors;

  final Future<void> Function() _cancel;

  const LeaderboardStream._(
    this.events,
    this.errors,
    this._cancel,
  );

  /// Cancels the subscription + closes the HTTP socket. Idempotent, so
  /// it's safe to call after the server emits `closed`.
  Future<void> cancel() => _cancel();
}

/// Opens an SSE subscription to a leaderboard. Returns a
/// [LeaderboardStream] handle the caller drives via its event/error
/// streams. Does NOT auto-reconnect; wrap it yourself when the
/// underlying transport drops.
///
/// The SSE framing itself is parsed by the shared reader in `sse.dart`;
/// this only maps the generic events onto the leaderboard-shaped type.
Future<LeaderboardStream> openLeaderboardStream({
  required String baseUrl,
  required String leaderboardId,
  required String authHeader,
  required http.Client httpClient,
  required String sdkUserAgent,
  String? playerSecret,
}) async {
  final raw = await openSseStream(
    baseUrl: baseUrl,
    path: '/sdk/v1/event-leaderboards/$leaderboardId/stream',
    authHeader: authHeader,
    httpClient: httpClient,
    sdkUserAgent: sdkUserAgent,
    label: 'leaderboard stream',
    playerSecret: playerSecret,
  );
  return LeaderboardStream._(
    raw.events.map(
      (e) => LeaderboardStreamEvent(kind: e.kind, data: e.data),
    ),
    raw.errors,
    raw.cancel,
  );
}
