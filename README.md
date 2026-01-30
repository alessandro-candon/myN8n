# n8n on Google Cloud Run

Deploy [n8n](https://n8n.io/) workflow automation on Google Cloud Run with persistent SQLite storage using GCS bucket volume mounts.

## 🎯 Features

- **Cost-effective**: Scale to zero when not in use (~$0-5/month for light usage)
- **Persistent storage**: SQLite database stored in GCS bucket (survives restarts/redeploys)
- **Secure**: Encryption key stored in Secret Manager, HTTPS by default
- **Simple**: One-command deployment

## 📋 Prerequisites

1. **Google Cloud Account** with billing enabled
2. **gcloud CLI** installed and authenticated
3. **Project** created in GCP

```bash
# Install gcloud (macOS)
brew install google-cloud-sdk

# Authenticate
gcloud auth login

# Set your project
gcloud config set project YOUR_PROJECT_ID
```

## 🚀 Quick Start

```bash
# Clone/download this repository
cd myn8n

# Make deploy script executable
chmod +x deploy.sh

# Deploy (uses default configuration)
./deploy.sh
```

### Custom Configuration

```bash
# Set environment variables before running
export PROJECT_ID="my-project"
export REGION="europe-west1"
export SERVICE_NAME="n8n"
export BUCKET_NAME="my-n8n-data"

./deploy.sh
```

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Google Cloud Run                        │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                    n8n Container                      │  │
│  │                                                       │  │
│  │   ┌─────────────┐    ┌──────────────────────────┐    │  │
│  │   │   n8n App   │────│  /home/node/.n8n         │    │  │
│  │   │  (Port 5678)│    │  (GCS Volume Mount)      │    │  │
│  │   └─────────────┘    └────────────┬─────────────┘    │  │
│  │                                   │                   │  │
│  └───────────────────────────────────│───────────────────┘  │
│                                      │                      │
└──────────────────────────────────────│──────────────────────┘
                                       │ GCS FUSE
                                       ▼
                    ┌──────────────────────────────────┐
                    │     Google Cloud Storage         │
                    │     (Standard Storage)           │
                    │                                  │
                    │  📁 database.sqlite              │
                    │  📁 config                       │
                    │  📁 .n8n files                   │
                    └──────────────────────────────────┘

                    ┌──────────────────────────────────┐
                    │     Secret Manager               │
                    │                                  │
                    │  🔐 n8n-encryption-key           │
                    └──────────────────────────────────┘
```

## 💰 Cost Estimation

| Component | Cost (Monthly) |
|-----------|---------------|
| Cloud Run (scale to zero) | $0-5 (pay per use) |
| Cloud Run (min-instances=1) | ~$15-25 |
| GCS Storage (Standard) | ~$0.02/GB |
| Secret Manager | ~$0.06 |
| **Total (scale to zero)** | **~$1-10/month** |
| **Total (always on)** | **~$15-30/month** |

> 💡 Free tier includes 2M Cloud Run requests/month and 5GB GCS storage.

## ⚠️ Important Limitations

### Single Instance Only

This setup uses **SQLite** with GCS FUSE volume mount. GCS FUSE does **not support file locking**, which means:

- ✅ Works perfectly with single instance (`--max-instances=1`)
- ❌ **DO NOT** increase `max-instances` above 1 (database corruption risk)
- ❌ **DO NOT** run multiple services accessing the same bucket

### Cold Starts

With `--min-instances=0` (default), expect:

- **10-30 second delay** on first request after idle period
- Webhooks may timeout during cold start
- Solution: Set `--min-instances=1` if you need instant response (costs ~$15-25/month more)

## 🔧 Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PROJECT_ID` | Current gcloud project | GCP project ID |
| `REGION` | `europe-west1` | GCP region |
| `SERVICE_NAME` | `n8n` | Cloud Run service name |
| `BUCKET_NAME` | `${PROJECT_ID}-n8n-data` | GCS bucket name |
| `MEMORY` | `1Gi` | Container memory |
| `CPU` | `1` | Container CPU |
| `MIN_INSTANCES` | `0` | Minimum instances (0 = scale to zero) |
| `MAX_INSTANCES` | `1` | Maximum instances (**keep at 1**) |

### Timezone

Edit `Dockerfile` to change timezone:

```dockerfile
ENV GENERIC_TIMEZONE=Europe/Rome
ENV TZ=Europe/Rome
```

## 📦 Backup & Restore

### Backup

```bash
# Download entire n8n data folder
gcloud storage cp -r gs://YOUR_BUCKET_NAME ./n8n-backup
```

### Restore

```bash
# Upload backup to bucket
gcloud storage cp -r ./n8n-backup/* gs://YOUR_BUCKET_NAME/
```

### Export Workflows (Recommended)

Use n8n's built-in export feature:
1. Go to **Workflows** in n8n
2. Select workflows to export
3. Click **Download** to get JSON files

## 🔄 Updates

### Update n8n Version

```bash
# Edit Dockerfile to pin specific version (optional)
# FROM docker.n8n.io/n8nio/n8n:1.94.1

# Rebuild and deploy
./deploy.sh
```

### Redeploy without Rebuilding

```bash
gcloud run services update n8n \
    --region=europe-west1 \
    --set-env-vars="NEW_VAR=value"
```

## 🛡️ Security

### What's Protected

- ✅ **Encryption key** stored in Secret Manager (not in container)
- ✅ **HTTPS** enforced by Cloud Run
- ✅ **Secure cookies** enabled
- ✅ **Bucket** has public access prevention enabled
- ✅ **Environment access** blocked in Code nodes

### Recommendations

1. **Create admin account immediately** after first deployment
2. **Enable 2FA** in n8n settings
3. **Use IAP** (Identity-Aware Proxy) for additional authentication layer:

```bash
# Optional: Restrict to specific users with IAP
gcloud run services update n8n \
    --region=europe-west1 \
    --no-allow-unauthenticated
```

## 🐛 Troubleshooting

### Container Won't Start

```bash
# Check logs
gcloud run services logs read n8n --region=europe-west1 --limit=50

# Check for startup errors
gcloud run revisions list --service=n8n --region=europe-west1
```

### Permission Denied on Volume Mount

```bash
# Verify service account permissions
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

gcloud storage buckets get-iam-policy gs://YOUR_BUCKET_NAME \
    --format="table(bindings.role,bindings.members)"
```

### Database Corruption

If SQLite database becomes corrupted:

```bash
# 1. Stop the service
gcloud run services update n8n --region=europe-west1 --no-traffic

# 2. Download and backup corrupted database
gcloud storage cp gs://YOUR_BUCKET_NAME/database.sqlite ./corrupted-db-backup.sqlite

# 3. Delete corrupted database
gcloud storage rm gs://YOUR_BUCKET_NAME/database.sqlite

# 4. Restore traffic (n8n will create fresh database)
gcloud run services update n8n --region=europe-west1 --traffic=LATEST=100

# 5. Re-import workflows from your JSON backups
```

### Slow Performance

GCS FUSE has higher latency than local disk. For better performance:

1. Use larger workflow batches instead of many small operations
2. Consider upgrading to Cloud SQL PostgreSQL for heavy usage

## 🗑️ Cleanup

Remove all resources:

```bash
# Delete Cloud Run service
gcloud run services delete n8n --region=europe-west1

# Delete GCS bucket (WARNING: deletes all data!)
gcloud storage rm -r gs://YOUR_BUCKET_NAME

# Delete secret
gcloud secrets delete n8n-encryption-key

# Delete container images
gcloud artifacts docker images delete \
    europe-west1-docker.pkg.dev/YOUR_PROJECT/cloud-run-source-deploy/n8n
```

## 📚 Resources

- [n8n Documentation](https://docs.n8n.io/)
- [Cloud Run Documentation](https://cloud.google.com/run/docs)
- [GCS Volume Mounts](https://cloud.google.com/run/docs/configuring/services/cloud-storage-volume-mounts)
- [GCS FUSE Semantics](https://github.com/GoogleCloudPlatform/gcsfuse/blob/master/docs/semantics.md)

## 📄 License

This deployment configuration is provided as-is for personal use.
n8n is licensed under [Sustainable Use License](https://github.com/n8n-io/n8n/blob/master/LICENSE.md).
