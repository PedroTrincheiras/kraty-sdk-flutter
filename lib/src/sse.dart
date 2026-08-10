import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';

/// Minimal Server-Sent Events reader shared by every Kraty stream
/// (leaderboards, inventory). Parses the `event:` / `data:` line protocol
/// off a long-lived HTTP response and surfaces one [SseEvent] per event.
///
/// No auto-reconnect on purpose: resumption policy differs per stream and
/// per game (backoff, whether to re-read state first), so transport
/// failures land on [SseStream.errors] and the caller decides.

/// One parsed SSE event: the `event:` name plus the decoded `data:` JSON.
class SseEvent {
  final String kind;
  final Map<String, Object?> data;
  const SseEvent({required this.kind, required this.data});
}

/// Handle to an open SSE subscription.
class SseStream {
  /// Server-pushed events. Single-subscriber.
  final Stream<SseEvent> events;

  /// Transport failures (network drop, server crash mid-stream) and
  /// malformed payloads. Broadcast, so several listeners can watch it.
  final Stream<Object> errors;

  final Future<void> Function() _cancel;

  const SseStream(this.events, this.errors, this._cancel);

  /// Cancels the subscription + closes the HTTP socket. Idempotent, so
  /// it's safe to call after the server closes the stream itself.
  Future<void> cancel() => _cancel();
}

/// Opens an SSE subscription against `baseUrl + path`.
///
/// Implementation note: this uses a long-lived `http.Request` (NOT
/// `http.Client.get`, which buffers the whole body) and parses the framing
/// line by line. A blank line terminates an event; `event:` / `data:` are
/// the fields we read; `:`-prefixed comment lines are heartbeats and are
/// ignored. [label] only shapes error messages.
Future<SseStream> openSseStream({
  required String baseUrl,
  required String path,
  required String authHeader,
  required http.Client httpClient,
  required String sdkUserAgent,
  required String label,
  String? playerSecret,
}) async {
  final req = http.Request('GET', Uri.parse('$baseUrl$path'));
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
    throw KratyNetworkError('$label connect failed: $err', err);
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    // Drain the body so the connection doesn't dangle, then surface the
    // error in the same shape the rest of the SDK uses.
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
      // Body wasn't JSON, so fall back to the status code as message.
    }
    throw KratyApiError(
      status: response.statusCode,
      code: (errBody['code'] as String?) ?? 'http_${response.statusCode}',
      message: (errBody['message'] as String?) ?? bodyText,
      details: errBody['details'],
    );
  }

  final eventsCtrl = StreamController<SseEvent>();
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
      eventsCtrl.add(SseEvent(kind: currentEvent, data: asMap));
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
        // Comment / heartbeat: ignore.
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
        // SSE also defines `id` and `retry`, which we don't use.
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

  return SseStream(eventsCtrl.stream, errorsCtrl.stream, cancel);
}
