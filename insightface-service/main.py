import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.face_analyzer import FaceAnalyzer
from app.redis_cache import reload_from_db
from app.routes import router

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("[Startup] Initializing InsightFace model…")
    FaceAnalyzer.initialize()
    logger.info("[Startup] Loading Redis embedding cache from PostgreSQL…")
    loaded = await reload_from_db()
    logger.info(f"[Startup] Ready — {loaded} embeddings in cache.")
    yield
    logger.info("[Shutdown] Goodbye.")


app = FastAPI(
    title="EduScan InsightFace Service",
    description="ArcFace 512-D face recognition microservice",
    version="1.0.0",
    lifespan=lifespan,
)

app.include_router(router)
