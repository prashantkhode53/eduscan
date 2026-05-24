import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class FaceService {
  static final FaceService instance = FaceService._();
  FaceService._();

  late final FaceDetector _detector;
  Interpreter? _interpreter;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _detector = FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks: true,
        enableClassification: true,
        enableTracking: true,
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.15,
      ),
    );
    _interpreter = await Interpreter.fromAsset('assets/models/mobilefacenet.tflite');
    _initialized = true;
  }

  Future<List<Face>> detectFaces(CameraImage cameraImage, InputImageRotation rotation) async {
    final inputImage = _cameraImageToInputImage(cameraImage, rotation);
    if (inputImage == null) return [];
    return _detector.processImage(inputImage);
  }

  InputImage? _cameraImageToInputImage(CameraImage cameraImage, InputImageRotation rotation) {
    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in cameraImage.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final inputImageData = InputImageMetadata(
        size: Size(cameraImage.width.toDouble(), cameraImage.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: cameraImage.planes[0].bytesPerRow,
      );

      return InputImage.fromBytes(bytes: bytes, metadata: inputImageData);
    } catch (_) {
      return null;
    }
  }

  Future<List<double>?> extractEmbedding(CameraImage cameraImage, Face face) async {
    if (_interpreter == null) return null;
    try {
      final box = face.boundingBox;

      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in cameraImage.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      img.Image? image = _decodeYuv420(bytes, cameraImage.width, cameraImage.height);
      if (image == null) return null;

      final left   = (box.left.toInt()).clamp(0, image.width - 1);
      final top    = (box.top.toInt()).clamp(0, image.height - 1);
      final width  = (box.width.toInt()).clamp(1, image.width - left);
      final height = (box.height.toInt()).clamp(1, image.height - top);

      final cropped = img.copyCrop(image, x: left, y: top, width: width, height: height);
      final resized = img.copyResize(cropped, width: 112, height: 112);

      final input = _imageToFloat32(resized);
      final output = List.filled(128, 0.0).reshape([1, 128]);

      _interpreter!.run(input.reshape([1, 112, 112, 3]), output);

      return List<double>.from(output[0] as List);
    } catch (_) {
      return null;
    }
  }

  img.Image? _decodeYuv420(Uint8List bytes, int width, int height) {
    try {
      final buffer = img.Image(width: width, height: height);
      final ySize = width * height;
      for (int j = 0; j < height; j++) {
        for (int i = 0; i < width; i++) {
          final y = bytes[j * width + i];
          final uvIndex = ySize + (j ~/ 2) * width + (i & ~1);
          final u = (uvIndex + 1 < bytes.length) ? bytes[uvIndex + 1] - 128 : 0;
          final v = (uvIndex < bytes.length) ? bytes[uvIndex] - 128 : 0;
          final r = (y + 1.402 * v).round().clamp(0, 255);
          final g = (y - 0.344136 * u - 0.714136 * v).round().clamp(0, 255);
          final b = (y + 1.772 * u).round().clamp(0, 255);
          buffer.setPixelRgba(i, j, r, g, b, 255);
        }
      }
      return buffer;
    } catch (_) {
      return null;
    }
  }

  Float32List _imageToFloat32(img.Image image) {
    final result = Float32List(1 * 112 * 112 * 3);
    int idx = 0;
    for (int y = 0; y < 112; y++) {
      for (int x = 0; x < 112; x++) {
        final pixel = image.getPixel(x, y);
        result[idx++] = (pixel.r / 127.5) - 1.0;
        result[idx++] = (pixel.g / 127.5) - 1.0;
        result[idx++] = (pixel.b / 127.5) - 1.0;
      }
    }
    return result;
  }

  List<double> averageEmbeddings(List<List<double>> embeddings) {
    if (embeddings.isEmpty) return [];
    final result = List<double>.filled(128, 0.0);
    for (final emb in embeddings) {
      for (int i = 0; i < 128; i++) {
        result[i] += emb[i];
      }
    }
    for (int i = 0; i < 128; i++) {
      result[i] /= embeddings.length;
    }
    return result;
  }

  double computeBrightnessScore(img.Image image) {
    double total = 0;
    int count = 0;
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        total += (pixel.r * 0.299 + pixel.g * 0.587 + pixel.b * 0.114) / 255.0;
        count++;
      }
    }
    return count > 0 ? total / count : 0.0;
  }

  void dispose() {
    _detector.close();
    _interpreter?.close();
    _initialized = false;
  }
}
