import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

void main() {
  runApp(const SensorPlotsApp());
}

class SensorPlotsApp extends StatelessWidget {
  const SensorPlotsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sensor & GPS Plots',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const SensorDashboardPage(),
    );
  }
}

class SensorDashboardPage extends StatefulWidget {
  const SensorDashboardPage({super.key});

  @override
  State<SensorDashboardPage> createState() => _SensorDashboardPageState();
}

class _SensorDashboardPageState extends State<SensorDashboardPage> {
  static const int _maxPoints = 80;

  // Accelerometer series (m/s^2)
  final List<FlSpot> _accX = [];
  final List<FlSpot> _accY = [];
  final List<FlSpot> _accZ = [];

  // GPS lat/lon path (x = longitude, y = latitude)
  final List<FlSpot> _gpsPath = [];

  // Estimated velocity from userAccelerometer integration (m/s) & GPS speed (m/s)
  final List<FlSpot> _velX = [];
  final List<FlSpot> _velY = [];
  final List<FlSpot> _velMag = [];
  final List<FlSpot> _gpsSpeedSpots = [];

  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<UserAccelerometerEvent>? _userAccSub;
  StreamSubscription<Position>? _posSub;

  double _sampleIndex = 0;
  double _velSampleIndex = 0;

  double _vx = 0;
  double _vy = 0;
  double _vz = 0;
  DateTime? _lastUserAccTime;

  String _gpsStatus = 'Initializing GPS...';
  double? _latestLat;
  double? _latestLon;
  double _latestGpsSpeed = 0;

  @override
  void initState() {
    super.initState();
    _startAccelerometer();
    _startVelocityIntegration();
    _startGps();
  }

  void _startAccelerometer() {
    _accSub =
        accelerometerEventStream(
          samplingPeriod: const Duration(milliseconds: 50),
        ).listen((AccelerometerEvent event) {
          setState(() {
            final t = _sampleIndex++;
            _addTrimmed(_accX, FlSpot(t, event.x));
            _addTrimmed(_accY, FlSpot(t, event.y));
            _addTrimmed(_accZ, FlSpot(t, event.z));
          });
        });
  }

  void _startVelocityIntegration() {
    _userAccSub =
        userAccelerometerEventStream(
          samplingPeriod: const Duration(milliseconds: 50),
        ).listen((UserAccelerometerEvent event) {
          final now = DateTime.now();
          if (_lastUserAccTime != null) {
            final dt = now.difference(_lastUserAccTime!).inMicroseconds / 1e6;
            if (dt > 0 && dt < 1.0) {
              // Small deadband to suppress stationary accelerometer noise
              final ax = event.x.abs() < 0.08 ? 0.0 : event.x;
              final ay = event.y.abs() < 0.08 ? 0.0 : event.y;
              final az = event.z.abs() < 0.08 ? 0.0 : event.z;

              // Light damping reduces long-term integration drift
              const damping = 0.985;
              _vx = (_vx + ax * dt) * damping;
              _vy = (_vy + ay * dt) * damping;
              _vz = (_vz + az * dt) * damping;

              final speedMag = math.sqrt(_vx * _vx + _vy * _vy + _vz * _vz);

              setState(() {
                final t = _velSampleIndex++;
                _addTrimmed(_velX, FlSpot(t, _vx));
                _addTrimmed(_velY, FlSpot(t, _vy));
                _addTrimmed(_velMag, FlSpot(t, speedMag));
                _addTrimmed(_gpsSpeedSpots, FlSpot(t, _latestGpsSpeed));
              });
            }
          }
          _lastUserAccTime = now;
        });
  }

  Future<void> _startGps() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => _gpsStatus = 'Location services disabled');
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() => _gpsStatus = 'Location permission denied');
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() => _gpsStatus = 'Location permission permanently denied');
      return;
    }

    setState(() => _gpsStatus = 'Streaming GPS...');

    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );

    _posSub = Geolocator.getPositionStream(locationSettings: settings).listen((
      Position pos,
    ) {
      setState(() {
        _latestLat = pos.latitude;
        _latestLon = pos.longitude;
        _latestGpsSpeed = pos.speed.isFinite && pos.speed >= 0 ? pos.speed : 0;
        _addTrimmed(_gpsPath, FlSpot(pos.longitude, pos.latitude));
      });
    });
  }

  void _resetVelocity() {
    setState(() {
      _vx = 0;
      _vy = 0;
      _vz = 0;
      _velX.clear();
      _velY.clear();
      _velMag.clear();
      _gpsSpeedSpots.clear();
      _velSampleIndex = 0;
    });
  }

  void _addTrimmed(List<FlSpot> list, FlSpot spot) {
    list.add(spot);
    if (list.length > _maxPoints) {
      list.removeAt(0);
    }
  }

  @override
  void dispose() {
    _accSub?.cancel();
    _userAccSub?.cancel();
    _posSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gpsCoordsLabel = (_latestLat != null && _latestLon != null)
        ? 'Lat: ${_latestLat!.toStringAsFixed(6)}, Lon: ${_latestLon!.toStringAsFixed(6)}'
        : _gpsStatus;

    return Scaffold(
      appBar: AppBar(
        title: const Text('GPS & Sensor Plots'),
        actions: [
          IconButton(
            onPressed: _resetVelocity,
            tooltip: 'Reset integrated velocity',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _PlotCard(
            title: 'GPS Latitude & Longitude',
            subtitle: gpsCoordsLabel,
            legend: const [
              _LegendItem(color: Colors.teal, label: 'Path (Lon X, Lat Y)'),
            ],
            child: _buildGpsChart(),
          ),
          const SizedBox(height: 16),
          _PlotCard(
            title: 'Accelerometer (m/s²)',
            subtitle: 'Raw 3-axis acceleration including gravity',
            legend: const [
              _LegendItem(color: Colors.red, label: 'X'),
              _LegendItem(color: Colors.green, label: 'Y'),
              _LegendItem(color: Colors.blue, label: 'Z'),
            ],
            child: _buildLineChart(
              lines: [
                _series(_accX, Colors.red),
                _series(_accY, Colors.green),
                _series(_accZ, Colors.blue),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _PlotCard(
            title: 'Velocity (m/s)',
            subtitle: 'Integrated linear velocity & GPS speed',
            legend: const [
              _LegendItem(color: Colors.purple, label: '|v| IMU'),
              _LegendItem(color: Colors.orange, label: 'Vx IMU'),
              _LegendItem(color: Colors.cyan, label: 'Vy IMU'),
              _LegendItem(color: Colors.black87, label: 'GPS Speed'),
            ],
            child: _buildLineChart(
              lines: [
                _series(_velMag, Colors.purple),
                _series(_velX, Colors.orange),
                _series(_velY, Colors.cyan),
                _series(_gpsSpeedSpots, Colors.black87),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGpsChart() {
    if (_gpsPath.isEmpty) {
      return const Center(child: Text('Waiting for GPS coordinates...'));
    }

    double minX = _gpsPath.first.x, maxX = _gpsPath.first.x;
    double minY = _gpsPath.first.y, maxY = _gpsPath.first.y;
    for (final p in _gpsPath) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }

    final padX = math.max((maxX - minX) * 0.2, 0.0002);
    final padY = math.max((maxY - minY) * 0.2, 0.0002);

    return LineChart(
      LineChartData(
        minX: minX - padX,
        maxX: maxX + padX,
        minY: minY - padY,
        maxY: maxY + padY,
        gridData: const FlGridData(show: true),
        borderData: FlBorderData(show: true),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            axisNameWidget: const Text(
              'Longitude',
              style: TextStyle(fontSize: 11),
            ),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(4),
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
          leftTitles: AxisTitles(
            axisNameWidget: const Text(
              'Latitude',
              style: TextStyle(fontSize: 11),
            ),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 54,
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(4),
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: List.of(_gpsPath),
            color: Colors.teal,
            barWidth: 3,
            dotData: const FlDotData(show: true),
          ),
        ],
      ),
    );
  }

  Widget _buildLineChart({required List<LineChartBarData> lines}) {
    return LineChart(
      LineChartData(
        gridData: const FlGridData(show: true),
        borderData: FlBorderData(show: true),
        titlesData: const FlTitlesData(
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        lineBarsData: lines,
      ),
    );
  }

  LineChartBarData _series(List<FlSpot> spots, Color color) {
    return LineChartBarData(
      spots: List.of(spots),
      color: color,
      barWidth: 2,
      dotData: const FlDotData(show: false),
    );
  }
}

class _PlotCard extends StatelessWidget {
  const _PlotCard({
    required this.title,
    required this.subtitle,
    required this.legend,
    required this.child,
  });

  final String title;
  final String subtitle;
  final List<_LegendItem> legend;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(spacing: 12, runSpacing: 4, children: legend),
            const SizedBox(height: 12),
            SizedBox(height: 210, child: child),
          ],
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 12, height: 4, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
