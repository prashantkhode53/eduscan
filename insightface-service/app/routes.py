"""
FastAPI route handlers for the InsightFace microservice.

Endpoints:
  POST /embed          — generate 512-D ArcFace embedding from one image
  POST /embed/batch    — generate embeddings from multiple images, return average
  POST /match          — match face against Redis-cached embeddings
  POST /cache/upsert   — add / update one student's embedding in Redis
  DELETE /cache/{id}   — remove one student's embedding from Redis
  POST /cache/reload   — reload all embeddings from PostgreSQL
  GET  /health         — liveness probe
"""

import base64
import logging
from typing import Annotated

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from pydantic import BaseModel

from .face_analyzer import FaceAnalyzer
from .redis_cache import (
    delete_embedding,
    get_all_embeddings,
    reload_from_db,
    set_embedding,
)

logger = logging.getLogger(__name__)
router = APIRouter()


# ── helpers ───────────────────────────────────────────────────────────────────

def _decode_image(file_bytes: bytes) -> bytes:
    return file_bytes


# ── /embed ────────────────────────────────────────────────────────────────────

@router.post("/embed")
async def embed_image(image: Annotated[UploadFile, File(description="JPEG/PNG face image")]):
    """
    Accept a single face image and return its 512-D ArcFace embedding.
    Used by Node.js during student registration.
    """
    image_bytes = await image.read()
    result = FaceAnalyzer.get_embedding(image_bytes)
    return result


class BatchEmbedRequest(BaseModel):
    images_b64: list[str]  # list of base64-encoded JPEG strings


@router.post("/embed/batch")
async def embed_batch(body: BatchEmbedRequest):
    """
    Accept multiple base64-encoded face images and return their averaged embedding.
    Rejects the whole batch if fewer than 1 valid embedding can be extracted.
    """
    embeddings: list[list[float]] = []
    rejections: list[str] = []

    for idx, b64 in enumerate(body.images_b64):
        try:
            img_bytes = base64.b64decode(b64)
        except Exception:
            rejections.append(f"image_{idx}: invalid_base64")
            continue

        result = FaceAnalyzer.get_embedding(img_bytes)
        if result["success"]:
            embeddings.append(result["embedding"])
        else:
            rejections.append(f"image_{idx}: {result['reason']}")

    if not embeddings:
        return {
            "success": False,
            "reason": "no_valid_embeddings",
            "rejections": rejections,
        }

    averaged = FaceAnalyzer.average_embeddings(embeddings)
    return {
        "success": True,
        "embedding": averaged,
        "samples_used": len(embeddings),
        "samples_rejected": rejections,
        "dimensions": len(averaged),
    }


# ── /match ────────────────────────────────────────────────────────────────────

@router.post("/match")
async def match_face(
    image: Annotated[UploadFile, File(description="JPEG/PNG face image to identify")],
):
    """
    Identify a face: extract embedding, compare against Redis-cached embeddings,
    return best match with confidence score.
    """
    image_bytes = await image.read()
    embed_result = FaceAnalyzer.get_embedding(image_bytes)

    if not embed_result["success"]:
        return {
            "success": True,
            "matched": False,
            "reason": embed_result["reason"],
            "quality": embed_result["quality"],
        }

    candidates = await get_all_embeddings()
    match_result = FaceAnalyzer.find_best_match(embed_result["embedding"], candidates)

    return {
        "success": True,
        "quality": embed_result["quality"],
        **match_result,
    }


# ── /cache ────────────────────────────────────────────────────────────────────

class UpsertCacheRequest(BaseModel):
    student_id: str
    embedding: list[float]       # 512-D, L2-normalized
    first_name: str
    last_name: str
    class_grade: str
    division: str
    roll_no: int | None = None


@router.post("/cache/upsert")
async def upsert_cache(body: UpsertCacheRequest):
    """
    Add or update a single student's embedding in Redis.
    Called by Node.js after a successful student registration.
    """
    await set_embedding(
        body.student_id,
        {
            "embedding": body.embedding,
            "first_name": body.first_name,
            "last_name": body.last_name,
            "class_grade": body.class_grade,
            "division": body.division,
            "roll_no": body.roll_no,
        },
    )
    return {"success": True, "student_id": body.student_id}


@router.delete("/cache/{student_id}")
async def remove_from_cache(student_id: str):
    """Remove a student's embedding from Redis (called on student deletion)."""
    await delete_embedding(student_id)
    return {"success": True, "student_id": student_id}


@router.post("/cache/reload")
async def reload_cache():
    """
    Full reload of Redis from PostgreSQL.
    Call this after bulk operations or when Redis is cleared.
    """
    loaded = await reload_from_db()
    return {"success": True, "loaded": loaded}


# ── /health ───────────────────────────────────────────────────────────────────

@router.get("/health")
async def health():
    from .face_analyzer import FaceAnalyzer
    from .config import settings
    return {
        "status": "ok",
        "model": settings.model_name,
        "ready": FaceAnalyzer._app is not None,
    }
