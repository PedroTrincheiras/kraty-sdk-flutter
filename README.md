# kraty (Dart / Flutter client SDK)

Dart / Flutter **client** SDK for the [Kraty](https://kraty.io)
game-events platform. Targets:

- Flutter apps (iOS, Android, web, desktop)
- Pure-Dart tooling and test suites

> 📖 **Full reference + examples:** <https://kraty.io/docs/sdks/flutter>
>
> The docs site has the complete guide: install via git pubspec,
> per-runtime secret stores, every method, SSE streaming, error
> handling. This README is the elevator pitch.

The default `SecretStore` auto-selects per runtime:
`SharedPreferencesSecretStore` inside a Flutter app,
`InMemorySecretStore` in headless Dart contexts where the Flutter
binding isn't initialized.

Wire-format and behavioral parity with [`@kraty/sdk`](../sdk-typescript/)
(the TypeScript reference) and [`Kraty.SDK`](../sdk-unity/) (the C#
port): same idempotency-key auto-generation, same exponential retry
with jitter, same sealed error codes, same adaptive polling helpers.

## Install

The package isn't on pub.dev yet. From a Flutter app inside this
monorepo:

```yaml
# pubspec.yaml
dependencies:
  kraty:
    path: ../../packages/sdk-flutter
```

For a future pub.dev publication: `dart pub add kraty`.

## Quickstart

```dart
import 'package:kraty/kraty.dart';

void main() async {
  final kraty = Kraty(KratyClientOptions(
    apiKey: '<your-client-sdk-key>',
    // Defaults to https://api.kraty.io; override for local/staging.
    baseUrl: 'http://localhost:8080',
  ));

  try {
    // 1) Events available for this player right now.
    final events = await kraty.events.listForPlayer('player_42');

    // 2) Start an attempt.
    final start = await kraty.events.start(
      'player_42',
      events.first.eventKey,
      playerContext: <String, Object?>{'country': 'PT', 'level': 7},
    );

    // 3) Push progress. mode: 'set' writes the value; 'increment' adds.
    await kraty.events.progress(
      'player_42',
      events.first.eventKey,
      start.attempt.id,
      const ProgressInput(mode: 'set', metricValue: 100),
    );

    // 4) Read the leaderboard with self-rank.
    final board = await kraty.leaderboards.read(
      start.leaderboardId,
      options: const LeaderboardReadOptions(
        limit: 50,
        includeSelf: true,
        externalId: 'player_42',
      ),
    );
    print(board.entries.take(3));
    print('self: ${board.self}');

    // 5) Pull + claim pending grants.
    final pending = await kraty.grants.listPending('player_42');
    for (final grant in pending) {
      if (grant.kind == 'reward') {
        await kraty.grants.claim('player_42', grant.id);
      } else if (grant.kind == 'crate') {
        final opened = await kraty.grants.open('player_42', grant.id);
        print('crate rolled: ${opened.contents.contents}');
      }
    }
  } finally {
    kraty.close();
  }
}
```

## Retry + idempotency

Every `POST` / `PUT` / `PATCH` is automatically stamped with an
`idempotencyKey` (a 32-character secure random hex by default) before
the first attempt. Retries reuse the same key, so the server's
idempotency check dedupes a network-replayed call.

Retry config is tunable:

```dart
Kraty(KratyClientOptions(
  apiKey: '...',
  retry: const KratyRetryConfig(
    attempts: 5,
    initialDelay: Duration(milliseconds: 200),
    maxDelay: Duration(seconds: 10),
    jitter: 0.25,
  ),
));
```

`Retry-After` headers (used by the platform's 429 responses) are
honored. Retries fire on `408` / `425` / `429` / `5xx` and on
`http.ClientException` / network failures.

## Error handling

Non-2xx responses throw `KratyApiError`. The `code` field mirrors the
backend's `api/errors.ts` sealed enum (constants exposed on
`KratyErrorCode`).

```dart
import 'package:kraty/kraty.dart';

try {
  await kraty.events.start('alice', 'race');
} on KratyApiError catch (err) {
  if (err.isLobbyForming) {
    // Matchmaking lobby still filling; poll and retry.
    final lobby = await pollLobbyUntilActive(kraty.lobbies, /* lobby id */);
    // ... retry start
  } else {
    switch (err.code) {
      case KratyErrorCode.noActiveWindow:
        print('event is between windows');
      case KratyErrorCode.maxAttemptsReached:
        print('player burned all attempts for this window');
      default:
        rethrow;
    }
  }
} on KratyNetworkError catch (netErr) {
  // Couldn't reach the server at all.
  print('network: ${netErr.message}');
}
```

## Polling helpers

The platform contract is poll-based on the client side. Two helpers
wrap the typical patterns:

```dart
// Pending grants: grows the interval while empty, snaps back to
// `start` as soon as grants land.
final completer = Completer<void>();
unawaited(pollPendingGrants(
  kraty.grants,
  'player_42',
  options: PollPendingGrantsOptions(
    start: const Duration(seconds: 2),
    grow: 1.5,
    max: const Duration(seconds: 30),
    onBatch: (batch) {
      for (final g in batch) {
        // claim / open / queue for UI
      }
    },
  ),
  signal: completer.future,
));

// Later, abort the poller:
completer.complete();

// Lobby: fixed-interval until status != 'forming' or timeout.
final lobby = await pollLobbyUntilActive(kraty.lobbies, lobbyId);
```

## Development

```bash
# From the package root:
flutter pub get
dart analyze
flutter test
```

Tests use a hand-rolled `FakeClient` (extends `http.BaseClient`) and
queue pre-baked `http.Response` objects: no real network IO, no
ports opened.

## File layout

```
packages/sdk-flutter/
  pubspec.yaml              # Dart package manifest
  analysis_options.yaml     # strict-casts, strict-inference, strict-raw-types
  lib/
    kraty.dart              # public API + Kraty facade
    src/
      client.dart           # KratyClient (HTTP, retry, idempotency)
      errors.dart           # KratyApiError, KratyNetworkError, codes
      types.dart            # public DTOs (Attempt, Grant, ...)
      resources.dart        # EventsClient, LeaderboardsClient, ...
  test/
    client_test.dart        # 17 lock-in tests (parity with TS + C# suites)
```
