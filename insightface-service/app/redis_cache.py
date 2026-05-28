"""
Redis embedding cache.

Schema:
  Key:   face_emb:{student_id}
  Value: JSON  { embedding: [512 floats], first_name, last_name, class_grade, division, roll_no }

All embeddings are loaded into Redis on startup and after each new registration.
The Node.js backend invalidates the relevant key whenever a student is updated or deleted.
"""

import json
import logging
from typing import Optional

import redis.asyncio as aioredis

from .config import settings

logger = logging.getLogger(__name__)

_client: Optional[aioredis.Redis] = None


async def get_client() -> aioredis.Redis:
    global _client
    if _client is None:
        _client = aioredis.from_url(
            settings.redis_url,
            encoding="utf-8",
            decode_responses=True,
        )
    return _client


async def get_all_embeddings() -> dict:
    """Return { student_id: { embedding, first_name, ... } } for all cached students."""
    client = await get_client()
    keys = await client.keys("face_emb:*")
    if not keys:
        return {}
    result: dict = {}
    for key in keys:
        raw = await client.get(key)
        if raw:
            sid = key[len("face_emb:"):]
            result[sid] = json.loads(raw)
    return result


async def set_embedding(student_id: str, data: dict) -> None:
    client = await get_client()
    payload = json.dumps(data)
    if settings.redis_emb_ttl > 0:
        await client.setex(f"face_emb:{student_id}", settings.redis_emb_ttl, payload)
    else:
        await client.set(f"face_emb:{student_id}", payload)
    logger.debug(f"[Redis] Cached embedding for {student_id}")


async def delete_embedding(student_id: str) -> None:
    client = await get_client()
    await client.delete(f"face_emb:{student_id}")
    logger.debug(f"[Redis] Removed embedding for {student_id}")


async def reload_from_db() -> int:
    """
    Reload all active student embeddings from PostgreSQL into Redis.
    Called on startup and via POST /cache/reload.
    """
    if not settings.database_url:
        logger.warning("[Redis] DATABASE_URL not set — skipping cache reload.")
        return 0

    import asyncpg  # imported lazily to avoid import error when DB not configured

    conn = await asyncpg.connect(settings.database_url, ssl="require")
    try:
        rows = await conn.fetch(
            """
            SELECT id, first_name, last_name, class_grade, division, roll_no,
                   face_embedding
            FROM students
            WHERE status = 'active' AND face_embedding IS NOT NULL
            """
        )
    finally:
        await conn.close()

    client = await get_client()

    # Clear all existing embedding keys before reload
    old_keys = await client.keys("face_emb:*")
    if old_keys:
        await client.delete(*old_keys)

    loaded = 0
    for row in rows:
        raw = row["face_embedding"]
        emb = json.loads(raw) if isinstance(raw, str) else raw
        if not emb or len(emb) not in (128, 512):
            continue
        await set_embedding(
            row["id"],
            {
                "embedding": emb,
                "first_name": row["first_name"],
                "last_name": row["last_name"],
                "class_grade": row["class_grade"],
                "division": row["division"],
                "roll_no": row["roll_no"],
            },
        )
        loaded += 1

    logger.info(f"[Redis] Reloaded {loaded} embeddings from PostgreSQL.")
    return loaded
