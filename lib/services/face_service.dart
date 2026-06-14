import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceService {
  // Accurate detector with full geometry — used only during student registration.
  static final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks:      true,
      enableContours:       true,
      enableClassification: true,
      performanceMode:      FaceDetectorMode.accurate,
    ),
  );

  // Fast, lightweight detector — used during live attendance scanning.
  // Contours/landmarks are not needed here; scanQualityHint only reads
  // headEulerAngle* and boundingBox, both available in fast mode.
  static final FaceDetector _scanDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks:      false,
      enableContours:       false,
      enableClassification: false,
      performanceMode:      FaceDetectorMode.fast,
    ),
  );

  static InputImage? cameraImageToInputImage(
    CameraImage image,
    CameraDescription camera,
  ) {
    final rotation =
        InputImageRotationValue.fromRawValue(camera.sensorOrientation);
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

  /// Full-accuracy detection — use during student registration only.
  static Future<List<Face>> detectFaces(InputImage inputImage) async {
    return _detector.processImage(inputImage);
  }

  /// Fast detection — use during live attendance scanning.
  /// Skips contours/landmarks; only euler angles and bounding box are needed.
  static Future<List<Face>> detectFacesForScan(InputImage inputImage) async {
    return _scanDetector.processImage(inputImage);
  }

  /// Generates a 128-D embedding that is invariant to:
  ///   - Translation  (eye midpoint used as origin)
  ///   - Scale        (inter-ocular distance used as unit)
  ///   - In-plane rotation  (Procrustes: eye-line rotated to horizontal)
  ///
  /// NOTE: Changing this function invalidates all previously stored embeddings.
  static List<double> generateEmbedding(Face face) {
    final lE  = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final rE  = face.landmarks[FaceLandmarkType.rightEye]?.position;
    final nos = face.landmarks[FaceLandmarkType.noseBase]?.position;
    final lM  = face.landmarks[FaceLandmarkType.leftMouth]?.position;
    final rM  = face.landmarks[FaceLandmarkType.rightMouth]?.position;
    final bM  = face.landmarks[FaceLandmarkType.bottomMouth]?.position;
    final lEr = face.landmarks[FaceLandmarkType.leftEar]?.position;
    final rEr = face.landmarks[FaceLandmarkType.rightEar]?.position;
    final lCh = face.landmarks[FaceLandmarkType.leftCheek]?.position;
    final rCh = face.landmarks[FaceLandmarkType.rightCheek]?.position;

    // Reference: eye midpoint as origin, inter-ocular distance as scale
    double cx, cy, iod;
    if (lE != null && rE != null) {
      cx  = (lE.x + rE.x) / 2.0;
      cy  = (lE.y + rE.y) / 2.0;
      iod = sqrt(pow(rE.x - lE.x, 2) + pow(rE.y - lE.y, 2));
    } else {
      cx  = face.boundingBox.center.dx;
      cy  = face.boundingBox.center.dy;
      iod = face.boundingBox.width.toDouble();
    }
    iod = max(iod, 1.0);

    // Procrustes rotation: rotate so the eye-line is always horizontal.
    // angle = 0 means rE is directly to the right of lE (no tilt).
    double cosA = 1.0, sinA = 0.0;
    if (lE != null && rE != null) {
      final angle = atan2((rE.y - lE.y).toDouble(), (rE.x - lE.x).toDouble());
      cosA =  cos(-angle);
      sinA =  sin(-angle);
    }

    // Normalize + rotate: translate to eye-center, scale by IOD, then rotate.
    List<double> np(Point<int>? p) {
      if (p == null) return [0.0, 0.0];
      final dx = (p.x - cx) / iod;
      final dy = (p.y - cy) / iod;
      return [dx * cosA - dy * sinA, dx * sinA + dy * cosA];
    }

    // Normalized Euclidean distance — rotation-invariant (distances don't change under rotation).
    double nd(Point<int>? a, Point<int>? b) {
      if (a == null || b == null) return 0.0;
      return sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2)) / iod;
    }

    final v = <double>[];

    // === Block 1: Normalized + rotated landmark positions (10 × 2 = 20) ===
    for (final p in [lE, rE, nos, lM, rM, bM, lEr, rEr, lCh, rCh]) {
      v.addAll(np(p));
    }

    // === Block 2: Pairwise geometric ratios (24) ===
    v.addAll([
      nd(lE,  rE),   // inter-ocular (= 1.0, baseline)
      nd(lE,  nos),  // left eye → nose
      nd(rE,  nos),  // right eye → nose
      nd(lE,  lM),   // left eye → left mouth corner
      nd(rE,  rM),   // right eye → right mouth corner
      nd(nos, bM),   // nose → bottom mouth (philtrum length)
      nd(lM,  rM),   // mouth width
      nd(lEr, rEr),  // ear-to-ear distance
      nd(lE,  lEr),  // left eye → left ear
      nd(rE,  rEr),  // right eye → right ear
      nd(lCh, rCh),  // cheek width
      nd(lE,  lCh),  // left eye → left cheek
      nd(rE,  rCh),  // right eye → right cheek
      nd(nos, lCh),  // nose → left cheek
      nd(nos, rCh),  // nose → right cheek
      nd(bM,  lCh),  // bottom mouth → left cheek
      nd(bM,  rCh),  // bottom mouth → right cheek
      nd(lM,  lCh),  // left mouth → left cheek
      nd(rM,  rCh),  // right mouth → right cheek
      nd(lEr, lCh),  // left ear → left cheek
      nd(rEr, rCh),  // right ear → right cheek
      nd(lE,  bM),   // left eye → bottom mouth (total face height)
      nd(rE,  bM),   // right eye → bottom mouth
      nd(nos, lEr),  // nose → left ear
    ]);

    // === Blocks 3–9: Contour samples (84 features) ===
    _addContour(v, face.contours[FaceContourType.face],           14, cx, cy, iod, cosA, sinA);
    _addContour(v, face.contours[FaceContourType.leftEye],         6, cx, cy, iod, cosA, sinA);
    _addContour(v, face.contours[FaceContourType.rightEye],        6, cx, cy, iod, cosA, sinA);
    _addContour(v, face.contours[FaceContourType.upperLipTop],     5, cx, cy, iod, cosA, sinA);
    _addContour(v, face.contours[FaceContourType.lowerLipBottom],  4, cx, cy, iod, cosA, sinA);
    _addContour(v, face.contours[FaceContourType.noseBridge],      4, cx, cy, iod, cosA, sinA);
    _addContour(v, face.contours[FaceContourType.noseBottom],      3, cx, cy, iod, cosA, sinA);
    // 28+12+12+10+8+8+6 = 84

    while (v.length < 128) v.add(0.0);

    final result = _normalize(v.sublist(0, 128));
    debugPrint('[FaceService] embedding norm=${_magnitude(result).toStringAsFixed(4)} iod=${iod.toStringAsFixed(1)}');
    return result;
  }

  /// Sample [n] evenly-spaced normalized+rotated points from a face contour.
  static void _addContour(
    List<double> v,
    FaceContour? contour,
    int n,
    double cx,
    double cy,
    double iod,
    double cosA,
    double sinA,
  ) {
    if (contour == null || contour.points.isEmpty) {
      for (int i = 0; i < n * 2; i++) v.add(0.0);
      return;
    }
    final pts = contour.points;
    for (int i = 0; i < n; i++) {
      final idx = (i * pts.length ~/ n).clamp(0, pts.length - 1);
      final dx = (pts[idx].x - cx) / iod;
      final dy = (pts[idx].y - cy) / iod;
      v.add(dx * cosA - dy * sinA);
      v.add(dx * sinA + dy * cosA);
    }
  }

  /// Average multiple embeddings (all must be unit-normalized before averaging).
  static List<double> averageEmbeddings(List<List<double>> embeddings) {
    if (embeddings.isEmpty) return List.filled(128, 0.0);
    final avg = List<double>.filled(128, 0.0);
    for (final e in embeddings) {
      for (int i = 0; i < min(128, e.length); i++) {
        avg[i] += e[i];
      }
    }
    for (int i = 0; i < 128; i++) {
      avg[i] /= embeddings.length;
    }
    return _normalize(avg);
  }

  /// Cosine similarity in [0, 1] — 1 = identical, 0 = orthogonal.
  static double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0.0;
    double dot = 0, magA = 0, magB = 0;
    for (int i = 0; i < a.length; i++) {
      dot  += a[i] * b[i];
      magA += a[i] * a[i];
      magB += b[i] * b[i];
    }
    if (magA == 0 || magB == 0) return 0.0;
    return (dot / (sqrt(magA) * sqrt(magB))).clamp(0.0, 1.0);
  }

  /// Returns null when [face] is good enough for a reliable scan embedding.
  /// Returns a user-facing hint string when the frame should be skipped.
  /// Thresholds are intentionally lenient (vs. registration) so the kiosk
  /// doesn't frustrate users standing at normal distance.
  static String? scanQualityHint(Face face) {
    final yaw   = (face.headEulerAngleY ?? 0.0).abs(); // left–right turn
    final roll  = (face.headEulerAngleZ ?? 0.0).abs(); // clockwise tilt
    final pitch = (face.headEulerAngleX ?? 0.0).abs(); // up–down nod
    if (yaw > 30)   return 'Look straight at the camera';
    if (roll > 25)  return 'Hold your head level';
    if (pitch > 30) return 'Raise your chin — face the camera straight';
    if (face.boundingBox.width < 60) return 'Move closer to the camera';
    return null;
  }

  static List<double> _normalize(List<double> v) {
    final mag = _magnitude(v);
    if (mag == 0) return v;
    return v.map((x) => x / mag).toList();
  }

  static double _magnitude(List<double> v) =>
      sqrt(v.fold(0.0, (s, x) => s + x * x));

  static void dispose() {
    _detector.close();
    _scanDetector.close();
  }
}
