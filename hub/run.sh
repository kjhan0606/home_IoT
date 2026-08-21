#!/usr/bin/env bash
# Start the HomeHub local gateway.
cd "$(dirname "$0")"
source .venv/bin/activate
exec uvicorn homehub.server:app --host "${HOMEHUB_HTTP_HOST:-0.0.0.0}" --port "${HOMEHUB_HTTP_PORT:-8099}" "$@"
