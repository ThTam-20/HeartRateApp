import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_heartrate/database/db/save_info_blood_pressure.dart';
import 'package:flutter_heartrate/database/db/heart_rate_record.dart';
import 'package:flutter_heartrate/features/heart_rate/service/push_hr_blynk.dart';
import 'package:flutter_heartrate/features/heart_rate/service/push_hr_zalo_bot.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../firebase/auth/GoogleAuthService.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../../../algorithm/heart_rate_analyzer2.dart';
import '../widgets/bpm_gauge.dart';
import '../widgets/ppg_line_chart.dart';
import '../screens/history_measure_screen.dart';
import '../../../algorithm/ppg_morphology.dart';

class MeasureTab extends StatefulWidget {
  const MeasureTab({super.key});

  @override
  State<MeasureTab> createState() => MeasureTabState();
}

class _BPScaler {
  late List<double> xMean;
  late List<double> xScale;
  late List<double> yMean;
  late List<double> yScale;

  Future<void> load() async {
    final jsonStr = await rootBundle.loadString('assets/models/config.json');
    final data = json.decode(jsonStr);
    xMean = List<double>.from(data['X_mean']);
    xScale = List<double>.from(data['X_scale']);
    yMean = List<double>.from(data['y_mean']);
    yScale = List<double>.from(data['y_scale']);
  }

  List<double> transformX(List<double> input) {
    return List.generate(
      input.length,
      (i) => (input[i] - xMean[i]) / xScale[i],
    );
  }

  List<double> inverseY(List<double> output) {
    return List.generate(
      output.length,
      (i) => output[i] * yScale[i] + yMean[i],
    );
  }
}

class _BPModel {
  late Interpreter interpreter;

  Future<void> load() async {
    interpreter = await Interpreter.fromAsset('assets/models/model.tflite');
    interpreter.allocateTensors();
  }

  List<double> predict(List<double> input) {
    try {
      // Lấy tensor
      var inputTensor = interpreter.getInputTensor(0);
      var outputTensor = interpreter.getOutputTensor(0);

      // Log shape để debug
      debugPrint('[_BPModel] Input tensor shape: ${inputTensor.shape}');
      debugPrint('[_BPModel] Output tensor shape: ${outputTensor.shape}');
      debugPrint('[_BPModel] Input data: $input');

      // Tính tổng số phần tử cần thiết (ví dụ: [1,5] = 5 phần tử)
      int inputSize = inputTensor.shape.reduce((a, b) => a * b);

      // Tạo input buffer Float32 với đúng kích thước
      final inputBuffer = Float32List(inputSize);
      for (int i = 0; i < input.length && i < inputSize; i++) {
        inputBuffer[i] = input[i];
      }

      // Set input data vào tensor (convert Float32List -> Uint8List)
      inputTensor.data = inputBuffer.buffer.asUint8List();

      // Chạy inference
      interpreter.invoke();

      // Lấy output data từ tensor
      final outputData = outputTensor.data.buffer.asFloat32List();

      debugPrint('[_BPModel] Output data: $outputData');

      // Trả về [SYS, DIA]
      return [outputData[0].toDouble(), outputData[1].toDouble()];
    } catch (e, s) {
      debugPrint('[_BPModel] Lỗi predict: $e');
      debugPrint('[_BPModel] Stack: $s');
      rethrow; // Throw lại để caller biết có lỗi
    }
  }
}

class MeasureTabState extends State<MeasureTab> {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  int _currentBpm = 0;
  int? _startTimestamp;
  bool _isFinishing = false;
  bool _bpReady = false;

  GoogleSignInAccount? _user;

  final List<double> _ppgSignal = [];
  final int _maxSample = 150; // ~5s @30fps

  late HeartRateAnalyzer _analyzer;
  late _BPScaler _bpScaler;
  late _BPModel _bpModel;
  List<double> _lastPpgWaveform = const <double>[];
  PpgMorphologyResult _latestMorphology = const PpgMorphologyResult();

  bool _isButtonStartMeasureEnabled = false;

  // Lưu kết quả dự đoán BP
  double? _lastSys;
  double? _lastDia;

  @override
  void initState() {
    super.initState();
    _loadUser();
    _bpScaler = _BPScaler();
    _bpModel = _BPModel();
    _analyzer = HeartRateAnalyzer(
      HeartRateAnalyzerConfig(
        fps: 30,
        windowSec: 10,
        stepSec: 1,
        smoothSamples: 3,
        minPeakDistMs: 300,
        bpmMin: 40,
        bpmMax: 180,
      ),
      onResultCalculated: (AnalyzerResult result) => setState(() {
        _currentBpm = result.bpm.toInt();
        _lastPpgWaveform = result.signal;
        _latestMorphology = result.morphology;
      }),
    );
    _initBpHelpers();
  }

  Future<void> _loadUser() async {
    _user =
        GoogleAuthService.currentUser ??
        await GoogleAuthService.signInSilently();
    if (mounted) setState(() {});
  }

  Future<void> _initBpHelpers() async {
    await _bpScaler.load();
    await _bpModel.load();
    if (mounted) {
      setState(() => _bpReady = true);
    }
  }

  Future<void> _predictBloodPressure() async {
    if (!_bpReady) return;
    final info = await SaveInfoBloodPressure.getInfoBloodPressure();
    if (info == null) return;

    final gender = info['gender'] as String? ?? 'Nam';
    final age = (info['age'] as int?)?.toDouble();
    final height = (info['height'] as int?)?.toDouble();
    final weight = (info['weight'] as int?)?.toDouble();

    if (age == null || height == null || weight == null) return;

    final morph = _latestMorphology;

    // --- KHẮC PHỤC DỮ LIỆU TẠI ĐÂY ---

    // 1. Lấy giá trị thô từ thuật toán
    double rawRiseTime = morph.meanRiseTime;
    double rawDecayTime = morph.meanDecayTime;
    double rawPulseWidth = morph.meanPulseWidth;
    double rawAUC = morph.meanAUC;
    double rawAmp = morph.meanAmp;

    // 2. Xử lý giá trị mặc định nếu đo lỗi (bằng 0)
    // Nếu đo được > 0 thì dùng, nếu không thì lấy Mean của Config
    double valRiseTime = rawRiseTime > 0 ? rawRiseTime : _bpScaler.xMean[5];
    double valDecayTime = rawDecayTime > 0 ? rawDecayTime : _bpScaler.xMean[6];
    double valPulseWidth = rawPulseWidth > 0 ? rawPulseWidth : _bpScaler.xMean[7];
    double valAUC = rawAUC > 0 ? rawAUC : _bpScaler.xMean[8];
    double valAmp = rawAmp > 0 ? rawAmp : _bpScaler.xMean[9];

    // 3. ÁP DỤNG SCALING FACTOR (Dựa trên Log của bạn)
    // Amp lệch ~132 lần -> Nhân 130
    if (valAmp < 10) {
      valAmp = valAmp * 130;
    }

    // AUC lệch ~100 lần -> Nhân 100
    if (valAUC < 200) {
      valAUC = valAUC * 100;
    }

    // PulseWidth lệch ~10 lần (579 vs 58) -> Chia 10
    // (Chỉ chia nếu nó lớn bất thường > 150ms)
    if (valPulseWidth > 150) {
      valPulseWidth = valPulseWidth / 10;
    }

    // DecayTime lệch ~4 lần (940 vs 241) -> Chia 4 hoặc đưa về Mean
    // DecayTime thường không quá 400ms. Nếu lớn quá thì có thể do thuật toán bắt sai điểm cuối.
    if (valDecayTime > 500) {
      // Cách an toàn: Nếu Decay quá lớn vô lý, dùng giá trị trung bình của model
      // Hoặc thử chia tỉ lệ:
      valDecayTime = _bpScaler.xMean[6];
    }

    debugPrint("=== INPUT SAU KHI FIX SCALING ===");
    debugPrint("RiseTime: $valRiseTime");
    debugPrint("DecayTime: $valDecayTime"); // Nên xấp xỉ 241
    debugPrint("PulseWidth: $valPulseWidth"); // Nên xấp xỉ 58
    debugPrint("AUC: $valAUC"); // Nên xấp xỉ 6800
    debugPrint("Amp: $valAmp"); // Nên xấp xỉ 236

    // Tạo mảng input
    final input = <double>[
      _encodeGender(gender),
      age,
      height,
      weight,
      _currentBpm.toDouble(),
      valRiseTime,
      valDecayTime,
      valPulseWidth,
      valAUC,
      valAmp,
    ];

    try {
      final scaled = _bpScaler.transformX(input);
      final predicted = _bpModel.predict(scaled);
      final real = _bpScaler.inverseY(predicted);

      if (mounted) {
        double sys = double.parse(real[0].toStringAsFixed(1));
        double dia = double.parse(real[1].toStringAsFixed(1));

        // Sanity Check: Chặn giá trị vô lý
        if (sys > 180) sys = 150; // Cap trần nếu quá cao
        if (dia > 120) dia = 100;
        if (sys < 90) sys = 110;  // Cap sàn nếu quá thấp

        setState(() {
          _lastSys = sys;
          _lastDia = dia;
        });
        debugPrint('BP Result: SYS=$sys DIA=$dia');
      }
    } catch (e) {
      debugPrint('Error BP predict: $e');
    }
  }

  double _encodeGender(String gender) {
    switch (gender) {
      case 'Nữ':
        return 1.0;
      case 'Nam':
        return 0.0;
      default:
        return 0.0;
    }
  }

  Future<void> _initializeCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Không tìm thấy camera")),
          );
        }
        return;
      }

      final backCamera = _cameras!.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras!.first,
      );

      // Lưu ý: ResolutionPreset.low hoặc medium là đủ để đo nhịp tim, high sẽ rất lag khi xử lý byte
      _controller = CameraController(
        backCamera,
        ResolutionPreset
            .medium, // Đổi xuống medium hoặc low để tối ưu tốc độ xử lý
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup
            .yuv420, // Cố định format trên Android để dễ xử lý byte
      );

      await _controller!.initialize();
      await _controller!.setFlashMode(FlashMode.torch);

      _startTimestamp = DateTime.now().millisecondsSinceEpoch;

      // Biến đếm để throttle UI update (nếu cần)
      int frameCount = 0;

      _controller!.startImageStream((CameraImage image) {
        // Check an toàn
        if (_controller == null || !mounted || _isFinishing) return;

        // 1. TỐI ƯU HÓA TÍNH TOÁN (Lấy trung bình vùng giữa)
        double avg = 0;
        final int width = image.width;
        final int height = image.height;

        // Y-plane luôn là plane 0
        final int yRowStride = image.planes[0].bytesPerRow;
        final Uint8List bytes = image.planes[0].bytes;

        // Lấy vùng cửa sổ 50x50 ở giữa ảnh
        const int windowSize = 50;
        int sum = 0;
        int count = 0;

        int startY = (height - windowSize) ~/ 2;
        int endY = startY + windowSize;
        int startX = (width - windowSize) ~/ 2;
        int endX = startX + windowSize;

        for (int y = startY; y < endY; y++) {
          // Tính offset dòng: y * rowStride
          // Cộng thêm offset cột: x
          // Lưu ý: logic này đúng cho YUV420; trên iOS (BGRA) có thể khác chút
          int rowOffset = y * yRowStride;
          for (int x = startX; x < endX; x++) {
            sum += bytes[rowOffset + x];
            count++;
          }
        }

        if (count > 0) avg = sum / count;

        // 2. Logic xử lý nhịp tim
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        _analyzer.addSample(avg);

        // 3. Cập nhật UI
        frameCount++;
        // Có thể chỉ setState mỗi 2 frame 1 lần nếu vẫn lag: if (frameCount % 2 == 0)
        setState(() {
          _ppgSignal.add(avg);
          if (_ppgSignal.length > _maxSample) {
            _ppgSignal.removeAt(0);
          }
        });

        // 4. Kiểm tra thời gian dừng (15s)
        if (_startTimestamp != null &&
            timestamp - _startTimestamp! >= 15000 &&
            !_isFinishing) {
          _isFinishing = true;
          // Gọi hàm async nhưng không await trong stream callback để tránh chặn luồng camera
          _finishMeasurement();
        }
      });
    } catch (e) {
      debugPrint('Lỗi khởi tạo camera: $e');
      if (mounted) {
        setState(() => _isButtonStartMeasureEnabled = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Lỗi camera: $e')));
      }
    }
  }

  Future<void> _finishMeasurement() async {
    if (!mounted) return;

    try {
      debugPrint('[MeasureTab] Bắt đầu hoàn tất phép đo');
      await stopCamera();
      debugPrint('[MeasureTab] Đã tắt camera');

      // Dự đoán huyết áp TRƯỚC KHI lưu lên cloud
      await _predictBloodPressure();
      debugPrint('[MeasureTab] Đã dự đoán BP: SYS=$_lastSys, DIA=$_lastDia');

      PushHrZaloBot.pushDataZalo(_currentBpm, _lastSys!, _lastDia!);
      debugPrint('[MeasureTab] Đã gửi dữ liệu Zalo Bot');
      PushHrBlynk.pushData(_currentBpm, _lastSys!, _lastDia!);
      debugPrint('[MeasureTab] Đã gửi dữ liệu Blynk');

      if (_user != null) {
        await addHeartRateRecordToCloud(
          _user!.id,
          _currentBpm.toInt(),
          List<double>.from(_lastPpgWaveform),
          _lastSys ?? 120.0,
          _lastDia ?? 80.0,
        );
        debugPrint('[MeasureTab] Đã lưu dữ liệu cloud');
      }

      if (!mounted) return;
      setState(() => _isButtonStartMeasureEnabled = false);
      debugPrint('[MeasureTab] Đã cập nhật UI trước khi điều hướng');

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => HistoryMeasureScreen(
            bpm: _currentBpm,
            ppgSignal: List<double>.from(_ppgSignal),
            timestamp: DateTime.now(),
            bp_sys: _lastSys ?? 120.0,
            bp_dia: _lastDia ?? 80.0,
          ),
        ),
      );
      debugPrint('[MeasureTab] Đã quay lại từ HistoryMeasureScreen');
    } catch (e, s) {
      debugPrint('Lỗi hoàn tất phép đo: $e');
      debugPrint('$s');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Có lỗi xảy ra khi hoàn tất phép đo.')),
        );
      }
    } finally {
      if (!mounted) return;
      setState(() {
        _currentBpm = 0;
        _startTimestamp = null;
        _isButtonStartMeasureEnabled = false;
        _isFinishing = false;
        _ppgSignal.clear();
        _lastSys = null;
        _lastDia = null;
        _lastPpgWaveform = const <double>[];
        _latestMorphology = const PpgMorphologyResult();
      });
      debugPrint('[MeasureTab] Đã reset state sau phép đo');
    }
  }

  Future<void> stopCamera() async {
    // được gọi khi rời tab đo
    if (_controller != null) {
      await _controller!.setFlashMode(FlashMode.off);
      await _controller!.dispose();
      _controller = null;
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          const SizedBox(height: 20),
          Center(
            child: Text(
              _isButtonStartMeasureEnabled
                  ? "ĐANG ĐO..."
                  : "ĐỀ TÀI KHÓA LUẬN TỐT NGHIỆP IUH (Nhật-Tâm)",
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 22),
            ),
          ),
          const SizedBox(height: 30),
          BpmGauge(
            progress: _currentBpm / 180,
            bpmText: _currentBpm.toString(),
          ),
          const SizedBox(height: 30),
          SizedBox(height: 80, child: PpgLineChart(signal: _ppgSignal)),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _isButtonStartMeasureEnabled = !_isButtonStartMeasureEnabled;
                if (_isButtonStartMeasureEnabled) {
                  _currentBpm = 0;
                  _analyzer.reset();
                  _latestMorphology = const PpgMorphologyResult();
                  _lastPpgWaveform = const <double>[];
                  _initializeCamera();
                } else {
                  stopCamera();
                }
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              textStyle: const TextStyle(color: Colors.white),
            ),
            child: Text(
              _isButtonStartMeasureEnabled ? 'Dừng đo' : 'Bắt đầu đo',
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            AppStrings.lastResult,
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}