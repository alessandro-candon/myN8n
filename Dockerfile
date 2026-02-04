# n8n on Cloud Run with GCS Volume Mount
# Optimized for personal use with SQLite persistence

FROM n8nio/n8n:2.3.0

# Switch to root to copy files
USER root

# Install FFmpeg static binary (no package manager)
ADD https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz /tmp/ffmpeg.tar.xz
RUN mkdir -p /opt/ffmpeg && \
    tar -xf /tmp/ffmpeg.tar.xz -C /opt/ffmpeg --strip-components=1 && \
    cp /opt/ffmpeg/ffmpeg /usr/local/bin/ffmpeg && \
    rm -rf /tmp/ffmpeg.tar.xz /opt/ffmpeg

# Copy startup wrapper script
COPY docker-entrypoint-wrapper.sh /docker-entrypoint-wrapper.sh
RUN chmod +x /docker-entrypoint-wrapper.sh

# Switch back to node user
USER node

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
# Enable WAL mode - with proper checkpoint on shutdown, WAL is safe and performant
ENV DB_SQLITE_ENABLE_WAL=false

# Data directory - don't set N8N_USER_FOLDER, n8n uses /home/node/.n8n by default
# The GCS bucket is mounted at /home/node/.n8n

# Security settings
ENV N8N_BLOCK_ENV_ACCESS_IN_NODE=true
ENV N8N_PERSONALIZATION_ENABLED=false
ENV NODE_FUNCTION_ALLOW_BUILTIN=fs
ENV N8N_RESTRICT_FILE_ACCESS_TO=
ENV N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES=false

# Disable telemetry for privacy
ENV N8N_DIAGNOSTICS_ENABLED=false

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=5 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:5678/healthz || exit 1

EXPOSE 5678

# Use tini as init, our wrapper handles GCS FUSE, then starts n8n directly
ENTRYPOINT ["tini", "--", "/docker-entrypoint-wrapper.sh"]
