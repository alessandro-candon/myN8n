# n8n on Cloud Run with GCS Volume Mount
# Optimized for personal use with SQLite persistence

FROM n8nio/n8n:stable

# n8n runs as 'node' user (uid=1000, gid=1000)
# GCS volume mount must match these permissions

# Set timezone (change as needed)
ENV GENERIC_TIMEZONE=Europe/Rome
ENV TZ=Europe/Rome

# n8n configuration
ENV N8N_PORT=5678
ENV N8N_PROTOCOL=https
ENV N8N_SECURE_COOKIE=true
ENV N8N_RUNNERS_ENABLED=true
ENV N8N_RUNNERS_MODE=internal
ENV NODES_EXCLUDE=[]


# Database configuration - SQLite (default)
ENV DB_TYPE=sqlite
ENV DB_SQLITE_VACUUM_ON_STARTUP=true

# Data directory (mounted from GCS bucket)
ENV N8N_USER_FOLDER=/home/node/.n8n

# Security settings
ENV N8N_BLOCK_ENV_ACCESS_IN_NODE=true
ENV N8N_PERSONALIZATION_ENABLED=false

# Disable telemetry for privacy
ENV N8N_DIAGNOSTICS_ENABLED=false

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:5678/healthz || exit 1

EXPOSE 5678

# Default command (inherited from base image)
CMD ["n8n"]
