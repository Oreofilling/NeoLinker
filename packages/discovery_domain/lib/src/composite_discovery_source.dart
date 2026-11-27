/// Fan-in of several discovery sources behind the single
/// [DiscoverySource] seam: the controller keeps one source while the app
/// runs BLE, device-AP and CT-Disc in parallel (M5 task 4: all three
/// channels feed one registry; sources never touch each other).
library;

import 'dart:async';

import '../discovery_domain.dart';

/// Merges the candidate streams of [sources]; start/stop propagate to
/// every child. Children are isolated from each other: a child whose
/// stream errors or whose start() throws never takes the healthy channels
/// down with it (each source already guards its own scan loops; this is
/// the second belt).
final class CompositeDiscoverySource implements DiscoverySource {
  CompositeDiscoverySource(this.sources);

  final List<DiscoverySource> sources;

  final _merged = StreamController<DiscoveryCandidate>.broadcast();
  final List<StreamSubscription<DiscoveryCandidate>> _subs = [];

  /// Children whose start() succeeded and that were not stopped since.
  final Set<DiscoverySource> _running = {};

  /// Children whose last start() threw, by the channel they serve.
  final Map<DiscoveryChannel, Object> _startErrors = {};

  /// The start() in flight: callers that overlap share one attempt per
  /// child instead of racing to start them twice.
  Future<void>? _starting;

  /// Children whose last [start] threw, by the channel they serve. A
  /// child that is not a [ChannelDiscoverySource] (it declares no
  /// channel) still counts towards the all-failed rule of [start] but is
  /// not listed. Empty while every child runs; cleared by [stop].
  Map<DiscoveryChannel, Object> get startErrors =>
      Map.unmodifiable(_startErrors);

  @override
  Stream<DiscoveryCandidate> get candidates => _merged.stream;

  /// Starts every child that is not running yet; a child that is already
  /// running is left alone, so a later call retries only the ones that
  /// failed. A failing child is remembered in [startErrors] while the
  /// rest still start. Throws the first failure once no child could start
  /// at all.
  @override
  Future<void> start() => _starting ??= _startChildren().whenComplete(
        () => _starting = null,
      );

  Future<void> _startChildren() async {
    Object? firstError;
    StackTrace? firstStack;
    if (_subs.isEmpty) {
      // Subscribed before the children start, so nothing a child emits on
      // start-up is missed.
      for (final source in sources) {
        _subs.add(
          source.candidates.listen(
            _merged.add,
            onError: (Object _) {},
            cancelOnError: false,
          ),
        );
      }
    }
    // Sequential is deliberate: BLE first (the fast path users watch),
    // then the slower pollers. None of the start()s block on scan results.
    for (final source in sources) {
      if (_running.contains(source)) continue;
      final channel = source is ChannelDiscoverySource ? source.channel : null;
      try {
        await source.start();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
        if (channel != null) _startErrors[channel] = error;
        continue;
      }
      _running.add(source);
      if (channel != null) _startErrors.remove(channel);
    }
    if (_running.isEmpty && firstError != null) {
      // Nothing runs, so nothing feeds the listeners: the next start()
      // sets them up again.
      await _releaseSubscriptions();
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }

  /// Stops every child — one that never started answers with the port's
  /// no-op — and forgets the start failures, so the next [start] attempts
  /// all of them again. A child that refuses to stop does not keep the
  /// others running: all are asked, then its error is raised.
  @override
  Future<void> stop() async {
    if (_subs.isEmpty && _running.isEmpty && _startErrors.isEmpty) return;
    Object? firstError;
    StackTrace? firstStack;
    for (final source in sources) {
      try {
        await source.stop();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
      }
    }
    _running.clear();
    _startErrors.clear();
    await _releaseSubscriptions();
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }

  Future<void> _releaseSubscriptions() async {
    final subs = _subs.toList();
    _subs.clear();
    for (final sub in subs) {
      await sub.cancel();
    }
  }
}
