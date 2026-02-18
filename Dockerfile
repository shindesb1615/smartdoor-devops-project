# ─── Stage 1: Builder ─────────────────────────────────────────
FROM python:3.11-slim AS builder
WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc libpq-dev && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --prefix=/deps --no-cache-dir -r requirements.txt

# ─── Stage 2: Production ──────────────────────────────────────
FROM python:3.11-slim AS production
LABEL maintainer="devops@smartdoor.io"
LABEL version="2.0.0"

# Non-root user (security hardening)
RUN groupadd -r smartdoor && useradd -r -g smartdoor smartdoor

WORKDIR /app
COPY --from=builder /deps /usr/local
COPY --chown=smartdoor:smartdoor . .

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000

USER smartdoor
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "4", "--proxy-headers"]
