FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DATA_DIR=/app/data

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

RUN curl -fsSL -o /usr/local/bin/supercronic https://github.com/aptible/supercronic/releases/download/v0.2.33/supercronic-linux-amd64 \
    && chmod +x /usr/local/bin/supercronic

COPY . .

RUN mkdir -p /app/data/queue/pending /app/data/queue/processing /app/data/queue/done /app/data/queue/failed

# small wait script to avoid race conditions (bot starts before vault renders secrets)
CMD ["sh", "-c", "until [ -s /run/secrets/discord_bot_token ]; do echo waiting for vault secrets; sleep 1; done; python -u dc_bot.py"]