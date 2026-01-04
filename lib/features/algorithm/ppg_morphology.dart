import 'dart:math';

/// Class chứa 5 đặc trưng hình thái khớp với Model AI
class PpgMorphologyResult {
  final double meanRiseTime; // ms
  final double meanDecayTime; // ms
  final double meanPulseWidth; // ms (đã nội suy)
  final double meanAUC; // diện tích
  final double meanAmp; // biên độ (z-score value)
  final int validBeats; // số nhịp hợp lệ dùng để tính

  const PpgMorphologyResult({
    this.meanRiseTime = 0,
    this.meanDecayTime = 0,
    this.meanPulseWidth = 0,
    this.meanAUC = 0,
    this.meanAmp = 0,
    this.validBeats = 0,
  });

  @override
  String toString() {
    return 'Rise: ${meanRiseTime.toStringAsFixed(1)}ms, '
        'Decay: ${meanDecayTime.toStringAsFixed(1)}ms, '
        'Width: ${meanPulseWidth.toStringAsFixed(1)}ms, '
        'AUC: ${meanAUC.toStringAsFixed(2)}, '
        'Amp: ${meanAmp.toStringAsFixed(2)}';
  }
}

class PpgMorphologyExtractor {
  /// Hàm chính để trích xuất đặc trưng
  /// [zSignal]: Tín hiệu đã chuẩn hóa Z-score (lấy từ Analyzer)
  /// [peaks]: Các đỉnh đã tìm được (lấy từ Analyzer)
  /// [fps]: Tốc độ khung hình (30)
  static PpgMorphologyResult extract({
    required List<double> zSignal,
    required List<int> peaks,
    required double fps,
  }) {
    // Cần ít nhất 2 đỉnh để xác định một chu kỳ đầy đủ (từ đáy đến đáy)
    if (peaks.length < 2 || zSignal.isEmpty) {
      return const PpgMorphologyResult();
    }

    List<double> listRise = [];
    List<double> listDecay = [];
    List<double> listWidth = [];
    List<double> listAUC = [];
    List<double> listAmp = [];

    // Duyệt qua các đỉnh (bỏ qua đỉnh đầu tiên để đảm bảo tìm được đáy trước đó)
    // Và bỏ đỉnh cuối cùng nếu không tìm được đáy sau
    for (int i = 0; i < peaks.length; i++) {
      int pIdx = peaks[i];

      // 1. TÌM ĐÁY TRƯỚC (Onset) VÀ ĐÁY SAU (Offset)

      // Giới hạn tìm kiếm:
      // - Đáy trước: Từ đỉnh trước đó (hoặc 0.6s trước nếu là đỉnh đầu) đến đỉnh hiện tại
      // - Đáy sau: Từ đỉnh hiện tại đến đỉnh kế tiếp (hoặc 0.6s sau nếu là đỉnh cuối)

      int searchStart = (i == 0)
          ? max(0, pIdx - (0.6 * fps).round())
          : peaks[i - 1];

      int searchEnd = (i == peaks.length - 1)
          ? min(zSignal.length - 1, pIdx + (0.6 * fps).round())
          : peaks[i + 1];

      // Tìm index của giá trị nhỏ nhất (Trough)
      int tPrev = _argMin(zSignal, searchStart, pIdx);
      int tNext = _argMin(zSignal, pIdx, searchEnd);

      // Kiểm tra tính hợp lệ: Đáy phải thấp hơn đỉnh và đúng thứ tự
      if (tPrev >= pIdx || tNext <= pIdx) continue;

      // Kiểm tra biên độ: Nếu sóng quá nhỏ (do nhiễu), bỏ qua
      // Vì là Z-score, hiệu số đỉnh - đáy thường > 1.0
      double peakVal = zSignal[pIdx];
      double baseline = zSignal[tPrev];
      double height = peakVal - baseline;

      if (height < 0.5) continue; // Ngưỡng lọc nhiễu cơ bản

      // 2. TÍNH TOÁN CÁC CHỈ SỐ

      // A. Rise Time & Decay Time (ms)
      double dtMs = 1000.0 / fps;
      double riseMs = (pIdx - tPrev) * dtMs;
      double decayMs = (tNext - pIdx) * dtMs;

      // B. Pulse Width @ 50% (Dùng nội suy tuyến tính)
      double targetLevel = baseline + (height * 0.5);

      double? leftCross = _findCrossingIndexSubsample(
        zSignal,
        tPrev,
        pIdx,
        targetLevel,
        rising: true,
      );

      double? rightCross = _findCrossingIndexSubsample(
        zSignal,
        pIdx,
        tNext,
        targetLevel,
        rising: false,
      );

      if (leftCross == null || rightCross == null) continue;

      double widthMs = (rightCross - leftCross) * dtMs;

      // C. AUC (Diện tích dưới đường cong - trên nền baseline)
      double auc = _calculateAUC(zSignal, tPrev, tNext, baseline);

      // D. Amp (Biên độ đỉnh z-score tuyệt đối - khớp với code Python train)
      double amp = peakVal;

      // Lọc các giá trị phi lý (do nhiễu quá lớn)
      if (riseMs > 1000 || decayMs > 2000 || widthMs > 1500) continue;

      listRise.add(riseMs);
      listDecay.add(decayMs);
      listWidth.add(widthMs);
      listAUC.add(auc);
      listAmp.add(amp);
    }

    if (listRise.isEmpty) return const PpgMorphologyResult();

    // Hàm tính trung bình
    double mean(List<double> x) => x.reduce((a, b) => a + b) / x.length;

    return PpgMorphologyResult(
      meanRiseTime: mean(listRise),
      meanDecayTime: mean(listDecay),
      meanPulseWidth: mean(listWidth),
      meanAUC: mean(listAUC),
      meanAmp: mean(listAmp),
      validBeats: listRise.length,
    );
  }

  // --- CÁC HÀM PHỤ TRỢ (HELPER FUNCTIONS) ---

  /// Tìm index có giá trị nhỏ nhất trong khoảng [start, end)
  static int _argMin(List<double> x, int start, int end) {
    if (start >= end) return start;
    int minIdx = start;
    double minVal = x[start];
    for (int i = start + 1; i < end; i++) {
      if (x[i] < minVal) {
        minVal = x[i];
        minIdx = i;
      }
    }
    return minIdx;
  }

  /// Tìm điểm cắt (crossing) chính xác bằng nội suy tuyến tính
  /// Trả về double (ví dụ index 12.4) thay vì int
  static double? _findCrossingIndexSubsample(
    List<double> x,
    int start,
    int end,
    double level, {
    required bool rising,
  }) {
    int s = max(0, start);
    int e = min(x.length - 1, end);

    if (rising) {
      // Tìm đoạn x[i] <= level < x[i+1]
      for (int i = s; i < e; i++) {
        if (x[i] <= level && x[i + 1] > level) {
          return _interpolate(i, x[i], x[i + 1], level);
        }
      }
    } else {
      // Tìm đoạn x[i] >= level > x[i+1]
      for (int i = s; i < e; i++) {
        if (x[i] >= level && x[i + 1] < level) {
          return _interpolate(i, x[i], x[i + 1], level);
        }
      }
    }
    return null;
  }

  /// Công thức nội suy tuyến tính: x = i + (y_target - y1) / (y2 - y1)
  static double _interpolate(int i, double y1, double y2, double target) {
    if ((y2 - y1).abs() < 1e-9) return i.toDouble();
    return i + (target - y1) / (y2 - y1);
  }

  /// Tính AUC dùng quy tắc hình thang (Trapezoidal rule)
  static double _calculateAUC(
    List<double> x,
    int start,
    int end,
    double baseline,
  ) {
    double sum = 0;
    for (int i = start; i < end; i++) {
      // Chỉ tính phần diện tích nằm trên baseline
      double h1 = max(0, x[i] - baseline);
      double h2 = max(0, x[i + 1] - baseline);
      sum += (h1 + h2) / 2.0;
    }
    return sum;
  }
}
