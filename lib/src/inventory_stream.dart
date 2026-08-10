import 'dart:async';

import 'package:http/http.dart' as http;

import 'sse.dart';

/// Live feed of everything that touches a player's items, wallet, and
/// grants — no matter who caused it.
///
/// Before this, a game only saw changes it made itself: a reward granted
/// from the dashboard, a currency credited by the studio's backend, or an
/// event payout landed in the database and the running client kept showing
/// stale numbers until the next launch.

/// Who caused a change. Lets a client skip the echo of its own writes.
class InventoryEventOrigin {
  static const String client = 'client';
  static const String server = 'server';
  static const String admin = 'admin';
  static const String engine = 'engine';
}

/// One event off the inventory stream. [kind] is the SSE `event:` line:
///
///   - `ready`             handshake, once the subscription is wired
///   - `inventory_changed` an item quantity moved
///   - `wallet_changed`    a currency / progression balance moved
///   - `grant_created`     a reward became claimable
///
/// [data] is the parsed payload. The typed getters below cover the common
/// fields; read [data] directly for anything a newer backend adds.
class InventoryStreamEvent {
  final String kind;
  final Map<String, Object?> data;

  const InventoryStreamEvent({required this.kind, required this.data});

  /// `client` / `server` / `admin` / `engine`; empty for `ready`.
  String get origin => _str('origin');

  /// Set on `inventory_changed`.
  String get itemKey => _str('itemKey');

  /// Set on `wallet_changed`.
  String get economyKey => _str('economyKey');

  /// Signed change; negative for a consume. 0 when not applicable.
  int get delta => _int('delta');

  /// Quantity AFTER the change (`inventory_changed`).
  int get quantity => _int('quantity');

  /// Balance AFTER the change (`wallet_changed`).
  int get balance => _int('balance');

  /// Ledger reason (`grant_deposit`, `consume`, `admin_grant`, …).
  String get reason => _str('reason');

  /// Set on `grant_created`; claim it with `grants.collectAll()`.
  String get grantId => _str('grantId');

  /// True when this event is the echo of a write the client itself made.
  bool get isOwnWrite => origin == InventoryEventOrigin.client;

  String _str(String key) {
    final v = data[key];
    return v is String ? v : '';
  }

  int _int(String key) {
    final v = data[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }
}

/// Handle to an active inventory subscription. Call [cancel] to stop.
class InventoryStream {
  /// Server-pushed events. Single-subscriber.
  final Stream<InventoryStreamEvent> events;

  /// Transport failures. The SDK does NOT auto-reconnect; listen here and
  /// re-invoke `inventory.live()` after a backoff if you want resumption.
  final Stream<Object> errors;

  final Future<void> Function() _cancel;

  const InventoryStream._(this.events, this.errors, this._cancel);

  /// Cancels the subscription + closes the HTTP socket. Idempotent.
  Future<void> cancel() => _cancel();
}

/// Opens an SSE subscription to a player's inventory / wallet / grants.
/// Does NOT auto-reconnect.
Future<InventoryStream> openInventoryStream({
  required String baseUrl,
  required String externalPlayerId,
  required String authHeader,
  required http.Client httpClient,
  required String sdkUserAgent,
  String? playerSecret,
}) async {
  final raw = await openSseStream(
    baseUrl: baseUrl,
    path: '/sdk/v1/players/${Uri.encodeComponent(externalPlayerId)}/inventory/stream',
    authHeader: authHeader,
    httpClient: httpClient,
    sdkUserAgent: sdkUserAgent,
    label: 'inventory stream',
    playerSecret: playerSecret,
  );
  return InventoryStream._(
    raw.events.map((e) => InventoryStreamEvent(kind: e.kind, data: e.data)),
    raw.errors,
    raw.cancel,
  );
}
