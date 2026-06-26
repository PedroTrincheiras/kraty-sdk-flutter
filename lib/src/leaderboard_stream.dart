import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';

/// One event emitted by the leaderboard SSE stream.
/// [kind] is the SSE `event:` line — typically:
///   - `ready` — handshake, sent once after the subscription is wired
///   - `score_update` — a participant's score / rank changed
///   - `closed` — server is finalizing or closing the stream
///
/// [data] is the parsed `data:` JSON line (or null if it didn't parse).
class LeaderboardStreamEvent {
  final String kind;
  final Map<String, Object?> data;
  const LeaderboardStreamEvent({required this.kind, required this.data});
}

/// Handle to an active SSE subscription. Call [cancel] to stop. Errors
/// from the underlying stream surface on [errors] — caller can decide
/// to reconnect or give up.
class LeaderboardStream {
  /// Event stream — yields `ready` / `score_update` / `closed` /
  /// any future event kinds the server adds. Single-subscriber.
  final Stream<LeaderboardStreamEvent> events;

  /// Transport failures (network drop, server crash mid-stream).
  /// Production code typically subscribes to this and re-invokes
  /// `leaderboards.live(...)` after a backoff. The SDK does NOT
  /// auto-reconnect — that policy belongs to the consumer.
  final Stream<Object> errors;

  final Future<void> Function() _cancel;

  const LeaderboardStream._(
    this.events,
    this.errors,
    this._cancel,
  );

  /// Cancels the subscription + closes the HTTP socket. Idempotent —
  /// safe to call after the server emits `closed`.
  Future<void> cancel() => _cancel();
}

/// Opens an SSE subscription to a leaderboard. Returns a
/// [LeaderboardStream] handle the caller drives via its event/error
/// streams. Does NOT auto-reconnect — wrap it yourself when the
/// underlying transport drops.
///
/// Implementation: opens a long-lived `http.Request` (NOT a
/// `http.Client.get`) and parses the SSE framing line by line.
/// `\n\n` separates events; `event:` / `data:` are the keys we read.
/// Comment lines starting with `:` are heartbeats — ignored.
Future<LeaderboardStream> openLeaderboardStream({
  required String baseUrl,
  required String leaderboardId,
  required String authHeader,
  required http.Client httpClient,
  required String sdkUserAgent,
  String? playerSecret,
}) async {
  final req = http.Request(
    'GET',
    Uri.parse('$baseUrl/sdk/v1/event-leaderboards/$leaderboardId/stream'),
  );
  req.headers['authorization'] = authHeader;
  req.headers['accept'] = 'text/event-stream';
  req.headers['x-kraty-sdk'] = sdkUserAgent;
  if (playerSecret != null && playerSecret.isNotEmpty) {
    req.headers['x-player-secret'] = playerSecret;
  }

  late http.StreamedResponse response;
  try {
    response = await httpClient.send(req);
  } catch (err) {
    throw KratyNetworkError('leaderboard stream connect failed: $err', err);
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    // Drain the body so the connection doesn't dangle, then surface
    // the error in the same shape the rest of the SDK uses.
    final bodyText = await response.stream.transform(utf8.decoder).join();
    Map<String, Object?> errBody = const <String, Object?>{};
    try {
      final decoded = jsonDecode(bodyText);
      if (decoded is Map) {
        final inner = decoded['error'];
        if (inner is Map) {
          errBody = inner.cast<String, Object?>();
        }
      }
    } catch (_) {
      // Body wasn't JSON — fall back to the status code as message.
    }
    throw KratyApiError(
      status: response.statusCode,
      code: (errBody['code'] as String?) ??
          'http_${response.statusCode}',
      message: (errBody['message'] as String?) ?? bodyText,
      details: errBody['details'],
    );
  }

  final eventsCtrl = StreamController<LeaderboardStreamEvent>();
  final errorsCtrl = StreamController<Object>.broadcast();
  StreamSubscription<String>? lineSub;
  String currentEvent = 'message';
  final dataBuffer = StringBuffer();

  void emit() {
    if (dataBuffer.isEmpty) {
      currentEvent = 'message';
      return;
    }
    try {
      final parsed = jsonDecode(dataBuffer.toString());
      final asMap = parsed is Map
          ? parsed.cast<String, Object?>()
          : <String, Object?>{'value': parsed};
      eventsCtrl.add(LeaderboardStreamEvent(kind: currentEvent, data: asMap));
    } catch (err) {
      errorsCtrl.add(err);
    }
    dataBuffer.clear();
    currentEvent = 'message';
  }

  lineSub = response.stream
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
    (line) {
      if (line.isEmpty) {
        // Blank line terminates an event.
        emit();
        return;
      }
      if (line.startsWith(':')) {
        // Comment / heartbeat — ignore.
        return;
      }
      final colonIdx = line.indexOf(':');
      if (colonIdx < 0) return;
      final field = line.substring(0, colonIdx);
      // Spec: a single leading space in the value is optional and
      // should be stripped.
      var value = line.substring(colonIdx + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'event':
          currentEvent = value;
          break;
        case 'data':
          if (dataBuffer.isNotEmpty) dataBuffer.write('\n');
          dataBuffer.write(value);
          break;
        // SSE also defines `id` and `retry` — we don't use them.
        default:
          break;
      }
    },
    onError: (Object err) {
      errorsCtrl.add(err);
    },
    onDone: () {
      // Surface anything still buffered as a final event, then close.
      emit();
      if (!eventsCtrl.isClosed) eventsCtrl.close();
      if (!errorsCtrl.isClosed) errorsCtrl.close();
    },
    cancelOnError: false,
  );

  Future<void> cancel() async {
    await lineSub?.cancel();
    if (!eventsCtrl.isClosed) await eventsCtrl.close();
    if (!errorsCtrl.isClosed) await errorsCtrl.close();
  }

  return LeaderboardStream._(eventsCtrl.stream, errorsCtrl.stream, cancel);
}
