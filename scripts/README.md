# 🔧 Lead Enrichment Scripts

This directory contains all operational scripts for the Lead Enrichment system.

## 📊 **Monitoring Scripts**
- **[monitor-progress.sh](monitor-progress.sh)** - Real-time job monitoring with colors and progress
- **[check-status.sh](check-status.sh)** - Quick system status check
- **[monitor.py](monitor.py)** - Python-based advanced monitoring dashboard

## 🚀 **Deployment Scripts**
- **[deploy-production.sh](deploy-production.sh)** - Main production deployment
- **[deploy-auto-shutdown.sh](deploy-auto-shutdown.sh)** - Deploy with auto-shutdown feature
- **[deploy-auto-shutdown-remote.sh](deploy-auto-shutdown-remote.sh)** - Remote deployment variant
- **[deploy-ecs.sh](deploy-ecs.sh)** - ECS-specific deployment
- **[deploy-manual.sh](deploy-manual.sh)** - Manual deployment process
- **[rebuild-and-deploy.sh](rebuild-and-deploy.sh)** - Full rebuild and deployment

## 🧪 **Testing Scripts**
- **[test-auto-shutdown.sh](test-auto-shutdown.sh)** - Test auto-shutdown functionality

## 🛠️ **Utility Scripts**
- **[cleanup-workers.sh](cleanup-workers.sh)** - Stop idle workers manually
- **[create-real-layer.sh](create-real-layer.sh)** - Create Lambda layers

## 📋 **Usage Examples**

### Monitor Current Job Progress
```bash
./scripts/monitor-progress.sh --watch
```

### Check System Status
```bash
./scripts/check-status.sh
```

### Deploy Latest Changes
```bash
./scripts/deploy-auto-shutdown.sh
```

### Test Auto-Shutdown Feature
```bash
./scripts/test-auto-shutdown.sh
```

### Stop All Workers (Emergency)
```bash
./scripts/cleanup-workers.sh
```

## 🔑 **Script Categories**

### 🟢 **Production Ready**
- `monitor-progress.sh` - Primary monitoring tool
- `check-status.sh` - Daily health checks
- `deploy-auto-shutdown.sh` - Standard deployment
- `cleanup-workers.sh` - Emergency worker cleanup

### 🟡 **Development/Testing**
- `test-auto-shutdown.sh` - Feature testing
- `deploy-manual.sh` - Manual deployment steps
- `monitor.py` - Alternative monitoring

### 🔴 **Legacy/Reference**
- `deploy-ecs.sh` - Older deployment method
- `create-real-layer.sh` - Layer creation (rarely needed)

## 💡 **Tips**
- Always make scripts executable: `chmod +x scripts/*.sh`
- Run scripts from the project root directory
- Check script help: `./scripts/script-name.sh --help` (if available)
- Monitor logs during operations for detailed feedback