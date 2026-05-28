from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # InsightFace model: "buffalo_sc" (200MB, fast) or "buffalo_l" (500MB, best accuracy)
    model_name: str = "buffalo_sc"
    det_size: int = 640

    # Matching thresholds (scores are in [0, 1] — ArcFace cosine mapped via (cos+1)/2)
    match_threshold: float = 0.60   # below this = unknown
    margin_threshold: float = 0.05  # gap between #1 and #2 must exceed this

    # Quality gates (applied before embedding generation)
    min_face_size_px: int = 60
    max_yaw_deg: float = 30.0
    max_pitch_deg: float = 30.0
    max_roll_deg: float = 25.0
    min_det_score: float = 0.60

    # Redis
    redis_url: str = "redis://localhost:6379"
    redis_emb_ttl: int = 0  # 0 = no expiry (embeddings persist until invalidated)

    # PostgreSQL (used only for cache reload)
    database_url: str = ""

    class Config:
        env_file = ".env"


settings = Settings()
