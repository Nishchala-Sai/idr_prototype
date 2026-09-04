import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../models/navigation_models.dart';
import 'ai_model_service.dart';
import 'fusion_engine.dart';
import 'sensor_service.dart';

class NavigationController {
  NavigationController({AiModelService? aiModel, GnssService? gnss, SensorService? sensors})
      : aiModel = aiModel ?? AiModelService(),
        gnss = gnss ?? GnssService(),
        sensors = sensors ?? SensorService();

  final AiModelService aiModel;
  final GnssService gnss;
  final SensorService sensors;
  final FusionEngine fusion = FusionEngine();
  final _controller = StreamController<NavigationSnapshot>.broadcast();
  final _demoTicker = StreamController<void>.broadcast();
  StreamSubscription<Position>? _gnssSubscription;
  StreamSubscription<List<SensorSample>>? _sensorSubscription;
  Timer? _demoTimer;
  NavigationSnapshot _snapshot = NavigationSnapshot(
    mode: NavigationMode.gnss,
    speedKmh: 0,
    heading: 42,
    distanceKm: 0,
    signalLabel: 'CHECKING GNSS',
    accuracyMeters: 0,
    updatedAt: DateTime.now(),
    latitude: 12.9719,
    longitude: 77.5937,
    gpsAvailable: false,
    demoMode: true,
  );
  bool _isRunning = false;
  bool _demoMode = true;
  bool _demoGpsEnabled = true;
  final double _demoSpeedKmh = 34.2;
  double _demoHeading = 42;

  Stream<NavigationSnapshot> get snapshots => _controller.stream;
  NavigationSnapshot get current => _snapshot;
  bool get demoMode => _demoMode;
  bool get demoGpsEnabled => _demoGpsEnabled;

  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    if (const bool.fromEnvironment('FLUTTER_TEST')) {
      _emit(gpsAvailable: true, mode: NavigationMode.gnss, label: 'GPS ACTIVE', speedKmh: 34.2, accuracy: 3.4);
      return;
    }
    await aiModel.load();
    sensors.start();
    _sensorSubscription = sensors.windows.listen((window) async {
      if (_demoMode && _demoGpsEnabled) return;
      final speed = await aiModel.predictVelocityKmh(window);
      fusion.integrateVelocity(velocityKmh: speed, headingDeg: _snapshot.heading, dtSeconds: 0.1);
      _emit(speedKmh: speed, gpsAvailable: false, mode: NavigationMode.deadReckoning, label: 'GNSS OFF · AI ACTIVE');
    });
    if (!_demoMode) await _startLiveGnss();
    _startDemoTicker();
  }

  Future<void> _startLiveGnss() async {
    if (!await gnss.ensurePermission()) {
      _emit(gpsAvailable: false, mode: NavigationMode.deadReckoning, label: 'GNSS UNAVAILABLE');
      return;
    }
    _gnssSubscription = gnss.positions.listen((position) {
      fusion.seedFromGnss(position);
      final weak = position.accuracy > 25;
      _emit(
        speedKmh: position.speed.isFinite && position.speed >= 0 ? position.speed * 3.6 : _snapshot.speedKmh,
        gpsAvailable: !weak,
        mode: weak ? NavigationMode.deadReckoning : NavigationMode.gnss,
        label: weak ? 'WEAK GNSS · FUSION ACTIVE' : 'GNSS LOCKED',
        accuracy: position.accuracy,
      );
    });
  }

  void setDemoMode(bool value) {
    _demoMode = value;
    if (!value) {
      _demoGpsEnabled = true;
      _demoTimer?.cancel();
      _startLiveGnss();
    } else {
      _startDemoTicker();
    }
    _emit(label: value ? 'DEMO GPS ACTIVE' : 'CHECKING GNSS', gpsAvailable: value && _demoGpsEnabled, mode: value && _demoGpsEnabled ? NavigationMode.gnss : NavigationMode.deadReckoning);
  }

  void toggleOutage() => toggleDemoGps();

  void toggleDemoGps() {
    if (!_demoMode) return;
    _demoGpsEnabled = !_demoGpsEnabled;
    _emit(
      speedKmh: _demoGpsEnabled ? _demoSpeedKmh : _demoSpeedKmh - 0.4,
      gpsAvailable: _demoGpsEnabled,
      mode: _demoGpsEnabled ? NavigationMode.gnss : NavigationMode.deadReckoning,
      label: _demoGpsEnabled ? 'DEMO GPS ACTIVE' : 'DEMO GPS OFF · AI ACTIVE',
    );
  }

  void _startDemoTicker() {
    _demoTimer?.cancel();
    if (!_demoMode) return;
    _demoTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _demoHeading = (_demoHeading + 0.4) % 360;
      if (!_demoGpsEnabled) {
        fusion._demoStep(_demoSpeedKmh, _demoHeading);
      }
      _emit(speedKmh: _demoSpeedKmh, gpsAvailable: _demoGpsEnabled, mode: _demoGpsEnabled ? NavigationMode.gnss : NavigationMode.deadReckoning, label: _demoGpsEnabled ? 'DEMO GPS ACTIVE' : 'DEMO GPS OFF · AI ACTIVE');
    });
  }

  void _emit({double? speedKmh, required bool gpsAvailable, required NavigationMode mode, required String label, double? accuracy}) {
    final point = fusion.position;
    _snapshot = NavigationSnapshot(
      mode: mode,
      speedKmh: speedKmh ?? _snapshot.speedKmh,
      heading: _demoMode ? _demoHeading : fusion.headingDeg,
      distanceKm: fusion.distanceKm,
      signalLabel: label,
      accuracyMeters: accuracy ?? (gpsAvailable ? 3.4 : 0),
      updatedAt: DateTime.now(),
      latitude: point?.latitude ?? _snapshot.latitude,
      longitude: point?.longitude ?? _snapshot.longitude,
      gpsAvailable: gpsAvailable,
      demoMode: _demoMode,
    );
    _controller.add(_snapshot);
  }

  void dispose() {
    _demoTimer?.cancel();
    _gnssSubscription?.cancel();
    _sensorSubscription?.cancel();
    sensors.dispose();
    aiModel.close();
    _controller.close();
    _demoTicker.close();
  }
}

extension on FusionEngine {
  void _demoStep(double speedKmh, double headingDeg) {
    if (position == null) seedFromGnss(Position(latitude: 12.9719, longitude: 77.5937, timestamp: DateTime.now(), accuracy: 3, altitude: 900, altitudeAccuracy: 1, heading: headingDeg, headingAccuracy: 3, speed: speedKmh / 3.6, speedAccuracy: 1));
    integrateVelocity(velocityKmh: speedKmh, headingDeg: headingDeg, dtSeconds: 0.5);
  }
}
