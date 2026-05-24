import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceService {
  static final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks: true,
      enableContours: true,
      enableClassification: true,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  static InputImage? cameraImageToInputImage(
    CameraImage image,
    CameraDescription camera,
  ) {
    final rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    if (rotation == null) return null;
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;
    if (image.planes.isEmpty) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  // Detect faces in camera frame
  static Future<List<Face>> detectFaces(InputImage inputImage) async {
    return _detector.processImage(inputImage);
  }

  // Generate a 128-D pseudo embedding from face landmarks (no TFLite needed)
  static List<double> generateEmbedding(Face face) {
    final List<double> embedding = List.filled(128, 0.0);
    int idx = 0;

    final box = face.boundingBox;
    embedding[idx++] = box.width / (box.height + 0.001);
    embedding[idx++] = box.left / 1000.0;
    embedding[idx++] = box.top / 1000.0;

    embedding[idx++] = (face.headEulerAngleX ?? 0) / 90.0;
    embedding[idx++] = (face.headEulerAngleY ?? 0) / 90.0;
    embedding[idx++] = (face.headEulerAngleZ ?? 0) / 90.0;

    embedding[idx++] = face.smilingProbability ?? 0.0;
    embedding[idx++] = face.leftEyeOpenProbability ?? 0.0;
    embedding[idx++] = face.rightEyeOpenProbability ?? 0.0;

    for (final type in FaceLandmarkType.values) {
      final landmark = face.landmarks[type];
      if (landmark != null && idx < 126) {
        embedding[idx++] = landmark.position.x / 1000.0;
        embedding[idx++] = landmark.position.y / 1000.0;
      } else {
        if (idx < 128) embedding[idx++] = 0.0;
        if (idx < 128) embedding[idx++] = 0.0;
      }
    }

    return _normalize(embedding);
  }

  // Average multiple embeddings for better accuracy during registration
  static List<double> averageEmbeddings(List<List<double>> embeddings) {
    if (embeddings.isEmpty) return List.filled(128, 0.0);
    final avg = List<double>.filled(128, 0.0);
    for (final e in embeddings) {
      for (int i = 0; i < 128; i++) {
        avg[i] += e[i];
      }
    }
    for (int i = 0; i < 128; i++) {
      avg[i] /= embeddings.length;
    }
    return _normalize(avg);
  }

  // Cosine similarity between two embeddings
  static double cosineSimilarity(List<double> a, List<double> b) {
    double dot = 0, magA = 0, magB = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      magA += a[i] * a[i];
      magB += b[i] * b[i];
    }
    if (magA == 0 || magB == 0) return 0;
    return dot / (sqrt(magA) * sqrt(magB));
  }

  static List<double> _normalize(List<double> v) {
    final mag = sqrt(v.fold(0.0, (sum, x) => sum + x * x));
    if (mag == 0) return v;
    return v.map((x) => x / mag).toList();
  }

  static void dispose() {
    _detector.close();
  }
}
