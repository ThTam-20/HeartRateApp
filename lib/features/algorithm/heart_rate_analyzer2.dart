import 'dart:collection';
import 'dart:math';
// IMPORT FILE BẠN VỪA TẠO
import 'ppg_morphology.dart';

// [MỚI] Class trả về kết quả đầy đủ cho UI
class AnalyzerResult {
  final int bpm;
  final PpgMorphologyResult morphology; // 5 đặc trưng sóng
  final DateTime timestamp;
  final List<double> signal;

  AnalyzerResult({
    required this.bpm,
    required this.morphology,
    required this.timestamp,
    required this.signal
  });
}

// [SỬA] Đổi kiểu callback
typedef ResultCallback = void Function(AnalyzerResult result);

class HeartRateAnalyzerConfig {
  // ... (Giữ nguyên toàn bộ nội dung Config cũ) ...
  final double fps;
  final double windowSec;
  final double stepSec;
  final double hpHz;
  final double lpHz;
  final int smoothSamples;
  final int minPeakDistMs;
  final int bpmMin;
  final int bpmMax;

  const HeartRateAnalyzerConfig({
    required this.fps,
    required this.windowSec,
    required this.stepSec,
    this.hpHz =  0.7,
    this.lpHz = 4.0,
    required this.smoothSamples ,
    required this.minPeakDistMs ,
    required this.bpmMin,
    required this.bpmMax,
  });
}

class HeartRateAnalyzer {
  final HeartRateAnalyzerConfig cfg;
  final ResultCallback? onResultCalculated; // [SỬA] Tên và kiểu callback

  final ListQueue<double> _buffer = ListQueue<double>();
  final int _maxSamples;
  final int _stepSamples;
  final int _smoothK;
  final int _minPeakDistSamples;
  List<double> lastPpgWaveform = []; // Sóng Z-score

  // Trạng thái filter
  double? _lastSample;
  double? _lastHp;
  double? _lastLp;
  double? _lastBpm;
  int _sinceLastEmit = 0;

  // [SỬA] Constructor
  HeartRateAnalyzer(this.cfg, {this.onResultCalculated})
    : _maxSamples = (cfg.windowSec * cfg.fps).round(),
      _stepSamples = max(1, (cfg.stepSec * cfg.fps).round()),
      _smoothK = (cfg.smoothSamples > 0)
          ? cfg.smoothSamples
          : max(3, (0.20 * cfg.fps).round()),
      _minPeakDistSamples = max(
        1,
        ((cfg.minPeakDistMs / 1000.0) * cfg.fps).round(),
      );

  void addSample(double v) {
    _buffer.add(v);
    if (_buffer.length > _maxSamples) _buffer.removeFirst();

    _sinceLastEmit++;
    if (_sinceLastEmit >= _stepSamples) {
      _sinceLastEmit = 0;
      _processWindow();
    }
  }

  void reset() {
    _buffer.clear();
    _lastSample = null;
    _lastHp = null;
    _lastLp = null;
    _lastBpm = null;
    _sinceLastEmit = 0;
    lastPpgWaveform = [];
  }

  // ========== Core pipeline ==========
  void _processWindow() {
    if (_buffer.length < max(8, (cfg.fps * 2).round())) return;

    final raw = _buffer.toList(growable: false);
    final dt = 1.0 / cfg.fps;

    // 1-3. Filters (Giữ nguyên logic cũ của bạn)
    final hpA = _alphaHighPass(cfg.hpHz, dt);
    final hp = List<double>.filled(raw.length, 0.0);
    double yhp = _lastHp ?? 0.0;
    double xprev = _lastSample ?? raw.first;
    for (int i = 0; i < raw.length; i++) {
      final x = raw[i];
      yhp = hpA * (yhp + x - xprev);
      hp[i] = yhp;
      xprev = x;
    }
    _lastHp = yhp;
    _lastSample = raw.last;

    final lpA = _alphaLowPass(cfg.lpHz, dt);
    final bp = List<double>.filled(hp.length, 0.0);
    double ylp = _lastLp ?? 0.0;
    for (int i = 0; i < hp.length; i++) {
      final x = hp[i];
      ylp = ylp + lpA * (x - ylp);
      bp[i] = ylp;
    }
    _lastLp = ylp;

    final sm = _movingAverage(bp, _smoothK);

    // 4. Z-score (Quan trọng cho AI)
    final m = _mean(sm);
    final s = _std(sm, m);
    final z = s > 1e-9
        ? sm.map((v) => (v - m) / s).toList(growable: false)
        : List<double>.filled(sm.length, 0.0);
    lastPpgWaveform = z;

    // 5. Phát hiện đỉnh
    final thr = max(0.5, _percentile(z, 0.75));
    final peaks = _findPeaks(
      z,
      threshold: thr,
      minDistance: _minPeakDistSamples,
    );
    if (peaks.length < 2) return;

    // --- [MỚI] TRÍCH XUẤT ĐẶC TRƯNG HÌNH THÁI ---
    final morphology = PpgMorphologyExtractor.extract(
      zSignal: z,
      peaks: peaks,
      fps: cfg.fps,
    );
    // --------------------------------------------

    // 6. Tính BPM (Logic cũ)
    final rr = <double>[];
    for (int i = 1; i < peaks.length; i++) {
      final sec = (peaks[i] - peaks[i - 1]) / cfg.fps;
      final tmpBpm = 60.0 / sec;
      if (tmpBpm >= cfg.bpmMin && tmpBpm <= cfg.bpmMax) rr.add(sec);
    }
    if (rr.isEmpty) return;

    final rrMed = _median(rr);
    double bpm = 60.0 / rrMed;
    bpm = bpm.clamp(cfg.bpmMin.toDouble(), cfg.bpmMax.toDouble());

    final smoothedBpm = (_lastBpm == null) ? bpm : 0.7 * _lastBpm! + 0.3 * bpm;
    _lastBpm = smoothedBpm;

    // [SỬA] Trả về kết quả tổng hợp
    onResultCalculated?.call(
      AnalyzerResult(
        bpm: smoothedBpm.round(),
        morphology: morphology, // Kết quả 5 đặc trưng nằm ở đây
        timestamp: DateTime.now(),
        signal: lastPpgWaveform
      ),
    );
  }

  // ... (Giữ nguyên các hàm static helper: _alphaHighPass, _mean, _std, v.v...)
  static double _alphaHighPass(double fc, double dt) {
    final rc = 1.0 / (2 * pi * fc);
    return rc / (rc + dt);
  }

  static double _alphaLowPass(double fc, double dt) {
    final rc = 1.0 / (2 * pi * fc);
    return dt / (rc + dt);
  }

  static List<double> _movingAverage(List<double> x, int k) {
    if (k <= 1 || x.length < k) return List<double>.from(x);
    final out = List<double>.filled(x.length, 0.0);
    double sum = 0;
    for (int i = 0; i < x.length; i++) {
      sum += x[i];
      if (i >= k) sum -= x[i - k];
      out[i] = i >= k - 1 ? sum / k : x[i];
    }
    return out;
  }

  static double _mean(List<double> x) {
    if (x.isEmpty) return 0;
    var s = 0.0;
    for (final v in x) s += v;
    return s / x.length;
  }

  static double _std(List<double> x, double m) {
    if (x.isEmpty) return 0;
    var s = 0.0;
    for (final v in x) {
      final d = v - m;
      s += d * d;
    }
    return sqrt(s / x.length);
  }

  static double _percentile(List<double> x, double p) {
    if (x.isEmpty) return 0;
    final a = List<double>.from(x)..sort();
    final idx = p * (a.length - 1);
    final i = idx.floor();
    final f = idx - i;
    if (i >= a.length - 1) return a.last;
    return a[i] * (1 - f) + a[i + 1] * f;
  }

  static List<int> _findPeaks(
    List<double> x, {
    required double threshold,
    required int minDistance,
  }) {
    final peaks = <int>[];
    var last = -minDistance - 1;
    for (int i = 1; i < x.length - 1; i++) {
      if (x[i] > threshold && x[i] >= x[i - 1] && x[i] > x[i + 1]) {
        if (i - last >= minDistance) {
          peaks.add(i);
          last = i;
        }
      }
    }
    return peaks;
  }

  static double _median(List<double> x) {
    final a = List<double>.from(x)..sort();
    final n = a.length;
    return n.isOdd ? a[n ~/ 2] : 0.5 * (a[n ~/ 2 - 1] + a[n ~/ 2]);
  }
}
