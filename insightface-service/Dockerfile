FROM python:3.11-slim

# System libs required by OpenCV and ONNX Runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-0 libsm6 libxext6 libxrender1 libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pre-download InsightFace models at build time so first request is fast.
# Uses buffalo_sc on CPU; override MODEL_NAME=buffalo_l for higher accuracy
# on a machine with more RAM (buffalo_l needs ~1GB, buffalo_sc needs ~200MB).
ARG MODEL_NAME=buffalo_sc
RUN python - <<'EOF'
import os, insightface
from insightface.app import FaceAnalysis
model = os.getenv("MODEL_NAME", "buffalo_sc")
try:
    app = FaceAnalysis(name=model, providers=["CPUExecutionProvider"])
    app.prepare(ctx_id=-1, det_size=(640, 640))
    print(f"[build] Model '{model}' downloaded successfully.")
except Exception as e:
    print(f"[build] Model pre-download failed (will retry at runtime): {e}")
EOF

COPY . .

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
