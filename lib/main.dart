import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:neurosdk2/neurosdk2.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const EMGApp());

class EMGApp extends StatelessWidget {
  const EMGApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: EMGHome(),
    );
  }
}

/* -------------------------- Exercise Presets -------------------------- */

class ExercisePreset {
  final String id;
  final String name;
  final String muscle; // for display only
  final double hi; // Schmitt trigger upper bound (normalized 0..1)
  final double lo; // Schmitt trigger lower bound (normalized 0..1)
  final double targetTutPerRepSecMin;
  final double targetTutPerRepSecMax;
  final String notes;

  const ExercisePreset({
    required this.id,
    required this.name,
    required this.muscle,
    required this.hi,
    required this.lo,
    required this.targetTutPerRepSecMin,
    required this.targetTutPerRepSecMax,
    required this.notes,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'muscle': muscle,
        'hi': hi,
        'lo': lo,
        'min': targetTutPerRepSecMin,
        'max': targetTutPerRepSecMax,
        'notes': notes,
      };

  factory ExercisePreset.fromJson(Map<String, dynamic> j) => ExercisePreset(
        id: j['id'],
        name: j['name'],
        muscle: j['muscle'],
        hi: (j['hi'] as num).toDouble(),
        lo: (j['lo'] as num).toDouble(),
        targetTutPerRepSecMin: (j['min'] as num).toDouble(),
        targetTutPerRepSecMax: (j['max'] as num).toDouble(),
        notes: j['notes'] ?? '',
      );
}

// Preloads tailored to your split (upper chest / delts / arms / abs + lats)
const kPresets = <ExercisePreset>[
  ExercisePreset(
    id: 'incline_db_press',
    name: 'Incline Dumbbell Press',
    muscle: 'Upper chest',
    hi: 0.62,
    lo: 0.34,
    targetTutPerRepSecMin: 3.5,
    targetTutPerRepSecMax: 5.0,
    notes: '2–3 sec eccentric; squeeze at top. Great for upper pec bias.',
  ),
  ExercisePreset(
    id: 'incline_db_fly',
    name: 'Incline Dumbbell Fly',
    muscle: 'Upper chest',
    hi: 0.58,
    lo: 0.30,
    targetTutPerRepSecMin: 4.0,
    targetTutPerRepSecMax: 6.0,
    notes: 'Control stretch; avoid bottom bounce.',
  ),
  ExercisePreset(
    id: 'chest_dips',
    name: 'Chest Dips (forward lean)',
    muscle: 'Chest',
    hi: 0.65,
    lo: 0.35,
    targetTutPerRepSecMin: 3.0,
    targetTutPerRepSecMax: 4.5,
    notes: 'Lean forward; avoid elbow flare pain.',
  ),
  ExercisePreset(
    id: 'lateral_raise',
    name: 'DB/Cable Lateral Raise',
    muscle: 'Delts',
    hi: 0.55,
    lo: 0.28,
    targetTutPerRepSecMin: 3.0,
    targetTutPerRepSecMax: 4.0,
    notes: 'Lead with elbow; soft lockout.',
  ),
  ExercisePreset(
    id: 'bayesian_curl',
    name: 'Bayesian Cable Curl',
    muscle: 'Biceps (long head)',
    hi: 0.60,
    lo: 0.32,
    targetTutPerRepSecMin: 3.5,
    targetTutPerRepSecMax: 5.0,
    notes: 'Stretch bias; keep humerus back.',
  ),
  ExercisePreset(
    id: 'incline_curl',
    name: 'Incline DB Curl',
    muscle: 'Biceps',
    hi: 0.60,
    lo: 0.32,
    targetTutPerRepSecMin: 4.0,
    targetTutPerRepSecMax: 5.5,
    notes: 'Let biceps lengthen; avoid shoulder roll.',
  ),
  ExercisePreset(
    id: 'jm_press',
    name: 'JM Press',
    muscle: 'Triceps',
    hi: 0.63,
    lo: 0.36,
    targetTutPerRepSecMin: 3.0,
    targetTutPerRepSecMax: 4.0,
    notes: 'Triceps bias, keep bar path consistent.',
  ),
  ExercisePreset(
    id: 'cable_crunch',
    name: 'Cable Crunch',
    muscle: 'Abs',
    hi: 0.58,
    lo: 0.30,
    targetTutPerRepSecMin: 2.5,
    targetTutPerRepSecMax: 3.5,
    notes: 'Flex spine; avoid hip-hinge dominance.',
  ),
  ExercisePreset(
    id: 'hanging_leg_raises',
    name: 'Hanging Straight Leg Raises',
    muscle: 'Abs/Hip flexors',
    hi: 0.62,
    lo: 0.34,
    targetTutPerRepSecMin: 3.0,
    targetTutPerRepSecMax: 4.0,
    notes: 'Posterior tilt; minimize swing.',
  ),
  ExercisePreset(
    id: 'lat_pull_in',
    name: 'Cross-Body Single-Arm Lat Pull-In',
    muscle: 'Lats',
    hi: 0.57,
    lo: 0.30,
    targetTutPerRepSecMin: 3.0,
    targetTutPerRepSecMax: 4.5,
    notes: 'Drive elbow to hip; feel lower lat.',
  ),
];

/* ----------------------------- App Widget ----------------------------- */

class EMGHome extends StatefulWidget {
  const EMGHome({super.key});
  @override
  State<EMGHome> createState() => _EMGHomeState();
}

class _EMGHomeState extends State<EMGHome> {
  // Callibri/SDK
  Scanner? _scanner;
  Callibri? _callibri;
  StreamSubscription<List<FSensorInfo>>? _scanSub;
  StreamSubscription<List<CallibriSignalData>>? _sigSub;

  // Live signal buffers
  final List<double> _envelope = [];
  static const int _winSamples = 100; // ~100ms at 1000 Hz
  final List<double> _chunk = [];

  // Metrics
  double _peakV = 0;
  double _avgV = 0;
  double _mvcPeak = 0.0;
  int _reps = 0;
  bool _gateHigh = false;
  DateTime? _repStart;
  double _tutThisSet = 0;
  bool _recordingSet = false;
  DateTime? _setStart;

  // Presets & thresholds
  late List<ExercisePreset> _presets;
  ExercisePreset? _selectedPreset;
  double _threshHi = 0.6;
  double _threshLo = 0.3;

  // History (persisted)
  final List<SetSummary> _history = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _presets = kPresets;
    _loadPersisted();
  }

  @override
  void dispose() {
    _sigSub?.cancel();
    _scanSub?.cancel();
    _callibri?.disconnect();
    _callibri?.dispose();
    _scanner?.stop();
    _scanner?.dispose();
    super.dispose();
  }

  /* --------------------------- Persistence I/O --------------------------- */

  Future<void> _loadPersisted() async {
    final sp = await SharedPreferences.getInstance();
    // Last preset
    final lastPresetId = sp.getString('preset_id');
    _selectedPreset =
        _presets.firstWhere((p) => p.id == lastPresetId, orElse: () => _presets.first);
    _applyPreset(_selectedPreset!, persist: false);

    // MVC & thresholds (if user tweaked)
    _mvcPeak = sp.getDouble('mvc_peak') ?? 0.0;
    _threshHi = sp.getDouble('thresh_hi') ?? _threshHi;
    _threshLo = sp.getDouble('thresh_lo') ?? _threshLo;

    // History
    final jsonStr = sp.getString('history_json');
    if (jsonStr != null && jsonStr.isNotEmpty) {
      final List<dynamic> arr = jsonDecode(jsonStr);
      _history.clear();
      _history.addAll(arr.map((e) => SetSummary.fromJson(e as Map<String, dynamic>)));
    }

    setState(() => _loading = false);
  }

  Future<void> _persistBasic() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('preset_id', _selectedPreset?.id ?? _presets.first.id);
    await sp.setDouble('mvc_peak', _mvcPeak);
    await sp.setDouble('thresh_hi', _threshHi);
    await sp.setDouble('thresh_lo', _threshLo);
  }

  Future<void> _persistHistory() async {
    final sp = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(_history.map((e) => e.toJson()).toList());
    await sp.setString('history_json', jsonStr);
  }

  /* ------------------------------ BLE Setup ----------------------------- */

  Future<void> _connect() async {
    try {
      _scanner = await Scanner.create([FSensorFamily.leCallibri]);
      _scanSub = _scanner!.sensorsStream.listen((devices) async {
        final info = devices.cast<FSensorInfo?>().firstWhere(
              (d) => d?.sensFamily == FSensorFamily.leCallibri,
              orElse: () => null,
            );
        if (info != null && _callibri == null) {
          await _scanner!.stop();
          _callibri = await _scanner!.createSensor(info!) as Callibri;
          await _callibri!.samplingFrequency.set(FSensorSamplingFrequency.hz1000);
          _sigSub = _callibri!.signalDataStream.listen(_onSignal);
          await _callibri!.execute(FSensorCommand.startSignal);
          setState(() {});
        }
      });
      await _scanner!.start();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Connect error: $e')));
      }
    }
  }

  /* ---------------------------- Signal Handling ---------------------------- */

  void _onSignal(List<CallibriSignalData> packets) {
    for (final p in packets) {
      for (final v in p.samples) {
        _chunk.add(v);
        if (_chunk.length >= _winSamples) {
          final rms = _rms(_chunk);
          _chunk.clear();

          _envelope.add(rms);
          final maxWindows = (1000 / _winSamples).round() * 6;
          if (_envelope.length > maxWindows) _envelope.removeAt(0);

          _peakV = max(_peakV, rms);
          _avgV = _envelope.fold(0.0, (a, b) => a + b) / _envelope.length;

          final denom = max(_mvcPeak, _peakV);
          final x = denom > 1e-9 ? (rms / denom) : 0.0;

          if (!_gateHigh && x > _threshHi) {
            _gateHigh = true;
            _repStart = DateTime.now();
          } else if (_gateHigh && x < _threshLo) {
            _gateHigh = false;
            _reps += 1;
            if (_recordingSet && _repStart != null) {
              _tutThisSet +=
                  DateTime.now().difference(_repStart!).inMilliseconds / 1000.0;
            }
            _repStart = null;
          }
        }
      }
    }
    if (mounted) setState(() {});
  }

  double _rms(List<double> s) {
    if (s.isEmpty) return 0;
    double sum = 0;
    for (final v in s) sum += v * v;
    return sqrt(sum / s.length);
  }

  /* ----------------------------- MVC & Sets ----------------------------- */

  Future<void> _calibrateMVC() async {
    if (_callibri == null) return;
    final start = DateTime.now();
    double localMax = 0;
    final sub = _callibri!.signalDataStream.listen((pkts) {
      for (final p in pkts) {
        for (final v in p.samples) {
          _chunk.add(v);
          if (_chunk.length >= _winSamples) {
            final rms = _rms(_chunk);
            _chunk.clear();
            localMax = max(localMax, rms);
          }
        }
      }
    });
    await Future.delayed(const Duration(seconds: 3));
    await sub.cancel();
    setState(() => _mvcPeak = max(_mvcPeak, localMax));
    _persistBasic();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('MVC captured: ${_mvcPeak.toStringAsFixed(6)} V')),
      );
    }
  }

  void _toggleSet() {
    if (_callibri == null) return;
    if (_recordingSet) {
      final setEnd = DateTime.now();
      final secs = setEnd.difference(_setStart!).inMilliseconds / 1000.0;
      _history.insert(
        0,
        SetSummary(
          timestamp: setEnd,
          reps: _reps,
          tutSec: _tutThisSet,
          durationSec: secs,
          avgV: _avgV,
          peakV: _peakV,
          mvcV: _mvcPeak,
          presetId: _selectedPreset?.id,
        ),
      );
      _persistHistory();
      _reps = 0;
      _tutThisSet = 0;
      _recordingSet = false;
    } else {
      _reps = 0;
      _tutThisSet = 0;
      _setStart = DateTime.now();
      _recordingSet = true;
    }
    setState(() {});
  }

  /* ------------------------------- Presets ------------------------------- */

  void _applyPreset(ExercisePreset p, {bool persist = true}) {
    _selectedPreset = p;
    _threshHi = p.hi;
    _threshLo = p.lo;
    if (persist) _persistBasic();
    setState(() {});
  }

  /* --------------------------------- UI --------------------------------- */

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final connected = _callibri != null;
    final denom = max(_mvcPeak, _peakV);
    final norm = _envelope
        .map((v) => denom > 1e-9 ? v / denom : 0.0)
        .toList(growable: false);

    final p = _selectedPreset!;
    final tutHint =
        '${p.targetTutPerRepSecMin.toStringAsFixed(1)}–${p.targetTutPerRepSecMax.toStringAsFixed(1)}s/rep';

    return Scaffold(
      appBar: AppBar(title: const Text('Callibri EMG – Presets & Storage')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Row 1: Connect • MVC • Start/End Set
            Row(
              children: [
                ElevatedButton(
                  onPressed: connected ? null : _connect,
                  child: Text(connected ? 'Connected ✅' : 'Connect'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: connected ? _calibrateMVC : null,
                  child: const Text('MVC (3s)'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: connected ? _toggleSet : null,
                  child: Text(_recordingSet ? 'End Set' : 'Start Set'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Row 2: Preset dropdown + TUT hint
            Row(
              children: [
                Expanded(
                  child: DropdownButton<ExercisePreset>(
                    isExpanded: true,
                    value: _selectedPreset,
                    items: _presets
                        .map((e) => DropdownMenuItem(
                              value: e,
                              child: Text('${e.name} — ${e.muscle}'),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) _applyPreset(v);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Chip(label: Text('Target TUT: $tutHint')),
              ],
            ),
            // Row 3: quick edit thresholds (persisted)
            Row(
              children: [
                Expanded(
                  child: _SliderWithLabel(
                    label: 'Hi',
                    value: _threshHi,
                    onChanged: (x) {
                      setState(() => _threshHi = x);
                    },
                    onChangeEnd: (_) => _persistBasic(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SliderWithLabel(
                    label: 'Lo',
                    value: _threshLo,
                    onChanged: (x) {
                      setState(() => _threshLo = x);
                    },
                    onChangeEnd: (_) => _persistBasic(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Env: ${_envelope.isEmpty ? "-" : _envelope.last.toStringAsFixed(6)} V   '
                'Peak: ${_peakV.toStringAsFixed(6)} V   '
                'Avg: ${_avgV.toStringAsFixed(6)} V   '
                '%MVC: ${_mvcPeak > 1e-9 && _envelope.isNotEmpty ? ((_envelope.last/_mvcPeak)*100).clamp(0, 999).toStringAsFixed(1) : "-"}%',
              ),
            ),
            const SizedBox(height: 8),
            // Chart
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: CustomPaint(
                  painter: EnvelopeChartPainter(norm, hi: _threshHi, lo: _threshLo),
                  child: Container(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // History
            Expanded(
              child: _history.isEmpty
                  ? const Center(child: Text('No sets yet'))
                  : ListView.builder(
                      itemCount: _history.length,
                      itemBuilder: (ctx, i) {
                        final s = _history[i];
                        final presetName = _presets
                            .firstWhere((pp) => pp.id == s.presetId,
                                orElse: () => _selectedPreset!)
                            .name;
                        return ListTile(
                          leading: const Icon(Icons.fitness_center),
                          title: Text(
                              '$presetName • ${s.reps} reps • TUT ${s.tutSec.toStringAsFixed(1)} s'),
                          subtitle: Text(
                            '${s.timestamp.toLocal()} • '
                            'dur ${s.durationSec.toStringAsFixed(1)} s • '
                            'avg ${s.avgV.toStringAsFixed(5)} V • '
                            'peak ${s.peakV.toStringAsFixed(5)} V • '
                            'MVC ${s.mvcV.toStringAsFixed(5)} V',
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ------------------------------- Widgets ------------------------------- */

class _SliderWithLabel extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  const _SliderWithLabel({
    required this.label,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${value.toStringAsFixed(2)}'),
        Slider(
          value: value,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
          min: 0.1,
          max: 0.9,
          divisions: 80,
        ),
      ],
    );
  }
}

/* ------------------------------- Painter ------------------------------- */

class EnvelopeChartPainter extends CustomPainter {
  final List<double> data; // normalized 0..1
  final double hi, lo;

  EnvelopeChartPainter(this.data, {required this.hi, required this.lo});

  @override
  void paint(Canvas canvas, Size size) {
    final paintLine = Paint()..style = PaintingStyle.stroke..strokeWidth = 2;
    final paintAxis = Paint()..style = PaintingStyle.stroke..strokeWidth = 1;

    canvas.drawLine(
        Offset(0, size.height - 1), Offset(size.width, size.height - 1), paintAxis);
    canvas.drawLine(Offset(0, 0), Offset(0, size.height), paintAxis);

    // dashed hi/lo guides
    final yHi = (1 - hi) * size.height;
    final yLo = (1 - lo) * size.height;
    final dash = Paint()..style = PaintingStyle.stroke..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, yHi), Offset(x + 4, yHi), dash);
      canvas.drawLine(Offset(x, yLo), Offset(x + 4, yLo), dash);
    }

    if (data.isEmpty) return;

    final stepX = size.width / max(1, data.length - 1);
    final path = Path();
    for (int i = 0; i < data.length; i++) {
      final x = i * stepX;
      final y = (1 - data[i].clamp(0.0, 1.5)) * size.height;
      if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    canvas.drawPath(path, paintLine);
  }

  @override
  bool shouldRepaint(covariant EnvelopeChartPainter old) =>
      old.data != data || old.hi != hi || old.lo != lo;
}

/* ------------------------------- Models ------------------------------- */

class SetSummary {
  final DateTime timestamp;
  final int reps;
  final double tutSec;
  final double durationSec;
  final double avgV;
  final double peakV;
  final double mvcV;
  final String? presetId;

  SetSummary({
    required this.timestamp,
    required this.reps,
    required this.tutSec,
    required this.durationSec,
    required this.avgV,
    required this.peakV,
    required this.mvcV,
    this.presetId,
  });

  Map<String, dynamic> toJson() => {
        'ts': timestamp.toIso8601String(),
        'reps': reps,
        'tut': tutSec,
        'dur': durationSec,
        'avg': avgV,
        'peak': peakV,
        'mvc': mvcV,
        'presetId': presetId,
      };

  factory SetSummary.fromJson(Map<String, dynamic> j) => SetSummary(
        timestamp: DateTime.parse(j['ts']),
        reps: (j['reps'] as num).toInt(),
        tutSec: (j['tut'] as num).toDouble(),
        durationSec: (j['dur'] as num).toDouble(),
        avgV: (j['avg'] as num).toDouble(),
        peakV: (j['peak'] as num).toDouble(),
        mvcV: (j['mvc'] as num).toDouble(),
        presetId: j['presetId'],
      );
}
