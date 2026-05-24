import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceService {
  static final FaceService instance = FaceService._();
  FaceService._();

  static final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks: true,
      enableContours: true,
      enableClassification: true,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  // No-op — TFLite removed, ML Kit initialises lazily on first use
  Future<void> init() async {}

  // Convert CameraImage to InputImage for ML Kit
  static InputImage? cameraImageToInputImage(
    CameraImage image,
    CameraDescription camera,
  ) {
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: InputImageRotation.rotation0deg,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  // Detect faces in an InputImage (file path or bytes)
  static Future<List<Face>> detectFaces(InputImage inputImage) async {
    return _detector.processImage(inputImage);
  }

  // Generate a 128-d pseudo-embedding from ML Kit landmarks.
  // No TFLite required — uses normalised landmark positions + pairwise
  // distances, then L2-normalises to unit length for cosine matching.
  static List<double>? extractEmbedding(Face face) {
    final box = face.boundingBox;
    final w = box.width;
    final h = box.height;
    if (w <= 0 || h <= 0) return null;

    const landmarkTypes = [
      FaceLandmarkType.leftEye,
      FaceLandmarkType.rightEye,
      FaceLandmarkType.noseBase,
      FaceLandmarkType.leftEar,
      FaceLandmarkType.rightEar,
      FaceLandmarkType.leftCheek,
      FaceLandmarkType.rightCheek,
      FaceLandmarkType.leftMouth,
      FaceLandmarkType.rightMouth,
      FaceLandmarkType.bottomMouth,
    ];

    // Normalised (x, y) for each landmark — 20 values
    final pts = <double>[];
    for (final type in landmarkTypes) {
      final lm = face.landmarks[type];
      pts.add(lm != null ? (lm.position.x - box.left) / w : 0.5);
      pts.add(lm != null ? (lm.position.y - box.top) / h : 0.5);
    }

    // Pairwise Euclidean distances — 10×9/2 = 45 values
    final n = pts.length ~/ 2;
    final dist = <double>[];
    for (int i = 0; i < n; i++) {
      for (int j = i + 1; j < n; j++) {
        final dx = pts[i * 2] - pts[j * 2];
        final dy = pts[i * 2 + 1] - pts[j * 2 + 1];
        dist.add(sqrt(dx * dx + dy * dy));
      }
    }

    // 20 + 45 = 65 features; zero-pad to 128 for interface compatibility
    final raw = [...pts, ...dist];
    final vec = List<double>.filled(128, 0.0);
    for (int i = 0; i < raw.length && i < 128; i++) {
      vec[i] = raw[i];
    }

    // L2 normalise so cosine similarity == dot product
    final norm = sqrt(vec.fold(0.0, (s, v) => s + v * v));
    if (norm == 0) return vec;
    return vec.map((v) => v / norm).toList();
  }

  // Average multiple embeddings for robust registration
  List<double> averageEmbeddings(List<List<double>> embeddings) {
    if (embeddings.isEmpty) return List.filled(128, 0.0);
    final result = List<double>.filled(128, 0.0);
    for (final emb in embeddings) {
      for (int i = 0; i < 128 && i < emb.length; i++) {
        result[i] += emb[i];
      }
    }
    final n = embeddings.length.toDouble();
    return result.map((v) => v / n).toList();
  }

  void dispose() {
    _detector.close();
  }
}
