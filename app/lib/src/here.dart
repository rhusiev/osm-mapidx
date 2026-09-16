/// Where the phone thinks it is, so a hit can say how far away it is.
///
/// The platform half is hand-written (`MainActivity.kt`) rather than
/// `geolocator`, which would pull Play services in. Where the channel is
/// missing - any platform but Android - that reads as a refusal, and the list
/// simply shows no distances.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('nl.r1a.mapidx/here');
const _fixes = EventChannel('nl.r1a.mapidx/here/fixes');

enum Locating {
  off,
  waiting,
  on,

  /// Refused, or location is switched off.
  denied,
}

class Here extends ChangeNotifier {
  Locating state = Locating.off;

  /// Latitude and longitude of the last fix, if there has been one.
  (double, double)? at;

  StreamSubscription<dynamic>? _stream;

  Future<void> start() async {
    if (state == Locating.on || _stream != null) return;

    state = Locating.waiting;
    notifyListeners();

    // Subscribe before asking: the platform side answers `start` only once it
    // has somewhere to send fixes
    _stream = _fixes.receiveBroadcastStream().listen(_arrived, onError: (_) => _deny());

    bool granted;
    try {
      granted = await _channel.invokeMethod<bool>('start') ?? false;
    } on PlatformException {
      granted = false;
    } on MissingPluginException {
      granted = false;
    }
    if (!granted) _deny();
  }

  Future<void> stop() async {
    if (_stream == null) return;
    _stop();
    state = Locating.off;
    notifyListeners();
  }

  void _arrived(dynamic event) {
    final fix = (event as Map).cast<String, double>();
    at = (fix['lat']!, fix['lon']!);
    state = Locating.on;
    notifyListeners();
  }

  void _deny() {
    _stop();
    at = null;
    state = Locating.denied;
    notifyListeners();
  }

  void _stop() {
    _stream?.cancel();
    _stream = null;
    _channel.invokeMethod<void>('stop').catchError((_) {});
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }
}
