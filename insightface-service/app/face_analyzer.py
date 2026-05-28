"""
InsightFace ArcFace wrapper.

Uses the buffalo_sc / buffalo_l model pack.
- RetinaFace for detection + alignment
- ArcFace for 512-D L2-normalized embeddings
- All processing on CPU (onnxruntime)

Cosine similarity for L2-normalized vectors == dot product.
Score is mapped to [0, 1] via  (cosine + 1) / 2  so callers
can apply a threshold like 0.60 without worrying about sign.
"""

import logging
from typing import Optional

import cv2
import numpy as np
from insightface.app import FaceAnalysis

from .config import settings

logger = logging.getLogger(__name__)


class FaceAnalyzer:
    _app: Optional[FaceAnalysis] = None

    @classmethod
    def initialize(cls) -> None:
        if cls._app is not None:
            return
        logger.info(f"[InsightFace] Loading model '{settings.model_name}' …")
        app = FaceAnalysis(
            name=settings.model_name,
            providers=["CPUExecutionProvider"],
        )
        app.prepare(
            ctx_id=-1,
            det_size=(settings.det_size, settings.det_size),
        )
        cls._app = app
        logger.info("[InsightFace] Model ready.")

    # ── Image decoding ────────────────────────────────────────────────────────

    @classmethod
    def _decode(cls, image_bytes: bytes) -> Optional[np.ndarray]:
        arr = np.frombuffer(image_bytes, np.uint8)
        img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
        return img if img is not None else None

    # ── Quality gate ──────────────────────────────────────────────────────────

    @classmethod
    def _check_face_quality(cls, face) -> Optional[str]:
        """
        Returns None when the face passes all quality checks.
        Returns a rejection reason string otherwise.
        """
        # Detection confidence
        if float(face.det_score) < settings.min_det_score:
            return "low_detection_score"

        # Bounding box size
        x1, y1, x2, y2 = face.bbox
        w, h = x2 - x1, y2 - y1
        if w < settings.min_face_size_px or h < settings.min_face_size_px:
            return "face_too_small"

        # Head pose (pitch, yaw, roll in degrees)
        if face.pose is not None:
            pitch, yaw, roll = float(face.pose[0]), float(face.pose[1]), float(face.pose[2])
            if abs(yaw) > settings.max_yaw_deg:
                return "face_turned_sideways"
            if abs(pitch) > settings.max_pitch_deg:
                return "face_tilted_up_or_down"
            if abs(roll) > settings.max_roll_deg:
                return "face_tilted_roll"

        return None

    # ── Public API ────────────────────────────────────────────────────────────

    @classmethod
    def get_embedding(
        cls,
        image_bytes: bytes,
    ) -> dict:
        """
        Process a single image and return its ArcFace embedding.

        Returns:
          {
            "success": bool,
            "embedding": list[float] | None,   # 512-D, L2-normalized
            "quality": float,                   # detection score [0,1]
            "reason": str,                      # rejection reason or "ok"
          }
        """
        if cls._app is None:
            cls.initialize()

        img = cls._decode(image_bytes)
        if img is None:
            return {"success": False, "embedding": None, "quality": 0.0, "reason": "invalid_image"}

        faces = cls._app.get(img)

        if len(faces) == 0:
            return {"success": False, "embedding": None, "quality": 0.0, "reason": "no_face_detected"}
        if len(faces) > 1:
            return {"success": False, "embedding": None, "quality": 0.0, "reason": "multiple_faces"}

        face = faces[0]
        rejection = cls._check_face_quality(face)
        if rejection:
            return {"success": False, "embedding": None, "quality": float(face.det_score), "reason": rejection}

        # normed_embedding is already L2-normalized (unit vector)
        emb: np.ndarray = face.normed_embedding
        return {
            "success": True,
            "embedding": emb.tolist(),
            "quality": float(face.det_score),
            "reason": "ok",
        }

    @classmethod
    def average_embeddings(cls, embeddings: list[list[float]]) -> list[float]:
        """
        Compute the mean of multiple embeddings and re-normalize to unit length.
        This produces a representative embedding more robust than any single frame.
        """
        arr = np.array(embeddings, dtype=np.float32)
        mean = arr.mean(axis=0)
        norm = np.linalg.norm(mean)
        if norm == 0:
            return mean.tolist()
        return (mean / norm).tolist()

    # ── Similarity & matching ────────────────────────────────────────────────

    @staticmethod
    def cosine_similarity_01(a: np.ndarray, b: np.ndarray) -> float:
        """
        Cosine similarity mapped to [0, 1].
        For L2-normalized vectors: cos = dot(a, b)  ∈ [-1, 1]
        → (cos + 1) / 2  ∈  [0, 1]
        """
        cos = float(np.dot(a, b))
        return (cos + 1.0) / 2.0

    @classmethod
    def find_best_match(
        cls,
        query_embedding: list[float],
        candidates: dict,
    ) -> dict:
        """
        candidates: { student_id: { embedding: [512 floats], ...metadata... } }

        Returns a match result dict. Applies:
          - threshold check  (score >= settings.match_threshold)
          - margin check     (gap between #1 and #2 >= settings.margin_threshold)
        """
        if not candidates:
            return {"matched": False, "reason": "no_registered_faces"}

        query = np.array(query_embedding, dtype=np.float32)

        best_score: float = 0.0
        second_score: float = 0.0
        best_id: Optional[str] = None

        for sid, data in candidates.items():
            emb = np.array(data["embedding"], dtype=np.float32)
            score = cls.cosine_similarity_01(query, emb)
            if score > best_score:
                second_score = best_score
                best_score = score
                best_id = sid
            elif score > second_score:
                second_score = score

        if best_id is None or best_score < settings.match_threshold:
            return {
                "matched": False,
                "reason": "below_threshold",
                "best_score": round(best_score, 4),
                "threshold": settings.match_threshold,
            }

        margin = best_score - second_score
        n = len(candidates)
        if n > 1 and margin < settings.margin_threshold:
            return {
                "matched": False,
                "reason": "ambiguous_match",
                "best_score": round(best_score, 4),
                "margin": round(margin, 4),
                "threshold": settings.match_threshold,
            }

        meta = {k: v for k, v in candidates[best_id].items() if k != "embedding"}
        return {
            "matched": True,
            "student_id": best_id,
            "confidence": round(best_score, 4),
            "margin": round(margin, 4),
            "student": meta,
        }
