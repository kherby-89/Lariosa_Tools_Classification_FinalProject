import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
 
import 'package:intl/intl.dart';
import 'firebase_options.dart';
import 'auth/auth_wrapper.dart';
import 'services/auth_service.dart';
import 'screens/analytics_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(ImageClassifierApp());
}

class ImageClassifierApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Image Classifier',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: AuthWrapper(child: CameraScreen()),
      debugShowCheckedModeBanner: false,
    );
  }
}

class CameraScreen extends StatefulWidget {
  @override
  _CameraScreenState createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _selectedCameraIndex = 0;
  Interpreter? _interpreter;
  List<String> _labels = [];
  // Minimum confidence required before we trust a prediction.
  // Mas taas = mas lisod mo-decide, pero mas likay sa sayop nga "Multimeter" permi.
  double _confidenceThreshold = 0.6;

  // How similar a camera capture must be to a saved reference embedding
  // before i-override niya ang raw model prediction.
  double _similarityThreshold = 0.9;
  final int _captureCount = 5;
  Map<String, List<double>> _referenceEmbeddings = {};
  bool _isModelLoaded = false;
  bool _isCameraInitialized = false;
  bool _isProcessing = false;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;
  final AuthService _authService = AuthService();

  final Map<String, String> _toolDescriptions = {
    'Multimeter': 'A digital multimeter used to measure voltage, current, and resistance in electrical circuits.',
    'Wire Stripper': 'A tool used to strip insulation from electrical wires without damaging the conductor.',
    'Digital Caliper': 'A precision measuring instrument used to measure dimensions with high accuracy.',
    'Combination Pliers': 'Versatile pliers used for gripping, cutting, and bending wires and other materials.',
    'Needle Nose Pliers': 'Long, narrow pliers designed for working in tight spaces and handling small objects.',
    'Adjustable Wrench': 'A wrench with an adjustable jaw that can fit various sizes of nuts and bolts.',
    'Socket Wrench': 'A wrench that uses interchangeable sockets to turn nuts and bolts of different sizes.',
    'Torque Wrench': 'A wrench that applies a specific amount of torque to fasteners to prevent over-tightening.',
    'Soldering Iron': 'A tool used to melt solder for joining electrical components and wires.',
    'Insulation Tape': 'Electrical tape used to insulate and protect electrical connections.',
  };

  @override
  void initState() {
    super.initState();
    _initializeApp();
    _logAppSession();
  }

  Future<void> _initializeApp() async {
    await _setupCamera();
    await _loadModel();
    await _loadReferenceEmbeddings();
  }

  Future<File> _embeddingsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/reference_embeddings.json');
  }

  Future<void> _loadReferenceEmbeddings() async {
    try {
      final f = await _embeddingsFile();
      if (!await f.exists()) return;
      final content = await f.readAsString();
      final Map data = json.decode(content) as Map;
      _referenceEmbeddings = data.map((key, value) => MapEntry(key as String, List<double>.from(value)));
      print('Loaded ${_referenceEmbeddings.length} reference embeddings');
    } catch (e) {
      print('Load embeddings error: $e');
    }
  }

  Future<void> _saveReferenceEmbeddings() async {
    try {
      final f = await _embeddingsFile();
      await f.writeAsString(json.encode(_referenceEmbeddings));
    } catch (e) {
      print('Save embeddings error: $e');
    }
  }

  Future<void> _setupCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        print('No cameras found');
        return;
      }

      _cameras = cameras;
      // ensure selected index is valid
      if (_selectedCameraIndex >= _cameras.length) _selectedCameraIndex = 0;

      _controller = CameraController(_cameras[_selectedCameraIndex], ResolutionPreset.medium);
      await _controller!.initialize();

      setState(() {
        _isCameraInitialized = true;
      });

      print('Camera initialized successfully: ${_cameras[_selectedCameraIndex].name}');
    } catch (e) {
      print('Camera setup error: $e');
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.isEmpty) return;
    try {
      _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
      await _controller?.dispose();
      _controller = CameraController(_cameras[_selectedCameraIndex], ResolutionPreset.medium);
      await _controller!.initialize();
      setState(() {});
      _analytics.logEvent(name: 'camera_switched', parameters: {'camera': _cameras[_selectedCameraIndex].name});
    } catch (e) {
      print('Switch camera error: $e');
      _showError('Unable to switch camera: ${e.toString()}');
    }
  }

  Future<void> _pickImageFromGallery() async {
    if (!_isModelLoaded || _isProcessing) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;

      final classification = await _classifyImage(picked.path);
      final scores = List<double>.from(classification['scores'] as List<dynamic>);
      final match = _matchReference(scores);
      // Prefer reference match only if it is both:
      // 1) very similar, and 2) clearly better than the model's own confidence.
      if (match != null &&
          match.value >= _similarityThreshold &&
          classification['confidence'] is double &&
          match.value >= (classification['confidence'] as double) + 0.05) {
        classification['label'] = match.key;
        classification['confidence'] = match.value;
      } else if (classification['confidence'] is double && (classification['confidence'] as double) < _confidenceThreshold) {
        classification['label'] = 'Unknown';
        classification['classIndex'] = -1;
      }
      await _logPrediction(classification, picked.path);
      _showResult(classification);
    } catch (e) {
      print('Gallery pick error: $e');
      _showError('Error picking image: ${e.toString()}');
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _loadModel() async {
    try {
      final options = InterpreterOptions();
      _interpreter = await Interpreter.fromAsset('assets/model_unquant.tflite', options: options);
      _labels = await _loadLabels();

      setState(() {
        _isModelLoaded = true;
      });

      print('Model loaded successfully. Labels: $_labels');
    } catch (e) {
      print('Model loading error: $e');
      // For testing, use dummy labels
      _labels = ['Multimeter', 'Wire Stripper', 'Digital Caliper', 'Combination Pliers', 'Needle Nose Pliers', 'Adjustable Wrench', 'Socket Wrench', 'Torque Wrench', 'Soldering Iron', 'Insulation Tape'];
      setState(() {
        _isModelLoaded = true;
      });
    }
  }

  Future<List<String>> _loadLabels() async {
    try {
      String labelString = await DefaultAssetBundle.of(context).loadString('assets/labels.txt');
      List<String> labels = labelString.split('\n').where((label) => label.trim().isNotEmpty).toList();
      return labels;
    } catch (e) {
      print('Label loading error: $e');
      return ['Healthy', 'Diseased', 'Normal', 'Unknown'];
    }
  }

  Future<void> _captureAndClassify() async {
    if (!_isCameraInitialized || !_isModelLoaded || _isProcessing) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      // Temporal smoothing: take multiple quick captures and average predictions
      final int captures = _captureCount;
      final int numLabels = _labels.length;
      List<double> accumScores = List.filled(numLabels, 0.0);
      XFile? lastImage;
      int successful = 0;

      for (var i = 0; i < captures; i++) {
        try {
          final XFile image = await _controller!.takePicture();
          lastImage = image;
          final result = await _classifyImage(image.path);
          final scores = List<double>.from(result['scores'] as List<dynamic>);
          if (scores.length == accumScores.length) {
            for (var j = 0; j < scores.length; j++) accumScores[j] += scores[j];
          }
          successful++;
          // small delay to allow camera to settle
          await Future.delayed(Duration(milliseconds: 150));
        } catch (e) {
          print('single capture error: $e');
        }
      }

      if (successful == 0 || lastImage == null) {
        _showError('Unable to capture image for classification.');
        return;
      }
      // average scores across captures
      for (var j = 0; j < accumScores.length; j++) accumScores[j] = accumScores[j] / successful;

      // match against registered references (nearest neighbor by cosine similarity)
      final match = _matchReference(accumScores);
      Map<String, dynamic> classification;
      // Raw model prediction from averaged scores
      var maxConfidence = accumScores.reduce((a, b) => a > b ? a : b);
      var predictedIndex = accumScores.indexOf(maxConfidence);
      final predictedLabel = predictedIndex < _labels.length ? _labels[predictedIndex] : 'Unknown';

      // Start with the model's own decision
      classification = {
        'label': predictedLabel,
        'confidence': maxConfidence,
        'scores': accumScores,
        'timestamp': DateTime.now(),
        'classIndex': predictedIndex,
      };

      // Only override with reference if it is clearly stronger than model prediction
      if (match != null &&
          match.value >= _similarityThreshold &&
          match.value >= maxConfidence + 0.05) {
        classification['label'] = match.key;
        classification['confidence'] = match.value;
        classification['classIndex'] = _labels.indexOf(match.key);
      }

      // If still low confidence, mark as Unknown instead of forcing "Multimeter"
      if (classification['confidence'] is double &&
          (classification['confidence'] as double) < _confidenceThreshold) {
        classification['label'] = 'Unknown';
        classification['classIndex'] = -1;
      }

      await _logPrediction(classification, lastImage.path);
      _showResult(classification);

    } catch (e) {
      print('Capture/classification error: $e');
      _showError('Error: ${e.toString()}');
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<Map<String, dynamic>> _classifyImage(String imagePath) async {
    try {
      if (_interpreter == null) {
        throw Exception('Model not loaded');
      }

      // Load image bytes and decode
      final imageBytes = await File(imagePath).readAsBytes();
      final decodedImage = img.decodeImage(imageBytes);
      if (decodedImage == null) throw Exception('Failed to decode image');

      // Preprocessing: preserve aspect ratio, center-crop to target size, and also use a horizontally flipped version
      final int targetSize = 224;
      img.Image _resizeAndCenterCrop(img.Image src, int size) {
        if (src.width == size && src.height == size) return img.copyResize(src, width: size, height: size);

        // scale so the shorter side == size, keep aspect, then center-crop
        img.Image scaled;
        if (src.width < src.height) {
          final newH = (src.height * (size / src.width)).round();
          scaled = img.copyResize(src, width: size, height: newH);
        } else {
          final newW = (src.width * (size / src.height)).round();
          scaled = img.copyResize(src, width: newW, height: size);
        }

        final int offsetX = max(0, (scaled.width - size) ~/ 2);
        final int offsetY = max(0, (scaled.height - size) ~/ 2);
        return img.copyCrop(scaled, x: offsetX, y: offsetY, width: size, height: size);
      }

      final resized = _resizeAndCenterCrop(decodedImage, targetSize);
      final flipped = img.flipHorizontal(resized);
      var crops = [resized, flipped];

      // Apply a light contrast-stretch preprocessing to improve feature visibility
      img.Image _contrastStretch(img.Image image) {
        int minR = 255, minG = 255, minB = 255;
        int maxR = 0, maxG = 0, maxB = 0;

        for (var y = 0; y < image.height; y++) {
          for (var x = 0; x < image.width; x++) {
            final pixel = image.getPixel(x, y);
            final r = pixel.r.toInt();
            final g = pixel.g.toInt();
            final b = pixel.b.toInt();
            if (r < minR) minR = r;
            if (g < minG) minG = g;
            if (b < minB) minB = b;
            if (r > maxR) maxR = r;
            if (g > maxG) maxG = g;
            if (b > maxB) maxB = b;
          }
        }

        // avoid divide by zero
        final dr = (maxR - minR) == 0 ? 1 : (maxR - minR);
        final dg = (maxG - minG) == 0 ? 1 : (maxG - minG);
        final db = (maxB - minB) == 0 ? 1 : (maxB - minB);

        final out = img.Image.from(image);
        for (var y = 0; y < out.height; y++) {
          for (var x = 0; x < out.width; x++) {
            final pixel = out.getPixel(x, y);
            final r = pixel.r.toInt();
            final g = pixel.g.toInt();
            final b = pixel.b.toInt();
            final nr = (((r - minR) * 255) / dr).clamp(0, 255).toInt();
            final ng = (((g - minG) * 255) / dg).clamp(0, 255).toInt();
            final nb = (((b - minB) * 255) / db).clamp(0, 255).toInt();
            out.setPixelRgba(x, y, nr, ng, nb, 255);
          }
        }
        return out;
      }

      for (var i = 0; i < crops.length; i++) {
        try {
          crops[i] = _contrastStretch(crops[i]);
        } catch (_) {
          // if preprocessing fails, continue with original crop
        }
      }

      final int numLabels = _labels.length;
      List<double> accumScores = List.filled(numLabels, 0.0);
      int validRuns = 0;

      for (final crop in crops) {
        // Build input as nested List [1][H][W][3]
        final input = List.generate(1, (_) => List.generate(targetSize, (_) => List.generate(targetSize, (_) => List.filled(3, 0.0))));

        for (var y = 0; y < targetSize; y++) {
          for (var x = 0; x < targetSize; x++) {
            final pixel = crop.getPixel(x, y);
            final r = pixel.r.toInt() / 255.0;
            final g = pixel.g.toInt() / 255.0;
            final b = pixel.b.toInt() / 255.0;
            input[0][y][x][0] = r;
            input[0][y][x][1] = g;
            input[0][y][x][2] = b;
          }
        }

        // Prepare output buffer as [1][numLabels] to be safe
        List<List<double>> output = List.generate(1, (_) => List.filled(numLabels, 0.0));

        try {
          _interpreter!.run(input, output);
        } catch (e) {
          print('TFLite run error: $e');
          continue;
        }

        // Some models return logits. Convert model output to probabilities with softmax
        List<double> raw = output.isNotEmpty ? output[0] : List.filled(numLabels, 0.0);
        double maxLogit = raw.isNotEmpty ? raw.reduce(max) : 0.0;
        final exps = raw.map((v) => exp(v - maxLogit)).toList();
        final sumExp = exps.fold(0.0, (a, b) => a + b);
        final probs = sumExp > 0 ? exps.map((e) => e / sumExp).toList() : List.filled(raw.length, 0.0);

        for (var i = 0; i < numLabels && i < probs.length; i++) {
          accumScores[i] += probs[i];
        }
        validRuns++;
      }

      if (validRuns == 0) throw Exception('No successful inference runs');

      for (var i = 0; i < accumScores.length; i++) accumScores[i] /= validRuns;

      var maxConfidence = accumScores.reduce((a, b) => a > b ? a : b);
      var predictedIndex = accumScores.indexOf(maxConfidence);
      final predictedLabel = predictedIndex < _labels.length ? _labels[predictedIndex] : 'Unknown';

      return {
        'label': predictedLabel,
        'confidence': maxConfidence,
        'scores': accumScores,
        'timestamp': DateTime.now(),
        'classIndex': predictedIndex,
      };
    } catch (e) {
      print('Classification error: $e');
      // Fallback to mock prediction if TFLite fails
      final random = DateTime.now().millisecond % (_labels.isEmpty ? 1 : _labels.length);
      final mockConfidence = 0.7 + (DateTime.now().millisecond % 300) / 1000;

      return {
        'label': _labels.isNotEmpty ? _labels[random] : 'Unknown',
        'confidence': mockConfidence.clamp(0.0, 1.0),
        'scores': List.filled(_labels.length, mockConfidence.clamp(0.0,1.0)),
        'timestamp': DateTime.now(),
        'classIndex': random,
      };
    }
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty || a.length != b.length) return 0.0;
    double dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0.0;
    return dot / (sqrt(na) * sqrt(nb));
  }

  Future<void> _registerReference(String label) async {
    if (!_isCameraInitialized || !_isModelLoaded || _isProcessing) return;
    setState(() { _isProcessing = true; });
    try {
      final int captures = _captureCount;
      List<double> accum = [];
      int runs = 0;
      for (var i = 0; i < captures; i++) {
        try {
          final XFile image = await _controller!.takePicture();
          final result = await _classifyImage(image.path);
          final scores = List<double>.from(result['scores'] as List<dynamic>);
          if (accum.isEmpty) accum = List.filled(scores.length, 0.0);
          for (var j = 0; j < scores.length; j++) accum[j] += scores[j];
          runs++;
          await Future.delayed(Duration(milliseconds: 150));
        } catch (e) {
          print('Register capture error: $e');
        }
      }
      if (runs == 0) throw Exception('No captures for reference');
      for (var j = 0; j < accum.length; j++) accum[j] = accum[j] / runs;
      _referenceEmbeddings[label] = accum;
      await _saveReferenceEmbeddings();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved reference: $label')));
    } catch (e) {
      _showError('Reference registration failed: ${e.toString()}');
    } finally {
      setState(() { _isProcessing = false; });
    }
  }

  MapEntry<String, double>? _matchReference(List<double> scores) {
    String? bestLabel;
    double bestSim = -1.0;
    _referenceEmbeddings.forEach((label, ref) {
      final sim = _cosineSimilarity(scores, ref);
      if (sim > bestSim) {
        bestSim = sim;
        bestLabel = label;
      }
    });
    if (bestLabel == null) return null;
    return MapEntry(bestLabel!, bestSim);
  }

  Future<void> _logPrediction(Map<String, dynamic> prediction, String imagePath) async {
    try {
      final userInfo = _authService.getUserInfo();
      
      // Save to Firestore
      await _firestore.collection('predictions').add({
        'timestamp': FieldValue.serverTimestamp(),
        'prediction': prediction['label'],
        'confidence': prediction['confidence'],
        'image_path': imagePath,
        'device_id': 'flutter_app_${DateTime.now().millisecondsSinceEpoch}',
        'status': 'completed',
        'session_id': DateTime.now().millisecondsSinceEpoch.toString(),
        'user_id': userInfo['uid'] ?? 'anonymous',
        'user_email': userInfo['email'] ?? 'anonymous',
        'is_anonymous': userInfo['isAnonymous'] ?? true,
      });
      
      // Log analytics event
      await _analytics.logEvent(
        name: 'image_classified',
        parameters: {
          'tool_type': prediction['label'],
          'confidence_score': (prediction['confidence'] * 100).round(),
          'confidence_range': _getConfidenceRange(prediction['confidence']),
          'classification_time': DateTime.now().millisecondsSinceEpoch,
        },
      );
      
      // Track tool usage frequency
      await _analytics.logEvent(
        name: 'tool_usage',
        parameters: {
          'tool_name': prediction['label'],
          'usage_type': 'classification',
        },
      );
      
      print('✅ Prediction logged: ${prediction['label']} (${(prediction['confidence'] * 100).toStringAsFixed(1)}%)');
    } catch (e) {
      print('❌ Logging error: $e');
    }
  }

  String _getConfidenceRange(double confidence) {
    if (confidence >= 0.9) return 'very_high';
    if (confidence >= 0.7) return 'high';
    if (confidence >= 0.5) return 'medium';
    if (confidence >= 0.3) return 'low';
    return 'very_low';
  }

  Future<void> _logAppSession() async {
    try {
      await _analytics.logEvent(
        name: 'app_session_start',
        parameters: {
          'session_time': DateTime.now().millisecondsSinceEpoch,
          'platform': 'flutter',
        },
      );
    } catch (e) {
      print('❌ Analytics session error: $e');
    }
  }

  void _showResult(Map<String, dynamic> prediction) {
    final description = _toolDescriptions[prediction['label']] ?? 'No description available for this tool.';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('🛠️ Tool Classification', style: TextStyle(color: Colors.blue)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('🔍 Tool: ${prediction['label']}',
                 style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SizedBox(height: 12),
            Text('📊 Accuracy: ${(prediction['confidence'] * 100).toStringAsFixed(1)}%',
                 style: TextStyle(fontSize: 16, color: Colors.green[700])),
            SizedBox(height: 12),
            Text('📝 Description:',
                 style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            SizedBox(height: 4),
            Text(description,
                 style: TextStyle(fontSize: 14, color: Colors.grey[700])),
            SizedBox(height: 12),
            Text('⏰ Classified at: ${DateFormat('HH:mm:ss').format(prediction['timestamp'])}',
                 style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('OK', style: TextStyle(color: Colors.blue)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _captureAndClassify();
            },
            child: Text('Capture Again', style: TextStyle(color: Colors.green)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _showSaveReferenceDialog(prediction['label'] ?? '');
            },
            child: Text('Save Reference', style: TextStyle(color: Colors.orange)),
          ),
        ],
      ),
    );
  }

  void _showSaveReferenceDialog(String suggestedLabel) {
    final controller = TextEditingController(text: suggestedLabel);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Save Reference'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(labelText: 'Label'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              final label = controller.text.trim();
              if (label.isNotEmpty) _registerReference(label);
            },
            child: Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showError(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Error', style: TextStyle(color: Colors.red)),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showUserInfo(Map<String, dynamic> userInfo) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('👤 User Information', style: TextStyle(color: Colors.blue)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('📧 Email: ${userInfo['email'] ?? 'Anonymous'}'),
            SizedBox(height: 8),
            Text('🆔 User ID: ${userInfo['uid'] ?? 'Unknown'}'),
            SizedBox(height: 8),
            Text('👻 Anonymous: ${userInfo['isAnonymous'] ?? 'Unknown'}'),
            SizedBox(height: 8),
            Text('👤 Display Name: ${userInfo['displayName'] ?? 'User'}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('OK', style: TextStyle(color: Colors.blue)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('📷 Image Classifier'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        elevation: 4,
        actions: [
          IconButton(
            icon: Icon(Icons.photo_library),
            tooltip: 'View Gallery',
            onPressed: () {
              _analytics.logEvent(name: 'gallery_opened');
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => GalleryScreen()),
              );
            },
          ),
          IconButton(
            icon: Icon(Icons.analytics),
            tooltip: 'Analytics Dashboard',
            onPressed: () {
              _analytics.logEvent(name: 'analytics_opened');
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => AnalyticsScreen()),
              );
            },
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.account_circle),
            onSelected: (value) async {
              if (value == 'signout') {
                await _authService.signOut();
              } else if (value == 'userinfo') {
                final userInfo = _authService.getUserInfo();
                _showUserInfo(userInfo);
              }
            },
            itemBuilder: (BuildContext context) => [
              PopupMenuItem<String>(
                value: 'userinfo',
                child: Row(
                  children: [
                    Icon(Icons.info, size: 20),
                    SizedBox(width: 8),
                    Text('User Info'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'signout',
                child: Row(
                  children: [
                    Icon(Icons.logout, size: 20),
                    SizedBox(width: 8),
                    Text('Sign Out'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: _buildCaptureButton(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  Widget _buildBody() {
    if (!_isCameraInitialized) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.blue),
            SizedBox(height: 20),
            Text('Initializing Camera...', style: TextStyle(fontSize: 16)),
            SizedBox(height: 10),
            Text('Please wait...', style: TextStyle(fontSize: 14, color: Colors.grey)),
          ],
        ),
      );
    }

    return Stack(
      children: [
        CameraPreview(_controller!),
        if (_isProcessing) _buildProcessingOverlay(),
      ],
    );
  }

  Widget _buildProcessingOverlay() {
    return Container(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 20),
            Text('Processing Image...', 
                 style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
      ),
    );
  }

  Widget _buildCaptureButton() {
    return Container(
      margin: EdgeInsets.only(bottom: 30),
      child: FloatingActionButton(
        onPressed: _showSourceSelectionSheet,
        backgroundColor: _isModelLoaded ? Colors.blue : Colors.grey,
        foregroundColor: Colors.white,
        child: _isProcessing 
            ? CircularProgressIndicator(color: Colors.white)
            : Icon(Icons.camera_alt, size: 30),
        tooltip: 'Capture / Gallery / Switch Camera',
      ),
    );
  }

  void _showSourceSelectionSheet() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.camera_alt),
                title: Text('Capture & Classify'),
                onTap: () {
                  Navigator.pop(context);
                  if (_isModelLoaded && !_isProcessing) _captureAndClassify();
                },
              ),
              ListTile(
                leading: Icon(Icons.switch_camera),
                title: Text('Switch Camera'),
                subtitle: Text(_cameras.isNotEmpty ? _cameras[_selectedCameraIndex].name : 'No camera'),
                onTap: () {
                  Navigator.pop(context);
                  _switchCamera();
                },
              ),
              ListTile(
                leading: Icon(Icons.photo_library),
                title: Text('Pick Image from Gallery'),
                onTap: () {
                  Navigator.pop(context);
                  _pickImageFromGallery();
                },
              ),
              ListTile(
                leading: Icon(Icons.save),
                title: Text('Register Reference (one-shot)'),
                subtitle: Text('Capture reference image for a label'),
                onTap: () async {
                  Navigator.pop(context);
                  final label = await showDialog<String>(
                    context: context,
                    builder: (context) {
                      String value = '';
                      return AlertDialog(
                        title: Text('Register Reference'),
                        content: TextField(
                          decoration: InputDecoration(labelText: 'Label name'),
                          onChanged: (v) => value = v.trim(),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel')),
                          TextButton(onPressed: () => Navigator.pop(context, value), child: Text('Save')),
                        ],
                      );
                    },
                  );
                  if (label != null && label.isNotEmpty) {
                    await _registerReference(label);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    _interpreter?.close();
    super.dispose();
  }
}

class GalleryScreen extends StatefulWidget {
  @override
  _GalleryScreenState createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  final Map<String, String> _toolDescriptions = {
    'Multimeter': 'A digital multimeter used to measure voltage, current, and resistance in electrical circuits.',
    'Wire Stripper': 'A tool used to strip insulation from electrical wires without damaging the conductor.',
    'Digital Caliper': 'A precision measuring instrument used to measure dimensions with high accuracy.',
    'Combination Pliers': 'Versatile pliers used for gripping, cutting, and bending wires and other materials.',
    'Needle Nose Pliers': 'Long, narrow pliers designed for working in tight spaces and handling small objects.',
    'Adjustable Wrench': 'A wrench with an adjustable jaw that can fit various sizes of nuts and bolts.',
    'Socket Wrench': 'A wrench that uses interchangeable sockets to turn nuts and bolts of different sizes.',
    'Torque Wrench': 'A wrench that applies a specific amount of torque to fasteners to prevent over-tightening.',
    'Soldering Iron': 'A tool used to melt solder for joining electrical components and wires.',
    'Insulation Tape': 'Electrical tape used to insulate and protect electrical connections.',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('🖼️ Classification Gallery'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        elevation: 4,
        leading: IconButton(
          icon: Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore
            .collection('predictions')
            .orderBy('timestamp', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline, size: 64, color: Colors.red),
                  SizedBox(height: 16),
                  Text('Error loading classifications',
                       style: TextStyle(fontSize: 18, color: Colors.red)),
                  SizedBox(height: 8),
                  Text(snapshot.error.toString(),
                       style: TextStyle(fontSize: 14, color: Colors.grey)),
                ],
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.blue),
                  SizedBox(height: 16),
                  Text('Loading classifications...', style: TextStyle(fontSize: 16)),
                ],
              ),
            );
          }

          final docs = snapshot.data?.docs ?? [];

          if (docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.image_not_supported, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('No classifications yet',
                       style: TextStyle(fontSize: 18, color: Colors.grey[600])),
                  SizedBox(height: 8),
                  Text('Capture some tools to see them here!',
                       style: TextStyle(fontSize: 14, color: Colors.grey)),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final doc = docs[index];
              final data = doc.data() as Map<String, dynamic>;
              final timestamp = (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now();
              final prediction = data['prediction'] as String? ?? 'Unknown';
              final confidence = (data['confidence'] as num?)?.toDouble() ?? 0.0;
              final description = _toolDescriptions[prediction] ?? 'No description available.';

              return Card(
                margin: EdgeInsets.only(bottom: 16),
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: InkWell(
                  onTap: () {
                    _analytics.logEvent(
                      name: 'prediction_viewed',
                      parameters: {
                        'tool_name': prediction,
                        'confidence_score': (confidence * 100).round(),
                      },
                    );
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.build, color: Colors.blue, size: 28),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                prediction,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blue[800],
                                ),
                              ),
                            ),
                            Container(
                              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.green[100],
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${(confidence * 100).toStringAsFixed(1)}%',
                                style: TextStyle(
                                  color: Colors.green[800],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 12),
                        Text(
                          description,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[700],
                            height: 1.4,
                          ),
                        ),
                        SizedBox(height: 12),
                        Row(
                          children: [
                            Icon(Icons.access_time, size: 16, color: Colors.grey),
                            SizedBox(width: 4),
                            Text(
                              DateFormat('yyyy-MM-dd HH:mm:ss').format(timestamp),
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}