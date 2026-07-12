import 'package:kraty/kraty.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirror of the TypeScript SDK's `finalization.test.ts`, covering the finalization
/// catch-up (docs/05b): the single-writer invariant, the SSE + catch-up
/// dedupe, the persisted session-vs-window reason, and dismiss/clearReported.

MembershipRef get _ref =>
    MembershipRef.eventLeaderboard('lb-1', eventKey: 'daily');

({FinalizationTracker tracker, List<FinalizationResult> fired}) _make({
  bool finalized = false,
  String? reason,
  SelfEntry? self,
}) {
  final store = InMemoryMembershipStore();
  final tracker = FinalizationTracker(
    store: store,
    getActivePlayerId: () async => 'p1',
    readEventLeaderboard: (_) async => EventLeaderboardStatus(
      finalized: finalized,
      reason: reason,
      self: self ?? const SelfEntry(rank: 3, score: 42),
    ),
  );
  final fired = <FinalizationResult>[];
  tracker.onFinalized(fired.add);
  return (tracker: tracker, fired: fired);
}

void main() {
  test('track is an idempotent upsert', () async {
    final store = InMemoryMembershipStore();
    final tracker = FinalizationTracker(
      store: store,
      getActivePlayerId: () async => 'p1',
      readEventLeaderboard: (_) async => null,
    );
    await tracker.track(_ref);
    await tracker.track(_ref);
    final entries = await store.load('p1');
    expect(entries, hasLength(1));
    expect(entries[0].status, MembershipStatus.active);
  });

  test('SSE path writes the registry AND fires once', () async {
    final m = _make();
    await m.tracker.track(_ref);
    await m.tracker.onStreamFinalized('lb-1', {
      'reason': FinalizationReason.sessionTerminated,
    });
    expect(m.fired, hasLength(1));
    expect(m.fired[0].reason, FinalizationReason.sessionTerminated);
  });

  test('catch-up does not re-fire what the SSE resolved', () async {
    final m = _make(finalized: true, reason: FinalizationReason.windowClosed);
    await m.tracker.track(_ref);
    await m.tracker.onStreamFinalized('lb-1', {
      'reason': FinalizationReason.windowClosed,
    });
    expect(m.fired, hasLength(1));
    final newly = await m.tracker.checkFinalizations();
    expect(newly, isEmpty);
    expect(m.fired, hasLength(1));
  });

  test('catch-up threads the persisted reason (session vs window)', () async {
    final s = _make(finalized: true, reason: FinalizationReason.sessionTerminated);
    await s.tracker.track(_ref);
    final sr = await s.tracker.checkFinalizations();
    expect(sr[0].reason, FinalizationReason.sessionTerminated);

    final w = _make(finalized: true, reason: FinalizationReason.windowClosed);
    await w.tracker.track(_ref);
    final wr = await w.tracker.checkFinalizations();
    expect(wr[0].reason, FinalizationReason.windowClosed);
  });

  test('catch-up falls back to finalized without a reason', () async {
    final m = _make(finalized: true, reason: null);
    await m.tracker.track(_ref);
    final out = await m.tracker.checkFinalizations();
    expect(out[0].reason, FinalizationReason.finalized);
  });

  test('catch-up fires once, dedupes, ignores active boards', () async {
    final m = _make(finalized: true, self: const SelfEntry(rank: 2, score: 99));
    await m.tracker.track(_ref);
    final first = await m.tracker.checkFinalizations();
    expect(first, hasLength(1));
    expect(first[0].self!.rank, 2);
    expect(first[0].eventKey, 'daily');
    final second = await m.tracker.checkFinalizations();
    expect(second, isEmpty);
    expect(m.fired, hasLength(1));
  });

  test('dismiss removes a membership so it never resurfaces', () async {
    final m = _make(finalized: true);
    await m.tracker.track(_ref);
    await m.tracker.dismiss(_ref);
    expect(await m.tracker.checkFinalizations(), isEmpty);
  });

  test('clearReported drops delivered entries but keeps active', () async {
    final m = _make(finalized: true);
    await m.tracker.track(_ref);
    await m.tracker.track(MembershipRef.eventLeaderboard('lb-2'));
    await m.tracker.onStreamFinalized('lb-1', {
      'reason': FinalizationReason.windowClosed,
    });
    final removed = await m.tracker.clearReported();
    expect(removed, 1);
  });

  test('concurrent SSE + checkFinalizations resolve exactly once', () async {
    final m = _make(finalized: true);
    await m.tracker.track(_ref);
    await Future.wait([
      m.tracker.onStreamFinalized('lb-1', {
        'reason': FinalizationReason.sessionTerminated,
      }),
      m.tracker.checkFinalizations(),
    ]);
    expect(m.fired, hasLength(1));
  });
}
