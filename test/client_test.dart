import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:kraty/kraty.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirror of the TypeScript SDK's `client.test.ts`: the same 17
/// scenarios ported to Dart's `test` package. The HTTP layer is
/// driven by a hand-rolled queueing client (rather than
/// `package:http/testing`'s `MockClient`) so we can assert on the
/// exact request shape including `idempotencyKey` retry preservation.

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
  final List<Object> errors = [];

  FakeClient push(int status, {Object? body, Map<String, String>? headers}) {
    responses.add(() => http.Response(
          body == null ? '' : (body is String ? body : jsonEncode(body)),
          status,
          headers: <String, String>{'content-type': 'application/json', ...?headers},
        ));
    return this;
  }

  FakeClient pushError(Object err) {
    responses.add(() => throw err);
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
      throw StateError('FakeClient: out of responses (request #${calls.length})');
    }
    final factory = responses.removeAt(0);
    final res = factory();
    return http.StreamedResponse(
      Stream.value(res.bodyBytes),
      res.statusCode,
      headers: res.headers,
    );
  }
}

const _apiKey = 'pUUVdrM8.djr4-0Iv9h1JvVNSMZNDmSsSN7lSVq2F9dG6DG4A5uQ';
const _baseUrl = 'https://api.test.kraty.io';

KratyClientOptions _baseOpts(FakeClient client, {String Function()? keyGen}) {
  return KratyClientOptions(
    apiKey: _apiKey,
    baseUrl: _baseUrl,
    httpClient: client,
    generateIdempotencyKey: keyGen,
    retry: const KratyRetryConfig(
      attempts: 3,
      initialDelay: Duration(milliseconds: 1),
      maxDelay: Duration(milliseconds: 5),
      jitter: 0,
    ),
    timeout: const Duration(seconds: 1),
  );
}

void main() {
  group('KratyClient: request layer', () {
    test('sends Authorization: Bearer <key>', () async {
      final fake = FakeClient()..push(200, body: {'ok': true});
      final client = KratyClient(_baseOpts(fake));
      await client.request(method: 'GET', path: '/sdk/v1/ping');
      expect(fake.calls[0].headers['authorization'], 'Bearer $_apiKey');
      client.close();
    });

    test('stamps idempotencyKey on POST when the body has none', () async {
      var counter = 0;
      String gen() => 'idem-${++counter}';
      final fake = FakeClient()..push(201, body: {'data': {'id': 'x'}});
      final client = KratyClient(_baseOpts(fake, keyGen: gen));
      await client.request(method: 'POST', path: '/sdk/v1/foo', body: {'x': 1});
      final decoded = jsonDecode(fake.calls[0].body!) as Map<String, Object?>;
      expect(decoded, {'x': 1, 'idempotencyKey': 'idem-1'});
      client.close();
    });

    test('does NOT stamp idempotencyKey on GET', () async {
      final fake = FakeClient()..push(200, body: <String, Object?>{'data': <Object>[]});
      final client = KratyClient(_baseOpts(fake, keyGen: () => 'never-fires'));
      await client.request(method: 'GET', path: '/sdk/v1/foo');
      expect(fake.calls[0].body, isNull);
      client.close();
    });

    test('preserves a caller-supplied idempotencyKey in the body', () async {
      var counter = 0;
      String gen() => 'idem-${++counter}';
      final fake = FakeClient()..push(201, body: <String, Object?>{'data': <String, Object?>{}});
      final client = KratyClient(_baseOpts(fake, keyGen: gen));
      await client.request(
        method: 'POST',
        path: '/sdk/v1/foo',
        body: <String, Object?>{'idempotencyKey': 'caller-chose-me'},
      );
      final decoded = jsonDecode(fake.calls[0].body!) as Map<String, Object?>;
      expect(decoded['idempotencyKey'], 'caller-chose-me');
      expect(counter, 0, reason: 'auto-gen should not fire when caller supplies key');
      client.close();
    });

    test('throws KratyApiError shaped from { error: { code, message } } on non-2xx', () async {
      final fake = FakeClient()
        ..push(404, body: {
          'error': {'code': 'not_found', 'message': 'leaderboard not found'}
        });
      final client = KratyClient(_baseOpts(fake));
      await expectLater(
        client.request(method: 'GET', path: '/sdk/v1/event-leaderboards/missing'),
        throwsA(
          isA<KratyApiError>()
              .having((e) => e.status, 'status', 404)
              .having((e) => e.code, 'code', 'not_found'),
        ),
      );
      client.close();
    });

    test('retries on 503 and succeeds on the second attempt', () async {
      final fake = FakeClient()
        ..push(503)
        ..push(200, body: {'data': {'ok': true}});
      final client = KratyClient(_baseOpts(fake));
      final res = await client.request(method: 'GET', path: '/sdk/v1/ping');
      expect((res['data']! as Map)['ok'], true);
      expect(fake.calls.length, 2);
      client.close();
    });

    test('preserves the SAME idempotencyKey across retries', () async {
      var counter = 0;
      String gen() => 'idem-${++counter}';
      final fake = FakeClient()
        ..push(503)
        ..push(503)
        ..push(201, body: <String, Object?>{'data': <String, Object?>{}});
      final client = KratyClient(_baseOpts(fake, keyGen: gen));
      await client.request(method: 'POST', path: '/sdk/v1/foo', body: {'x': 1});
      expect(fake.calls.length, 3);
      for (final call in fake.calls) {
        final decoded = jsonDecode(call.body!) as Map<String, Object?>;
        expect(decoded['idempotencyKey'], 'idem-1');
      }
      expect(counter, 1, reason: 'auto-gen fires once; retries reuse the key');
      client.close();
    });

    test('gives up after retry.attempts and throws the last error', () async {
      final fake = FakeClient()
        ..push(503)
        ..push(503)
        ..push(503, body: {
          'error': {'code': 'internal_error', 'message': 'still broken'}
        });
      final client = KratyClient(_baseOpts(fake));
      await expectLater(
        client.request(method: 'GET', path: '/sdk/v1/ping'),
        throwsA(isA<KratyApiError>()),
      );
      expect(fake.calls.length, 3);
      client.close();
    });

    test('honors Retry-After on 429', () async {
      final fake = FakeClient()
        ..push(429, headers: {'retry-after': '0'})
        ..push(200, body: {'data': {'ok': true}});
      final client = KratyClient(_baseOpts(fake));
      final sw = Stopwatch()..start();
      await client.request(method: 'GET', path: '/sdk/v1/ping');
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(500));
      expect(fake.calls.length, 2);
      client.close();
    });

    test('does NOT retry on 4xx other than 408/425/429', () async {
      final fake = FakeClient()
        ..push(404, body: {
          'error': {'code': 'not_found', 'message': 'no such grant'}
        });
      final client = KratyClient(_baseOpts(fake));
      await expectLater(
        client.request(method: 'POST', path: '/sdk/v1/foo', body: {'x': 1}),
        throwsA(isA<KratyApiError>()),
      );
      expect(fake.calls.length, 1);
      client.close();
    });

    test('wraps a network crash as KratyNetworkError after retries exhausted', () async {
      final fake = FakeClient()
        ..pushError(http.ClientException('connect ECONNREFUSED'))
        ..pushError(http.ClientException('connect ECONNREFUSED'));
      final client = KratyClient(KratyClientOptions(
        apiKey: _apiKey,
        baseUrl: _baseUrl,
        httpClient: fake,
        retry: const KratyRetryConfig(
          attempts: 2,
          initialDelay: Duration(milliseconds: 1),
          maxDelay: Duration(milliseconds: 2),
          jitter: 0,
        ),
      ));
      await expectLater(
        client.request(method: 'GET', path: '/sdk/v1/ping'),
        throwsA(isA<KratyNetworkError>()),
      );
      client.close();
    });

    test('exposes onRequest for telemetry hooks', () async {
      final fake = FakeClient()..push(200, body: <String, Object?>{'data': <String, Object?>{}});
      final events = <KratyRequestInfo>[];
      final client = KratyClient(KratyClientOptions(
        apiKey: _apiKey,
        baseUrl: _baseUrl,
        httpClient: fake,
        onRequest: events.add,
        retry: const KratyRetryConfig(attempts: 1),
      ));
      await client.request(method: 'GET', path: '/sdk/v1/ping');
      expect(events.length, 1);
      expect(events[0].status, 200);
      expect(events[0].ok, true);
      client.close();
    });
  });

  group('Kraty facade', () {
    test('wires the resource clients to the shared KratyClient', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'leaderboardId': 'lb_1',
            'mode': 'global',
            'finalized': false,
            'entries': <Object>[],
            'self': null,
          }
        });
      final kraty = Kraty(_baseOpts(fake));
      // Replace the auto-constructed inner client with our fake-backed one.
      // (Kraty's factory creates its own KratyClient, so wire a single fake
      // through by reconstructing manually.)
      final c = KratyClient(_baseOpts(fake));
      final lb = EventLeaderboardsClient(c);
      final board = await lb.read('lb_1', options: const EventLeaderboardReadOptions(limit: 10));
      expect(board.leaderboardId, 'lb_1');
      expect(fake.calls[0].url, contains('/sdk/v1/event-leaderboards/lb_1?limit=10'));
      kraty.close();
      c.close();
    });

    test('lobby_forming surfaces as KratyApiError with isLobbyForming == true', () async {
      final fake = FakeClient()
        ..push(202, body: {
          'error': {'code': 'lobby_forming', 'message': "lobby '...' is filling (1/3)"}
        });
      final c = KratyClient(_baseOpts(fake));
      final events = EventsClient(c);
      Object? caught;
      try {
        await events.start('race', as: 'alice');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<KratyApiError>());
      expect((caught as KratyApiError?)?.isLobbyForming, true);
      c.close();
    });

    test('start() includes the playerContext and auto-stamps idempotencyKey', () async {
      var counter = 0;
      String gen() => 'idem-${++counter}';
      final fake = FakeClient()
        ..push(201, body: {
          'data': {
            'attempt': {
              'id': 'a1',
              'eventId': 'e1',
              'eventWindowId': 'w1',
              'leaderboardId': 'lb1',
              'playerId': 'p1',
              'startedAt': '2026-01-01T00:00:00Z',
              'endsAt': '2026-01-01T00:10:00Z',
              'completedAt': null,
              'metrics': <String, double>{},
              'metricsRaw': <String, double>{},
              'score': 0,
              'status': 'in_progress',
            },
            'leaderboardId': 'lb1',
            'windowEndsAt': '2026-01-01T00:10:00Z',
          }
        });
      final c = KratyClient(_baseOpts(fake, keyGen: gen));
      final events = EventsClient(c);
      await events.start('race', playerContext: {'country': 'PT', 'level': 7}, as: 'alice');
      final body = jsonDecode(fake.calls[0].body!) as Map<String, Object?>;
      expect(body['playerContext'], {'country': 'PT', 'level': 7});
      expect(body['idempotencyKey'], 'idem-1');
      c.close();
    });

    test('progress() surfaces milestonesFired alongside the attempt', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'attempt': {
              'id': 'a1',
              'eventId': 'e1',
              'eventWindowId': 'w1',
              'leaderboardId': 'lb1',
              'playerId': 'p1',
              'startedAt': '2026-01-01T00:00:00Z',
              'endsAt': '2026-01-01T00:10:00Z',
              'completedAt': null,
              'metrics': {'kills': 15.0},
              'metricsRaw': {'kills': 15.0},
              'score': 15.0,
              'status': 'in_progress',
            },
            'milestonesFired': [
              {
                'key': 'kills_15',
                'grants': [
                  {
                    'id': 'g1',
                    'kind': 'reward',
                    'contents': {
                      'entries': [
                        {'type': 'currency', 'currencyKey': 'gold', 'amount': 50}
                      ]
                    },
                    'sourceKind': 'event_milestone',
                    'sourceRefId': 'a1',
                    'parentGrantId': null,
                    'status': 'pending',
                    'rolledAt': '2026-01-01T00:05:00Z',
                    'claimedAt': null,
                    'expiresAt': null,
                    'createdAt': '2026-01-01T00:05:00Z',
                  }
                ],
              }
            ],
          }
        });
      final c = KratyClient(_baseOpts(fake));
      final events = EventsClient(c);
      final out = await events.progress(
        'race',
        'a1',
        const ProgressInput(mode: 'set', metricValue: 15),
        as: 'alice',
      );
      expect(out.attempt.id, 'a1');
      expect(out.milestonesFired, hasLength(1));
      expect(out.milestonesFired[0].key, 'kills_15');
      expect(out.milestonesFired[0].grants, hasLength(1));
      expect(out.milestonesFired[0].grants[0].kind, 'reward');
      expect(out.milestonesFired[0].grants[0].sourceKind, 'event_milestone');
      c.close();
    });

    test('progress() returns an empty milestonesFired list when nothing fires', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'attempt': {
              'id': 'a1',
              'eventId': 'e1',
              'eventWindowId': 'w1',
              'leaderboardId': 'lb1',
              'playerId': 'p1',
              'startedAt': '2026-01-01T00:00:00Z',
              'endsAt': '2026-01-01T00:10:00Z',
              'completedAt': null,
              'metrics': {'kills': 2.0},
              'metricsRaw': {'kills': 2.0},
              'score': 2.0,
              'status': 'in_progress',
            },
            'milestonesFired': <Object?>[],
          }
        });
      final c = KratyClient(_baseOpts(fake));
      final events = EventsClient(c);
      final out = await events.progress(
        'race',
        'a1',
        const ProgressInput(mode: 'increment', metricValue: 1),
        as: 'alice',
      );
      expect(out.milestonesFired, isEmpty);
      c.close();
    });

    test('progress() tolerates a missing milestonesFired field (backend rollback safety)', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'attempt': {
              'id': 'a1',
              'eventId': 'e1',
              'eventWindowId': 'w1',
              'leaderboardId': 'lb1',
              'playerId': 'p1',
              'startedAt': '2026-01-01T00:00:00Z',
              'endsAt': '2026-01-01T00:10:00Z',
              'completedAt': null,
              'metrics': <String, double>{},
              'metricsRaw': <String, double>{},
              'score': 0.0,
              'status': 'in_progress',
            },
            // milestonesFired omitted entirely (older backend)
          }
        });
      final c = KratyClient(_baseOpts(fake));
      final events = EventsClient(c);
      final out = await events.progress(
        'race',
        'a1',
        const ProgressInput(mode: 'set', metricValue: 0),
        as: 'alice',
      );
      expect(out.milestonesFired, isEmpty);
      c.close();
    });

    test('eventLeaderboards.read with includeSelf builds the query string', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'leaderboardId': 'lb_self',
            'mode': 'global',
            'finalized': false,
            'entries': <Object>[],
            'self': {'rank': 4, 'score': 90},
          }
        });
      final c = KratyClient(_baseOpts(fake));
      final lb = EventLeaderboardsClient(c);
      final board = await lb.read(
        'lb_self',
        options: const EventLeaderboardReadOptions(
          limit: 5,
          includeSelf: true,
          externalId: 'alice',
        ),
      );
      expect(board.self?.rank, 4);
      expect(fake.calls[0].url, contains('limit=5'));
      expect(fake.calls[0].url, contains('includeSelf=true'));
      expect(fake.calls[0].url, contains('externalId=alice'));
      c.close();
    });

    test('eventLeaderboards.read with includeSelf defaults externalId to the active player', () async {
      final fake = FakeClient()
        ..push(201, body: {'data': {'secret': 'auto'}})
        ..push(200, body: {
          'data': {
            'leaderboardId': 'lb_self',
            'mode': 'global',
            'finalized': false,
            'entries': <Object>[],
            'self': {'rank': 1, 'score': 100},
          }
        });
      final c = KratyClient(_baseOpts(fake));
      final lb = EventLeaderboardsClient(c);
      await lb.read('lb_self', options: const EventLeaderboardReadOptions(includeSelf: true));
      // First call registered a fresh player, second carries the
      // lazy-minted id as externalId.
      expect(fake.calls[0].url, contains('/register'));
      final selfId = c.activeExternalPlayerId!;
      expect(fake.calls[1].url, contains('includeSelf=true'));
      expect(fake.calls[1].url, contains('externalId=$selfId'));
      c.close();
    });

    test('leaderboards.read hits the keyed shared route', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'key': 'weekly_global',
            'leaderboardId': 'slb_1',
            'scope': 'game',
            'resetCadence': 'weekly',
            'scoreAggregation': 'best',
            'segment': null,
            'period': '2026-06-22T00:00:00Z',
            'entries': [
              {'participantId': 'p1', 'kind': 'player', 'name': 'alice', 'avatar': null, 'score': 42, 'rank': 1, 'isSelf': false}
            ],
            'self': null,
          }
        });
      final c = KratyClient(_baseOpts(fake));
      final lb = LeaderboardsClient(c);
      final board = await lb.read('weekly_global', options: const LeaderboardReadOptions(limit: 10));
      expect(board.key, 'weekly_global');
      expect(board.leaderboardId, 'slb_1');
      expect(board.entries.length, 1);
      expect(fake.calls[0].url, contains('/sdk/v1/leaderboards/weekly_global?limit=10'));
      c.close();
    });

    test('leaderboards.read passes segment + period + includeSelf', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'key': 'weekly_region',
            'leaderboardId': 'slb_2',
            'scope': 'game',
            'resetCadence': 'weekly',
            'scoreAggregation': 'best',
            'segment': 'eu',
            'period': '2026-06-15T00:00:00Z',
            'entries': <Object>[],
            'self': {'rank': 7, 'score': 100},
          }
        });
      final c = KratyClient(_baseOpts(fake));
      final lb = LeaderboardsClient(c);
      final board = await lb.read(
        'weekly_region',
        options: const LeaderboardReadOptions(
          limit: 25,
          segment: 'eu',
          period: '2026-06-15T00:00:00Z',
          includeSelf: true,
          externalId: 'alice',
        ),
      );
      expect(board.segment, 'eu');
      expect(board.self?.rank, 7);
      final url = fake.calls[0].url;
      expect(url, contains('limit=25'));
      expect(url, contains('segment=eu'));
      expect(url, contains('period=2026-06-15T00%3A00%3A00Z'));
      expect(url, contains('includeSelf=true'));
      expect(url, contains('externalId=alice'));
      c.close();
    });

    test('leaderboards.listPeriods decodes newest-first periods', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'key': 'weekly_global',
            'leaderboardId': 'slb_1',
            'currentPeriodStartedAt': '2026-06-22T00:00:00Z',
            'periods': [
              {'periodStartedAt': '2026-06-15T00:00:00Z', 'periodEndedAt': '2026-06-22T00:00:00Z'},
              {'periodStartedAt': '2026-06-08T00:00:00Z', 'periodEndedAt': '2026-06-15T00:00:00Z'},
            ],
          }
        });
      final c = KratyClient(_baseOpts(fake));
      final lb = LeaderboardsClient(c);
      final resp = await lb.listPeriods('weekly_global', limit: 5);
      expect(resp.periods.length, 2);
      expect(resp.periods[0].periodStartedAt, '2026-06-15T00:00:00Z');
      expect(fake.calls[0].url, contains('/sdk/v1/leaderboards/weekly_global/periods?limit=5'));
      c.close();
    });

    test('leaderboards.join posts to the player-scoped join route + parses joined', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'key': 'weekly_global',
            'leaderboardId': 'slb_1',
            'scope': 'game',
            'resetCadence': 'weekly',
            'scoreAggregation': 'best',
            'segment': 'eu',
            'period': '2026-06-22T00:00:00Z',
            'entries': <Object>[],
            'self': {'rank': 12, 'score': 0},
            'joined': true,
          }
        });
      final c = KratyClient(_baseOpts(fake));
      final lb = LeaderboardsClient(c);
      final board = await lb.join('weekly_global', segment: 'eu', limit: 20, as: 'alice');
      expect(board.joined, isTrue);
      expect(board.segment, 'eu');
      expect(board.self?.rank, 12);
      expect(fake.calls[0].method, 'POST');
      expect(fake.calls[0].url,
          '$_baseUrl/sdk/v1/players/alice/leaderboards/weekly_global/join?limit=20');
      final body = jsonDecode(fake.calls[0].body!) as Map<String, Object?>;
      expect(body['segment'], 'eu');
      c.close();
    });

    test('leaderboards.standings builds scope/period/limit/maxSegments query + parses segments', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'key': 'league',
            'leaderboardId': 'slb_9',
            'scope': 'game',
            'resetCadence': 'weekly',
            'scoreAggregation': 'best',
            'period': '2026-06-22T00:00:00Z',
            'segmentsTruncated': true,
            'segments': [
              {
                'segment': 'gold',
                'participated': true,
                'selfRank': 3,
                'entries': [
                  {'participantId': 'p1', 'kind': 'player', 'name': 'alice', 'avatar': null, 'score': 90, 'rank': 1, 'isSelf': false},
                ],
              },
              {
                'segment': 'silver',
                'participated': false,
                'selfRank': null,
                'entries': <Object>[],
              },
            ],
          }
        });
      final c = KratyClient(_baseOpts(fake));
      final lb = LeaderboardsClient(c);
      final standings = await lb.standings(
        'league',
        options: const StandingsReadOptions(
          scope: 'all',
          period: '2026-06-22T00:00:00Z',
          limit: 25,
          maxSegments: 5,
        ),
      );
      expect(standings.key, 'league');
      expect(standings.segmentsTruncated, isTrue);
      expect(standings.segments, hasLength(2));
      expect(standings.segments.first.segment, 'gold');
      expect(standings.segments.first.participated, isTrue);
      expect(standings.segments.first.selfRank, 3);
      expect(standings.segments.first.entries, hasLength(1));
      expect(standings.segments[1].selfRank, isNull);
      final url = fake.calls[0].url;
      expect(url, contains('/sdk/v1/leaderboards/league/standings?'));
      expect(url, contains('scope=all'));
      expect(url, contains('period=2026-06-22T00%3A00%3A00Z'));
      expect(url, contains('limit=25'));
      expect(url, contains('maxSegments=5'));
      c.close();
    });

    test('leaderboards.standings passes explicit externalId for self_segment', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'key': 'league',
            'leaderboardId': 'slb_9',
            'scope': 'game',
            'resetCadence': 'weekly',
            'scoreAggregation': 'best',
            'period': '2026-06-22T00:00:00Z',
            'segmentsTruncated': false,
            'segments': <Object>[],
          }
        });
      final c = KratyClient(_baseOpts(fake));
      final lb = LeaderboardsClient(c);
      await lb.standings(
        'league',
        options: const StandingsReadOptions(scope: 'self_segment', externalId: 'alice'),
      );
      final url = fake.calls[0].url;
      expect(url, contains('scope=self_segment'));
      expect(url, contains('externalId=alice'));
      c.close();
    });

    test('eventLeaderboards.join posts empty body + parses joined', () async {
      final fake = FakeClient()
        ..push(200, body: {
          'data': {
            'leaderboardId': 'lb_1',
            'mode': 'global',
            'finalized': false,
            'entries': <Object>[],
            'self': {'rank': 5, 'score': 0},
            'joined': true,
          }
        });
      final c = KratyClient(_baseOpts(fake));
      final lb = EventLeaderboardsClient(c);
      final board = await lb.join('lb_1', limit: 10, as: 'alice');
      expect(board.joined, isTrue);
      expect(board.self?.rank, 5);
      expect(fake.calls[0].method, 'POST');
      expect(fake.calls[0].url,
          '$_baseUrl/sdk/v1/players/alice/event-leaderboards/lb_1/join?limit=10');
      c.close();
    });

    test('eventLeaderboards.join surfaces 409 conflict on a finalized window', () async {
      final fake = FakeClient()
        ..push(409, body: {
          'error': {'code': 'conflict', 'message': 'window finalized'},
        });
      final c = KratyClient(_baseOpts(fake));
      final lb = EventLeaderboardsClient(c);
      Object? caught;
      try {
        await lb.join('lb_1', as: 'alice');
      } catch (err) {
        caught = err;
      }
      expect(caught, isA<KratyApiError>());
      expect((caught! as KratyApiError).code, 'conflict');
      c.close();
    });
  });
}
