FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DATA_DIR=/app/data

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*

# nc certifcate
COPY vault-ca.crt /usr/local/share/ca-certificates/vault-ca.crt
RUN update-ca-certificates

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

RUN curl -fsSL -o /usr/local/bin/supercronic https://github.com/aptible/supercronic/releases/download/v0.2.33/supercronic-linux-amd64 \
    && chmod +x /usr/local/bin/supercronic

# build context is this directory, so the app lands directly in /app
COPY . .

# ensuring the image and all scripts have required perms
RUN chown -R 1000:1000 /app && chmod -R a+rX /app && find /app -type f \( -name '*.py' -o -name '*.crontab' \) -exec chmod 0644 '{}' +

RUN mkdir -p /app/data/queue/pending /app/data/queue/processing /app/data/queue/done /app/data/queue/failed

# compose overrides this and waits on the rendered secrets first
CMD ["python", "-u", "dc_bot.py"]
