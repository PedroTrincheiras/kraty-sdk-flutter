import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:kraty/kraty.dart';
import 'package:flutter_test/flutter_test.dart';

/// Resource-client coverage (events.listForPlayer, grants.*,
/// inventory.*, wallet.*, players.register, lobbies.read, polling
/// helpers, X-Player-Secret injection, collectAll, error helpers).
///
/// Uses the same FakeClient pattern as `client_test.dart` so we can
/// assert on outgoing request shape (headers, body, query string)
/// without spinning up a real backend.

class FakeCall {
  FakeCall(this.method, this.url, this.headers, this.body);
  final String method;
  final String url;
  final Map<String, String> headers;
  final String? body;
}

class FakeClient extends http.BaseClient {
  final List<FakeCall> calls = [];
  final List<http.Response Function()> responses = [];

  FakeClient push(int status, {Object? body, Map<String, String>? headers}) {
    responses.add(() => http.Response(
          body == null ? '' : (body is String ? body : jsonEncode(body)),
          status,
          headers: <String, String>{'content-type': 'application/json', ...?headers},
        ));
    return this;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : null;
    final headers = Map<String, String>.fromEntries(
      request.headers.entries.map((e) => MapEntry(e.key.toLowerCase(), e.value)),
    );
    calls.add(FakeCall(
      request.method,
      request.url.toString(),
      headers,
      body == null || body.isEmpty ? null : body,
    ));
    if (responses.isEmpty) {
      throw StateError('FakeClient: out of responses');
    }
    final res = responses.removeAt(0)();
    return http.StreamedResponse(
      Stream.value(res.bodyBytes),
      res.statusCode,
      headers: res.headers,
    );
  }
}

const _apiKey = 'pUUVdrM8.djr4-0Iv9h1JvVNSMZNDmSsSN7lSVq2F9dG6DG4A5uQ';
const _baseUrl = 'https://api.test.kraty.io';

KratyClientOptions _opts(FakeClient client, {String? playerSecret}) {
  return KratyClientOptions(
    apiKey: _apiKey,
    baseUrl: _baseUrl,
    httpClient: client,
    playerSecret: playerSecret,
    generateIdempotencyKey: () => 'fixed-idem',
    retry: const KratyRetryConfig(
      attempts: 1,
      initialDelay: Duration(milliseconds: 1),
      maxDelay: Duration(milliseconds: 5),
      jitter: 0,
    ),
    timeout: const Duration(seconds: 1),
  );
}

void main() {
  group('events.listForPlayer', () {
    test('parses entryCost + entryRequirement + type + leaderboardMode + metrics', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': [
            {
              'eventKey': 'bounty_hunt',
              'name': {'en': 'Bounty Hunt'},
              'windowId': 'w1',
              'startsAt': '2026-06-08T00:00:00Z',
              'endsAt': '2026-06-09T00:00:00Z',
              'leaderboardId': 'lb1',
              'currentAttemptId': null,
              'metadata': {},
              'type': 'single_metric',
              'leaderboardMode': 'global',
              'metrics': [
                {'key': 'bounties', 'target': 5, 'capAtTarget': true},
              ],
              'entryRequirement': null,
              'entryCost': {
                'currencies': [
                  {'key': 'cash', 'amount': 50},
                ],
                'items': [
                  {'key': 'bullet_basic', 'quantity': 1},
                ],
              },
            },
          ],
        });
      final kraty = Kraty(_opts(fake));
      final list = await kraty.events.listForPlayer(as: 'alice');
      expect(list, hasLength(1));
      final e = list.first;
      expect(e.eventKey, 'bounty_hunt');
      expect(e.type, 'single_metric');
      expect(e.leaderboardMode, 'global');
      expect(e.isLobbyMatched, isFalse);
      expect(e.metrics, hasLength(1));
      expect(e.metrics.first['key'], 'bounties');
      expect(e.entryCost, isNotNull);
      expect(e.entryCost!.currencies, hasLength(1));
      expect(e.entryCost!.currencies.first.key, 'cash');
      expect(e.entryCost!.currencies.first.amount, 50);
      expect(e.entryCost!.items, hasLength(1));
      expect(e.entryCost!.items.first.quantity, 1);
      expect(e.entryCost!.isEmpty, isFalse);
      expect(e.entryRequirement, isNull);
      kraty.close();
    });

    test('isLobbyMatched true when leaderboardMode is lobby_matched', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': [
            {
              'eventKey': 'quick_brawl',
              'name': 'Quick Brawl',
              'windowId': 'w',
              'startsAt': '',
              'endsAt': '',
              'leaderboardId': null,
              'currentAttemptId': null,
              'metadata': {},
              'type': 'single_metric',
              'leaderboardMode': 'lobby_matched',
              'metrics': const <Object>[],
              'entryRequirement': null,
              'entryCost': null,
            },
          ],
        });
      final kraty = Kraty(_opts(fake));
      final list = await kraty.events.listForPlayer(as: 'alice');
      expect(list.first.isLobbyMatched, isTrue);
      kraty.close();
    });
  });

  group('players.register', () {
    test('POST with empty body returns PlayerRegistration', () async {
      final fake = FakeClient()
        ..push(201, body: {
          'data': {
            'playerId': 'pl-1',
            'externalPlayerId': 'alice',
            'secret': 'super-secret',
            'secretPrefix': 'super-se',
            'registeredAt': '2026-06-08T17:00:00Z',
          },
        });
      final kraty = Kraty(_opts(fake));
      final reg = await kraty.players.register('alice');
      expect(reg.secret, 'super-secret');
      expect(reg.externalPlayerId, 'alice');
      expect(reg.secretPrefix, 'super-se');
      expect(fake.calls.single.url, '$_baseUrl/sdk/v1/players/alice/register');
      expect(fake.calls.single.method, 'POST');
      kraty.close();
    });

    test('force=true appends ?force=true to the URL', () async {
      final fake = FakeClient()
        ..push(201, body: {
          'data': {
            'playerId': 'pl-1',
            'externalPlayerId': 'alice',
            'secret': 'rotated',
            'secretPrefix': 'rotated_',
            'registeredAt': '',
          },
        });
      final kraty = Kraty(_opts(fake));
      await kraty.players.register('alice', force: true);
      expect(fake.calls.single.url,
          '$_baseUrl/sdk/v1/players/alice/register?force=true');
      kraty.close();
    });

    test('409 surfaces as KratyApiError.isPlayerAlreadyRegistered', () async {
      final fake = FakeClient()
        ..push(409, body: {
          'error': {
            'code': 'player_already_registered',
            'message': 'already registered',
          },
        });
      final kraty = Kraty(_opts(fake));
      Object? caught;
      try {
        await kraty.players.register('alice');
      } catch (err) {
        caught = err;
      }
      expect(caught, isA<KratyApiError>());
      expect((caught! as KratyApiError).isPlayerAlreadyRegistered, isTrue);
      expect((caught as KratyApiError).code,
          KratyErrorCode.playerAlreadyRegistered);
      kraty.close();
    });
  });

  group('X-Player-Secret header injection', () {
    test('sent on every request when client has playerSecret', () async {
      final fake = FakeClient()
        ..push(200, body: {'data': []});
      final kraty = Kraty(_opts(fake, playerSecret: 'my-secret'));
      await kraty.events.listForPlayer(as: 'alice');
      expect(fake.calls.single.headers['x-player-secret'], 'my-secret');
      kraty.close();
    });

    test('absent when client has no playerSecret', () async {
      final fake = FakeClient()
        ..push(200, body: {'data': []});
      final kraty = Kraty(_opts(fake));
      await kraty.events.listForPlayer(as: 'alice');
      expect(fake.calls.single.headers.containsKey('x-player-secret'), isFalse);
      kraty.close();
    });

    test('absent when playerSecret is empty string', () async {
      final fake = FakeClient()
        ..push(200, body: {'data': []});
      final kraty = Kraty(_opts(fake, playerSecret: ''));
      await kraty.events.listForPlayer(as: 'alice');
      expect(fake.calls.single.headers.containsKey('x-player-secret'), isFalse);
      kraty.close();
    });
  });

  group('grants.* + collectAll', () {
    test('listPending parses Grant list', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': [
            {
              'id': 'g1',
              'kind': 'reward',
              'contents': {'entries': []},
              'sourceKind': 'event_completion',
              'sourceRefId': null,
              'parentGrantId': null,
              'status': 'pending',
              'rolledAt': null,
              'claimedAt': null,
              'expiresAt': null,
              'createdAt': '2026-06-08T00:00:00Z',
            },
          ],
        });
      final kraty = Kraty(_opts(fake));
      final pending = await kraty.grants.listPending(as: 'alice');
      expect(pending, hasLength(1));
      expect(pending.first.id, 'g1');
      expect(pending.first.kind, 'reward');
      kraty.close();
    });

    test('collectAll opens crates + claims rewards in one sweep', () async {
      final fake = FakeClient()
        // listPending → 1 crate + 1 reward
        ..push(200, body: {
          'data': [
            {
              'id': 'crate-1',
              'kind': 'crate',
              'contents': {'crateItemKey': 'mystery'},
              'sourceKind': 'event_completion',
              'sourceRefId': null,
              'parentGrantId': null,
              'status': 'pending',
              'rolledAt': null,
              'claimedAt': null,
              'expiresAt': null,
              'createdAt': '',
            },
            {
              'id': 'reward-1',
              'kind': 'reward',
              'contents': {'entries': [{'type': 'currency', 'currencyKey': 'cash', 'amount': 100}]},
              'sourceKind': 'event_completion',
              'sourceRefId': null,
              'parentGrantId': null,
              'status': 'pending',
              'rolledAt': null,
              'claimedAt': null,
              'expiresAt': null,
              'createdAt': '',
            },
          ],
        })
        // open crate-1
        ..push(200, body: {
          'data': {
            'crate': {
              'id': 'crate-1',
              'kind': 'crate',
              'contents': {},
              'sourceKind': 'event_completion',
              'sourceRefId': null,
              'parentGrantId': null,
              'status': 'claimed',
              'rolledAt': '',
              'claimedAt': '',
              'expiresAt': null,
              'createdAt': '',
            },
            'contents': {
              'id': 'rolled-1',
              'kind': 'reward',
              'contents': {'entries': []},
              'sourceKind': 'crate_open',
              'sourceRefId': 'crate-1',
              'parentGrantId': 'crate-1',
              'status': 'pending',
              'rolledAt': '',
              'claimedAt': null,
              'expiresAt': null,
              'createdAt': '',
            },
          },
        })
        // claim reward-1
        ..push(200, body: {
          'data': {
            'id': 'reward-1',
            'kind': 'reward',
            'contents': {'entries': []},
            'sourceKind': 'event_completion',
            'sourceRefId': null,
            'parentGrantId': null,
            'status': 'claimed',
            'rolledAt': '',
            'claimedAt': '',
            'expiresAt': null,
            'createdAt': '',
          },
        });
      final kraty = Kraty(_opts(fake));
      final result = await kraty.grants.collectAll(as: 'alice');
      expect(result.processed, 2);
      expect(result.opened, hasLength(1));
      expect(result.opened.first.contents.id, 'rolled-1');
      expect(result.claimed, hasLength(1));
      expect(result.claimed.first.id, 'reward-1');
      expect(result.failures, isEmpty);
      expect(result.hasFailures, isFalse);
      // Three calls total: listPending, open, claim
      expect(fake.calls, hasLength(3));
      expect(fake.calls[0].url, contains('/pending-grants'));
      expect(fake.calls[1].url, contains('/crates/crate-1/open'));
      expect(fake.calls[2].url, contains('/grants/reward-1/claim'));
      kraty.close();
    });

    test('collectAll surfaces per-grant failures without aborting', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': [
            {
              'id': 'good',
              'kind': 'reward',
              'contents': {'entries': []},
              'sourceKind': 'event_completion',
              'sourceRefId': null, 'parentGrantId': null, 'status': 'pending',
              'rolledAt': null, 'claimedAt': null, 'expiresAt': null, 'createdAt': '',
            },
            {
              'id': 'bad',
              'kind': 'reward',
              'contents': {'entries': []},
              'sourceKind': 'event_completion',
              'sourceRefId': null, 'parentGrantId': null, 'status': 'pending',
              'rolledAt': null, 'claimedAt': null, 'expiresAt': null, 'createdAt': '',
            },
          ],
        })
        ..push(200, body: {
          'data': {
            'id': 'good', 'kind': 'reward', 'contents': {'entries': []},
            'sourceKind': '', 'sourceRefId': null, 'parentGrantId': null,
            'status': 'claimed', 'rolledAt': '', 'claimedAt': '',
            'expiresAt': null, 'createdAt': '',
          },
        })
        // 2nd claim fails
        ..push(500, body: {
          'error': {'code': 'internal_error', 'message': 'oops'},
        });
      final kraty = Kraty(_opts(fake));
      final result = await kraty.grants.collectAll(as: 'alice');
      expect(result.processed, 2);
      expect(result.claimed, hasLength(1));
      expect(result.claimed.first.id, 'good');
      expect(result.failures, hasLength(1));
      expect(result.failures.first.grant.id, 'bad');
      expect(result.hasFailures, isTrue);
      kraty.close();
    });
  });

  group('inventory.* + wallet.*', () {
    test('inventory.list parses { items: [...] }', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'items': [
              {
                'itemKey': 'bullet_basic',
                'quantity': 5,
                'metadata': {},
                'createdAt': '',
                'updatedAt': '',
              },
            ],
          },
        });
      final kraty = Kraty(_opts(fake));
      final inv = await kraty.inventory.list(as: 'alice');
      expect(inv, hasLength(1));
      expect(inv.first.itemKey, 'bullet_basic');
      expect(inv.first.quantity, 5);
      kraty.close();
    });

    test('inventory.consume sends quantity + auto-idem + parses applied', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {'itemKey': 'bullet_basic', 'quantity': 4, 'applied': true},
        });
      final kraty = Kraty(_opts(fake));
      final res = await kraty.inventory.consume(
        'bullet_basic',
        const ConsumeItemInput(quantity: 1),
        as: 'alice',
      );
      expect(res.applied, isTrue);
      expect(res.quantity, 4);
      final body = jsonDecode(fake.calls.single.body!) as Map<String, Object?>;
      expect(body['quantity'], 1);
      expect(body['idempotencyKey'], 'fixed-idem');
      kraty.close();
    });

    test('wallet.list parses { wallet: [...] }', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'wallet': [
              {
                'economyKey': 'cash', 'balance': 200, 'metadata': {},
                'createdAt': '', 'updatedAt': '',
              },
            ],
          },
        });
      final kraty = Kraty(_opts(fake));
      final w = await kraty.wallet.list(as: 'alice');
      expect(w, hasLength(1));
      expect(w.first.economyKey, 'cash');
      expect(w.first.balance, 200);
      kraty.close();
    });

    test('wallet.debit on insufficient → isInsufficientEntryCost stays false', () async {
      final fake = FakeClient()
        ..push(409, body: {
          'error': {'code': 'conflict', 'message': 'insufficient balance'},
        });
      final kraty = Kraty(_opts(fake));
      Object? caught;
      try {
        await kraty.wallet.debit(
          'cash',
          const DebitWalletInput(amount: 9999),
          as: 'alice',
        );
      } catch (err) {
        caught = err;
      }
      expect(caught, isA<KratyApiError>());
      final err = caught! as KratyApiError;
      expect(err.code, 'conflict');
      // insufficient_entry_cost is a separate error code from
      // wallet-debit's generic insufficient, so verify the helper
      // doesn't mis-classify.
      expect(err.isInsufficientEntryCost, isFalse);
      kraty.close();
    });

    test('events.start on insufficient cost → isInsufficientEntryCost true', () async {
      final fake = FakeClient()
        ..push(402, body: {
          'error': {
            'code': 'insufficient_entry_cost',
            'message': 'not enough cash to enter, need 50',
          },
        });
      final kraty = Kraty(_opts(fake));
      Object? caught;
      try {
        await kraty.events.start('bounty_hunt', as: 'alice');
      } catch (err) {
        caught = err;
      }
      expect(caught, isA<KratyApiError>());
      final err = caught! as KratyApiError;
      expect(err.status, 402);
      expect(err.isInsufficientEntryCost, isTrue);
      expect(err.isPlayerSecretInvalid, isFalse);
      kraty.close();
    });

    test('any 401 player_secret_invalid → isPlayerSecretInvalid true', () async {
      final fake = FakeClient()
        ..push(401, body: {
          'error': {
            'code': 'player_secret_invalid',
            'message': 'invalid player secret',
          },
        });
      final kraty = Kraty(_opts(fake));
      Object? caught;
      try {
        await kraty.inventory.list(as: 'alice');
      } catch (err) {
        caught = err;
      }
      final err = caught! as KratyApiError;
      expect(err.isPlayerSecretInvalid, isTrue);
      expect(err.isLobbyForming, isFalse);
      kraty.close();
    });
  });

  group('lobbies.read', () {
    test('parses botSlots projection field', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'id': 'l1',
            'eventId': 'e1',
            'eventWindowId': 'w1',
            'leaderboardId': null,
            'mode': 'auto',
            'status': 'forming',
            'capacity': 4,
            'fillBy': '2026-06-08T17:00:30Z',
            'participantCount': 1,
            'botSlots': 2,
            'startedAt': null,
            'endsAt': null,
          },
        });
      final kraty = Kraty(_opts(fake));
      final lobby = await kraty.lobbies.read('l1');
      expect(lobby.id, 'l1');
      expect(lobby.capacity, 4);
      expect(lobby.participantCount, 1);
      expect(lobby.botSlots, 2);
      expect(lobby.filledSlots, 3);
      expect(lobby.status, 'forming');
      kraty.close();
    });

    test('filledSlots clamps to capacity if server skew over-counts', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'id': 'l1', 'eventId': 'e1', 'eventWindowId': 'w1',
            'leaderboardId': null, 'mode': 'auto', 'status': 'forming',
            'capacity': 4, 'fillBy': '', 'participantCount': 3,
            'botSlots': 5, 'startedAt': null, 'endsAt': null,
          },
        });
      final kraty = Kraty(_opts(fake));
      final lobby = await kraty.lobbies.read('l1');
      expect(lobby.filledSlots, 4); // capped at capacity, not 3 + 5
      kraty.close();
    });
  });

  group('Kraty lazy identity (Option B)', () {
    KratyClientOptions optsWithStore(FakeClient client, SecretStore store) =>
        KratyClientOptions(
          apiKey: _apiKey,
          baseUrl: _baseUrl,
          httpClient: client,
          secretStore: store,
          generateIdempotencyKey: () => 'fixed-idem',
          retry: const KratyRetryConfig(
            attempts: 1,
            initialDelay: Duration(milliseconds: 1),
            maxDelay: Duration(milliseconds: 5),
            jitter: 0,
          ),
          timeout: const Duration(seconds: 1),
        );

    test('auto-registers a fresh player on the first bare call', () async {
      final fake = FakeClient()
        ..push(201, body: {'data': {'secret': 'auto-secret'}})
        ..push(200, body: {'data': []});
      final store = InMemorySecretStore();
      final kraty = Kraty(optsWithStore(fake, store));
      await kraty.grants.listPending();
      // First call lazy-registers with a fresh kp_ id.
      expect(fake.calls[0].url, matches(
        RegExp(r'/sdk/v1/players/kp_[A-Za-z0-9_-]+/register$'),
      ));
      // Second call reuses the freshly-minted id without re-registering.
      expect(fake.calls[1].url, matches(
        RegExp(r'/sdk/v1/players/kp_[A-Za-z0-9_-]+/pending-grants$'),
      ));
      expect(fake.calls[1].headers['x-player-secret'], 'auto-secret');
      expect(kraty.activeExternalPlayerId, startsWith('kp_'));
      kraty.close();
    });

    test('restores a persisted identity without re-registering', () async {
      final fake = FakeClient()..push(200, body: {'data': []});
      final store = InMemorySecretStore();
      await store.write('alice', 'cached-secret');
      await store.writeActiveExternalPlayerId('alice');
      final kraty = Kraty(optsWithStore(fake, store));
      await kraty.grants.listPending();
      expect(fake.calls, hasLength(1));
      expect(fake.calls[0].url, contains('/players/alice/pending-grants'));
      expect(fake.calls[0].headers['x-player-secret'], 'cached-secret');
      kraty.close();
    });

    test('constructor identity skips the register round-trip', () async {
      final fake = FakeClient()..push(200, body: {'data': []});
      final store = InMemorySecretStore();
      final kraty = Kraty(KratyClientOptions(
        apiKey: _apiKey,
        baseUrl: _baseUrl,
        httpClient: fake,
        playerSecret: 'ctor-secret',
        activeExternalPlayerId: 'alice',
        secretStore: store,
        retry: const KratyRetryConfig(attempts: 1),
      ));
      await kraty.grants.listPending();
      expect(fake.calls, hasLength(1));
      expect(fake.calls[0].url, contains('/players/alice/pending-grants'));
      expect(fake.calls[0].headers['x-player-secret'], 'ctor-secret');
      kraty.close();
    });

    test('opts.as overrides the active player id without resolving identity', () async {
      final fake = FakeClient()..push(200, body: {'data': []});
      final store = InMemorySecretStore();
      final kraty = Kraty(optsWithStore(fake, store));
      await kraty.grants.listPending(as: 'bob');
      expect(fake.calls[0].url, contains('/players/bob/pending-grants'));
      // `as:` is the server-side-tooling escape hatch; it skips
      // identity resolution entirely, so no lazy register fires.
      expect(fake.calls, hasLength(1));
      expect(kraty.activeExternalPlayerId, isNull);
      kraty.close();
    });

    test('concurrent first-touch shares one register call', () async {
      final fake = FakeClient()
        ..push(201, body: {'data': {'secret': 'shared-secret'}})
        ..push(200, body: {'data': []})
        ..push(200, body: {'data': []});
      final store = InMemorySecretStore();
      final kraty = Kraty(optsWithStore(fake, store));
      final results = await Future.wait<List<Object?>>([
        kraty.grants.listPending(),
        kraty.grants.listPending(),
      ]);
      expect(results, hasLength(2));
      // 1 register + 2 pending-grants = 3 calls. NOT 4 (no double-register).
      expect(fake.calls, hasLength(3));
      expect(fake.calls[0].url, contains('/register'));
      kraty.close();
    });

    test('signIn installs an explicit identity and persists it', () async {
      final fake = FakeClient()..push(200, body: {'data': []});
      final store = InMemorySecretStore();
      final kraty = Kraty(optsWithStore(fake, store));
      await kraty.signIn(externalPlayerId: 'eve', secret: 'eve-secret');
      expect(kraty.activeExternalPlayerId, 'eve');
      expect(await store.read('eve'), 'eve-secret');
      expect(await store.readActiveExternalPlayerId(), 'eve');
      await kraty.grants.listPending();
      expect(fake.calls.single.url, contains('/players/eve/pending-grants'));
      expect(fake.calls.single.headers['x-player-secret'], 'eve-secret');
      kraty.close();
    });

    test('logout clears the persisted identity', () async {
      final fake = FakeClient()
        ..push(201, body: {'data': {'secret': 'fresh'}});
      final store = InMemorySecretStore();
      final kraty = Kraty(optsWithStore(fake, store));
      final id = (await kraty.ensureIdentity()).externalPlayerId;
      expect(await store.read(id), 'fresh');
      expect(kraty.activeExternalPlayerId, id);
      await kraty.logout();
      expect(kraty.activeExternalPlayerId, isNull);
      expect(await store.read(id), isNull);
      expect(await store.readActiveExternalPlayerId(), isNull);
      kraty.close();
    });
  });

  group('friends.*', () {
    test('list unwraps { friends: [...] } with identity + presence', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'friends': [
              {
                'externalPlayerId': 'bob',
                'displayIdentity': {'name': 'Bob', 'avatar': null, 'country': 'PT'},
                'friendsSince': '2026-06-08T00:00:00Z',
                'online': true,
                'lastActiveAt': '2026-06-08T17:00:00Z',
                'status': 'in_match',
              },
            ],
          },
        });
      final kraty = Kraty(_opts(fake));
      final friends = await kraty.friends.list(as: 'alice');
      expect(friends, hasLength(1));
      expect(friends.first.externalPlayerId, 'bob');
      expect(friends.first.displayIdentity?.name, 'Bob');
      expect(friends.first.displayIdentity?.country, 'PT');
      expect(friends.first.online, isTrue);
      expect(friends.first.status, 'in_match');
      expect(fake.calls.single.url, '$_baseUrl/sdk/v1/players/alice/friends');
      kraty.close();
    });

    test('add with friendCode returns pending request', () async {
      final fake = FakeClient()
        ..push(201, body: {
          'data': {
            'status': 'pending',
            'request': {
              'requestId': 'req-1',
              'direction': 'outgoing',
              'player': {
                'externalPlayerId': 'carol',
                'displayIdentity': {'name': 'Carol'},
              },
              'createdAt': '2026-06-08T00:00:00Z',
            },
          },
        });
      final kraty = Kraty(_opts(fake));
      final res = await kraty.friends.add(
        FriendTarget.byCode('ABC123'),
        as: 'alice',
      );
      expect(res.status, 'pending');
      expect(res.request?.requestId, 'req-1');
      expect(res.request?.direction, 'outgoing');
      expect(res.request?.player.externalPlayerId, 'carol');
      expect(res.friend, isNull);
      final body = jsonDecode(fake.calls.single.body!) as Map<String, Object?>;
      expect(body['friendCode'], 'ABC123');
      expect(body.containsKey('externalPlayerId'), isFalse);
      expect(
        fake.calls.single.url,
        '$_baseUrl/sdk/v1/players/alice/friends/requests',
      );
      kraty.close();
    });

    test('add reciprocal auto-accept returns friend', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'status': 'accepted',
            'friend': {
              'externalPlayerId': 'dave',
              'displayIdentity': {'name': 'Dave'},
              'friendsSince': '2026-06-08T00:00:00Z',
              'online': false,
              'lastActiveAt': null,
              'status': null,
            },
          },
        });
      final kraty = Kraty(_opts(fake));
      final res = await kraty.friends.add(
        FriendTarget.byExternalPlayerId('dave'),
        as: 'alice',
      );
      expect(res.status, 'accepted');
      expect(res.friend?.externalPlayerId, 'dave');
      expect(res.request, isNull);
      final body = jsonDecode(fake.calls.single.body!) as Map<String, Object?>;
      expect(body['externalPlayerId'], 'dave');
      kraty.close();
    });

    test('heartbeat sends status + parses presence', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'online': true,
            'lastActiveAt': '2026-06-08T17:00:00Z',
            'status': 'lobby',
          },
        });
      final kraty = Kraty(_opts(fake));
      final presence = await kraty.friends.heartbeat(status: 'lobby', as: 'alice');
      expect(presence.online, isTrue);
      expect(presence.status, 'lobby');
      final body = jsonDecode(fake.calls.single.body!) as Map<String, Object?>;
      expect(body['status'], 'lobby');
      expect(fake.calls.single.method, 'POST');
      expect(fake.calls.single.url, '$_baseUrl/sdk/v1/players/alice/presence');
      kraty.close();
    });

    test('search unwraps { results: [...] } and sends q + limit', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'results': [
              {
                'externalPlayerId': 'eve',
                'displayIdentity': {'name': 'Eve'},
                'relationship': 'request_incoming',
              },
            ],
          },
        });
      final kraty = Kraty(_opts(fake));
      final results = await kraty.friends.search('ev', limit: 10, as: 'alice');
      expect(results, hasLength(1));
      expect(results.first.externalPlayerId, 'eve');
      expect(results.first.relationship, 'request_incoming');
      expect(fake.calls.single.url,
          '$_baseUrl/sdk/v1/players/alice/friends/search?q=ev&limit=10');
      kraty.close();
    });

    test('decline / cancelRequest / remove / unblock hit the right verbs', () async {
      final fake = FakeClient()
        ..push(200, body: {'data': {'declined': true}})
        ..push(200, body: {'data': {'cancelled': true}})
        ..push(200, body: {'data': {'removed': true}})
        ..push(200, body: {'data': {'unblocked': true}});
      final kraty = Kraty(_opts(fake));
      await kraty.friends.decline('req-1', as: 'alice');
      await kraty.friends.cancelRequest('req-2', as: 'alice');
      await kraty.friends.remove('bob', as: 'alice');
      await kraty.friends.unblock('carol', as: 'alice');
      expect(fake.calls[0].method, 'POST');
      expect(fake.calls[0].url,
          '$_baseUrl/sdk/v1/players/alice/friends/requests/req-1/decline');
      expect(fake.calls[1].method, 'DELETE');
      expect(fake.calls[1].url,
          '$_baseUrl/sdk/v1/players/alice/friends/requests/req-2');
      expect(fake.calls[2].method, 'DELETE');
      expect(fake.calls[2].url, '$_baseUrl/sdk/v1/players/alice/friends/bob');
      expect(fake.calls[3].method, 'DELETE');
      expect(fake.calls[3].url, '$_baseUrl/sdk/v1/players/alice/blocks/carol');
      kraty.close();
    });
  });

  group('InMemorySecretStore', () {
    test('read/write/remove roundtrip', () async {
      final store = InMemorySecretStore();
      expect(await store.read('alice'), isNull);
      await store.write('alice', 'secret-1');
      expect(await store.read('alice'), 'secret-1');
      await store.write('alice', 'secret-2');
      expect(await store.read('alice'), 'secret-2');
      await store.remove('alice');
      expect(await store.read('alice'), isNull);
    });

    test('keys are isolated per externalPlayerId', () async {
      final store = InMemorySecretStore();
      await store.write('alice', 'a');
      await store.write('bob', 'b');
      expect(await store.read('alice'), 'a');
      expect(await store.read('bob'), 'b');
      await store.remove('alice');
      expect(await store.read('bob'), 'b'); // bob unaffected
    });
  });

}
