import 'package:flutter/services.dart' show MissingPluginException;
import 'package:shared_preferences/shared_preferences.dart';

/// Per-player secret + active-id persistence contract. Implementations
/// MUST be durable across process restarts so the SDK's lazy
/// `register` doesn't fire every launch.
///
/// The SDK auto-selects a backend based on the runtime:
/// [SharedPreferencesSecretStore] when the Flutter binding is alive,
/// [InMemorySecretStore] otherwise. Game code never has to construct
/// or pass one; `Kraty(KratyClientOptions(apiKey: '...'))` is enough.
abstract class SecretStore {
  /// Returns the stored secret for [externalPlayerId], or null if
  /// none is stored.
  Future<String?> read(String externalPlayerId);

  /// Persists [secret] for [externalPlayerId]. Overwrites any
  /// existing value (rotation).
  Future<void> write(String externalPlayerId, String secret);

  /// Removes the stored secret for [externalPlayerId]. Used on
  /// logout or when the backend invalidates the secret.
  Future<void> remove(String externalPlayerId);

  /// Returns the last `externalPlayerId` written via
  /// [writeActiveExternalPlayerId], or null when the store doesn't
  /// track an active id or none has been set.
  ///
  /// Default impl: returns null (no active-identity tracking).
  Future<String?> readActiveExternalPlayerId() async => null;

  /// Persists [externalPlayerId] as the device's "active player".
  /// Called automatically when the SDK resolves an identity via
  /// `Kraty.ensureIdentity` / `Kraty.signIn`.
  ///
  /// Default impl: no-op.
  Future<void> writeActiveExternalPlayerId(String externalPlayerId) async {}

  /// Forgets the active-id marker without touching per-player
  /// secrets. Used on explicit logout / "switch user" flows where
  /// you want the secret to survive in case the user signs back in.
  ///
  /// Default impl: no-op.
  Future<void> clearActiveExternalPlayerId() async {}
}

/// Volatile, process-local store. Used as the fallback default in
/// pure-Dart runtimes (CLI tools, headless tests) where the Flutter
/// binding isn't initialized and [SharedPreferencesSecretStore] can't
/// reach platform storage. Production Flutter apps get the durable
/// default automatically.
class InMemorySecretStore implements SecretStore {
  final Map<String, String> _secrets = <String, String>{};
  String? _activeExternalPlayerId;

  @override
  Future<String?> read(String externalPlayerId) async =>
      _secrets[externalPlayerId];

  @override
  Future<void> write(String externalPlayerId, String secret) async {
    _secrets[externalPlayerId] = secret;
  }

  @override
  Future<void> remove(String externalPlayerId) async {
    _secrets.remove(externalPlayerId);
    if (_activeExternalPlayerId == externalPlayerId) {
      _activeExternalPlayerId = null;
    }
  }

  @override
  Future<String?> readActiveExternalPlayerId() async =>
      _activeExternalPlayerId;

  @override
  Future<void> writeActiveExternalPlayerId(String externalPlayerId) async {
    _activeExternalPlayerId = externalPlayerId;
  }

  @override
  Future<void> clearActiveExternalPlayerId() async {
    _activeExternalPlayerId = null;
  }
}

/// Durable [SecretStore] backed by `shared_preferences`. Picked
/// automatically when the SDK detects a live Flutter binding; game
/// code doesn't construct it directly.
///
/// Key namespace mirrors the TypeScript SDK so a hybrid Flutter/web
/// project can read the same shape if it ever needs to:
/// `kraty.playerSecret.<externalId>` for secrets,
/// `kraty.activeExternalPlayerId` for the active marker.
///
/// `shared_preferences` is unencrypted on disk. For high-value
/// economies, wrap a platform Keychain plugin behind a custom
/// [SecretStore] and pass it via `KratyClientOptions.secretStore`.
class SharedPreferencesSecretStore implements SecretStore {
  static const String _secretKeyPrefix = 'kraty.playerSecret.';
  static const String _activeIdKey = 'kraty.activeExternalPlayerId';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  String _secretKey(String externalPlayerId) =>
      '$_secretKeyPrefix$externalPlayerId';

  @override
  Future<String?> read(String externalPlayerId) async {
    final prefs = await _prefs;
    final v = prefs.getString(_secretKey(externalPlayerId));
    return v != null && v.isNotEmpty ? v : null;
  }

  @override
  Future<void> write(String externalPlayerId, String secret) async {
    final prefs = await _prefs;
    await prefs.setString(_secretKey(externalPlayerId), secret);
  }

  @override
  Future<void> remove(String externalPlayerId) async {
    final prefs = await _prefs;
    await prefs.remove(_secretKey(externalPlayerId));
    final active = prefs.getString(_activeIdKey);
    if (active == externalPlayerId) {
      await prefs.remove(_activeIdKey);
    }
  }

  @override
  Future<String?> readActiveExternalPlayerId() async {
    final prefs = await _prefs;
    final v = prefs.getString(_activeIdKey);
    return v != null && v.isNotEmpty ? v : null;
  }

  @override
  Future<void> writeActiveExternalPlayerId(String externalPlayerId) async {
    final prefs = await _prefs;
    await prefs.setString(_activeIdKey, externalPlayerId);
  }

  @override
  Future<void> clearActiveExternalPlayerId() async {
    final prefs = await _prefs;
    await prefs.remove(_activeIdKey);
  }
}

/// Lazily-resolved default store. The first method call probes the
/// runtime: if `SharedPreferences.getInstance()` succeeds we swap in
/// [SharedPreferencesSecretStore]; if it throws [MissingPluginException]
/// (pure-Dart CLI, no Flutter binding) we fall back to
/// [InMemorySecretStore]. The probe runs once; every subsequent call
/// delegates to the resolved backend.
///
/// Exists so `Kraty(KratyClientOptions(apiKey: '...'))` Just Works on
/// both Flutter apps and headless Dart tools without forcing the
/// caller to pick a backend at construction time.
class DefaultSecretStore implements SecretStore {
  SecretStore? _delegate;
  Future<SecretStore>? _resolving;

  Future<SecretStore> _resolve() {
    final cached = _delegate;
    if (cached != null) return Future.value(cached);
    final pending = _resolving;
    if (pending != null) return pending;
    final future = _probe();
    _resolving = future;
    return future;
  }

  Future<SecretStore> _probe() async {
    try {
      await SharedPreferences.getInstance();
      final store = SharedPreferencesSecretStore();
      _delegate = store;
      return store;
    } on MissingPluginException {
      final store = InMemorySecretStore();
      _delegate = store;
      return store;
    } catch (_) {
      final store = InMemorySecretStore();
      _delegate = store;
      return store;
    } finally {
      _resolving = null;
    }
  }

  @override
  Future<String?> read(String externalPlayerId) async =>
      (await _resolve()).read(externalPlayerId);

  @override
  Future<void> write(String externalPlayerId, String secret) async =>
      (await _resolve()).write(externalPlayerId, secret);

  @override
  Future<void> remove(String externalPlayerId) async =>
      (await _resolve()).remove(externalPlayerId);

  @override
  Future<String?> readActiveExternalPlayerId() async =>
      (await _resolve()).readActiveExternalPlayerId();

  @override
  Future<void> writeActiveExternalPlayerId(String externalPlayerId) async =>
      (await _resolve()).writeActiveExternalPlayerId(externalPlayerId);

  @override
  Future<void> clearActiveExternalPlayerId() async =>
      (await _resolve()).clearActiveExternalPlayerId();
}
