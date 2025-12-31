# Storage Solution for GitLab Runner on Kubernetes

## Quick Reference

| Your Cluster | `/builds` Solution | `/cache` Solution | Jump to |
|--------------|-------------------|-------------------|---------|
| **Single-node** | `emptyDir` | Shared PVC (RWX) | [Config](#single-node-cluster-configtoml) |
| **Multi-node (2-5 nodes)** | `emptyDir` | `hostPath` + pod affinity | [Config](#multi-node-cluster-option-1-per-node-cache-with-affinity) |
| **Multi-node (5+ nodes)** | `emptyDir` | GitLab S3/MinIO distributed cache | [Config](#multi-node-cluster-option-2-gitlab-distributed-cache-with-s3) |
| **Cloud (EKS/GKE/AKS)** | `emptyDir` | GitLab S3/GCS/Azure distributed cache | [Config](#multi-node-cluster-option-2-gitlab-distributed-cache-with-s3) |
| **Self-hosted** | `emptyDir` | MinIO or `hostPath` + affinity | [Config](#multi-node-cluster-option-3-self-hosted-minio) |

**Key Insight:** Network storage (NFS) for cache in multi-node clusters defeats the performance purpose of caching. Use local storage with affinity OR object storage (S3/MinIO).

---

## Problem Statement

When using the Kubernetes executor with concurrent jobs, the default shared PVC approach for `/builds` and `/cache` directories causes isolation issues:

- **`/builds`**: Concurrent jobs from the same project clone into the same directory, causing corruption
- **`/cache`**: Concurrent cache operations cause race conditions and corrupted cache archives
- **Multi-node**: Network storage (NFS/CephFS) has high latency, defeating cache performance benefits

## Recommended Solution

### `/builds` Directory: Use `emptyDir` (Ephemeral Storage)

Build directories are ephemeral by nature and don't require persistence across jobs. Use Kubernetes `emptyDir` volumes for perfect per-job isolation.

#### Configuration

```toml
[[runners]]
  builds_dir = "/builds"

  [runners.kubernetes]
    [[runners.kubernetes.volumes.empty_dir]]
      name = "builds"
      mount_path = "/builds"
      medium = "Memory"  # Optional: RAM-backed (tmpfs) for speed
      # OR omit 'medium' to use node disk storage
```
- See [GitLab Docs](https://docs.gitlab.com/ci/runners/configure_runners/#custom-build-directories "docs.gitlab.com")

#### Benefits

- ✅ **Perfect isolation**: Each job pod gets its own empty directory
- ✅ **Auto-cleanup**: Automatically deleted when pod terminates
- ✅ **No PVC management**: No pre-allocation or dynamic provisioning needed
- ✅ **Performance**: Fast, especially with `medium = "Memory"` (tmpfs)
- ✅ **Unlimited scaling**: No PVC pre-allocation limits

#### Considerations

- If using `medium = "Memory"`, ensure adequate node memory
- For large builds, use node disk by omitting the `medium` parameter
- Memory usage counts against pod memory limits

---

### `/cache` Directory: Shared PVC with Logical Isolation

Use a single shared PVC with GitLab's cache key mechanism for logical isolation between projects, branches, and jobs.

#### Configuration

```toml
[[runners]]
  cache_dir = "/cache"

  [runners.kubernetes]
    [[runners.kubernetes.volumes.pvc]]
      name = "gitlab-runner-cache"
      mount_path = "/cache"
      read_only = false
```

#### Pre-create the PVC

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gitlab-runner-cache
  namespace: gitlab-runner  # Match your runner namespace
spec:
  accessModes: [ReadWriteMany]  # Required for concurrent access
  storageClassName: nfs-client   # Must support ReadWriteMany (RWX)
  resources:
    requests:
      storage: 100Gi  # Adjust based on your needs
```

Apply the PVC:

```bash
kubectl apply -f pvc-cache.yaml
```

#### Storage Class Requirements

The storage class **must support `ReadWriteMany` (RWX)** access mode:

- **NFS** (nfs-client, nfs-subdir-external-provisioner)
- **CephFS**
- **Azure Files**
- **GlusterFS**
- **AWS EFS** (via EFS CSI driver)

Verify your storage class supports RWX:

```bash
kubectl get storageclass
kubectl describe storageclass <name>
```

#### GitLab Cache Key Configuration

In your `.gitlab-ci.yml`, configure cache keys for logical isolation:

```yaml
cache:
  key: "$CI_PROJECT_PATH_SLUG-$CI_COMMIT_REF_SLUG"
  paths:
    - node_modules/
    - .m2/repository/
    - .cache/pip/
    - vendor/
```

**Common cache key patterns:**

```yaml
# Per-project + per-branch
key: "$CI_PROJECT_PATH_SLUG-$CI_COMMIT_REF_SLUG"

# Per-project + per-branch + per-job
key: "$CI_PROJECT_PATH_SLUG-$CI_COMMIT_REF_SLUG-$CI_JOB_NAME"

# Shared across branches (use with caution)
key: "$CI_PROJECT_PATH_SLUG"

# Per-project with fallback keys
key:
  files:
    - package-lock.json  # Invalidate when dependencies change
  prefix: "$CI_PROJECT_PATH_SLUG"
```

#### Benefits

- ✅ Cache persists across pipeline runs (faster subsequent builds)
- ✅ Logical isolation via cache keys prevents conflicts
- ✅ No per-job PVC allocation needed
- ✅ Scales to unlimited concurrent jobs
- ✅ Efficient storage usage (shared space)

#### Considerations

- ⚠️ Requires RWX-capable storage class
- 💡 Monitor cache size and implement cleanup policies
- 💡 Consider cache expiration for infrequently used branches

---

## Alternative: Ephemeral Cache

If cache persistence between pipeline runs is not critical, use `emptyDir` for cache as well:

```toml
[[runners]]
  cache_dir = "/cache"

  [runners.kubernetes]
    [[runners.kubernetes.volumes.empty_dir]]
      name = "cache"
      mount_path = "/cache"
      # Use node disk (not memory) for larger capacity
```

**Trade-offs:**

- ✅ Perfect isolation, no PVC management, works with any storage
- ⚠️ Cache lost after each job (slower builds, more network traffic)
- 💡 Suitable for environments where build time > cache restore time

---

## Multi-Node Cluster Considerations

### The Network Storage Problem

In multi-node clusters, using ReadWriteMany (RWX) network storage (NFS, CephFS, EFS) for cache has a critical performance issue:

**⚠️ Network storage has high latency compared to local disk**, defeating the performance purpose of caching.

**Example scenario:**
```
Node 1: Job A reads cache from NFS (network I/O)
Node 2: Job B reads same cache from NFS (network I/O)
Node 3: Job C reads cache from NFS (network I/O)
```

All jobs suffer network latency instead of fast local disk reads.

### Solution Options for Multi-Node Clusters

#### **Option 1: Per-Node Local Cache with Node Affinity** ⭐ Recommended

Use local storage on each node with pod affinity to ensure jobs from the same project prefer the same node (increasing cache hits).

**Step 1: Deploy local-path-provisioner (if not already available)**

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
```

**Step 2: Create per-node cache using hostPath volume**

```toml
[[runners]]
  cache_dir = "/cache"

  [runners.kubernetes]
    # Use hostPath for local node storage
    [[runners.kubernetes.volumes.host_path]]
      name = "node-cache"
      mount_path = "/cache"
      host_path = "/var/lib/gitlab-runner/cache"
      read_only = false
```

**Step 3: Add node affinity for cache locality**

```toml
[[runners]]
  [runners.kubernetes]
    # Prefer scheduling pods on the same node for cache reuse
    [runners.kubernetes.affinity]
      [runners.kubernetes.affinity.node_affinity]
        [runners.kubernetes.affinity.node_affinity.preferred_during_scheduling_ignored_during_execution]
          [[runners.kubernetes.affinity.node_affinity.preferred_during_scheduling_ignored_during_execution.preference]]
            [[runners.kubernetes.affinity.node_affinity.preferred_during_scheduling_ignored_during_execution.preference.match_expressions]]
              key = "gitlab-runner-cache"
              operator = "In"
              values = ["enabled"]
```

Or use pod affinity based on project:

```toml
[[runners]]
  [runners.kubernetes]
    # Schedule jobs from same project on same node when possible
    [runners.kubernetes.pod_labels]
      "gitlab-project" = "$CI_PROJECT_PATH_SLUG"

    [runners.kubernetes.affinity]
      [runners.kubernetes.affinity.pod_affinity]
        [[runners.kubernetes.affinity.pod_affinity.preferred_during_scheduling_ignored_during_execution]]
          weight = 100
          [runners.kubernetes.affinity.pod_affinity.preferred_during_scheduling_ignored_during_execution.pod_affinity_term]
            topology_key = "kubernetes.io/hostname"
            [runners.kubernetes.affinity.pod_affinity.preferred_during_scheduling_ignored_during_execution.pod_affinity_term.label_selector]
              [[runners.kubernetes.affinity.pod_affinity.preferred_during_scheduling_ignored_during_execution.pod_affinity_term.label_selector.match_expressions]]
                key = "gitlab-project"
                operator = "In"
                values = ["$CI_PROJECT_PATH_SLUG"]
```

**Step 4: Create cleanup DaemonSet for cache management**

```yaml
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: gitlab-cache-cleanup
  namespace: gitlab-runner
spec:
  selector:
    matchLabels:
      app: gitlab-cache-cleanup
  template:
    metadata:
      labels:
        app: gitlab-cache-cleanup
    spec:
      containers:
      - name: cleanup
        image: busybox
        command:
        - sh
        - -c
        - |
          while true; do
            # Clean caches older than 7 days every 24 hours
            find /cache -type f -mtime +7 -delete
            sleep 86400
          done
        volumeMounts:
        - name: cache
          mountPath: /cache
      volumes:
      - name: cache
        hostPath:
          path: /var/lib/gitlab-runner/cache
          type: DirectoryOrCreate
```

**Benefits:**
- ✅ **Fast local disk I/O** (no network latency)
- ✅ Cache reuse when jobs scheduled on same node
- ✅ No RWX storage class required
- ✅ Works on any Kubernetes cluster

**Trade-offs:**
- ⚠️ Cache not shared across nodes (cache miss on different node)
- ⚠️ Requires node affinity tuning for optimal cache hit rate
- ⚠️ Each node consumes local disk space

**Cache hit optimization:**
- Jobs from the same project/branch have higher cache hit rate
- Use pod affinity based on `$CI_PROJECT_PATH_SLUG`
- Node count should align with concurrent job count

---

#### **Option 2: Distributed Cache Layer**

Use a distributed cache system (Redis, Memcached) for frequently accessed small files, with fallback to object storage.

**Architecture:**
```
Job Pod → Check Redis → (miss) → Download from S3/MinIO → Store in Redis → Use
       → (hit) → Use from Redis
```

**Implementation requires custom cache logic in jobs or wrapper scripts.**

**Example `.gitlab-ci.yml` with Redis cache layer:**

```yaml
variables:
  REDIS_HOST: "redis.gitlab-runner.svc.cluster.local"
  CACHE_BUCKET: "s3://gitlab-cache"

before_script:
  - |
    # Try to restore from Redis first
    CACHE_KEY="$CI_PROJECT_PATH_SLUG-$CI_COMMIT_REF_SLUG"
    if redis-cli -h $REDIS_HOST GET "$CACHE_KEY" > /tmp/cache.tar.gz; then
      echo "Cache hit from Redis"
      tar xzf /tmp/cache.tar.gz
    elif aws s3 cp "$CACHE_BUCKET/$CACHE_KEY.tar.gz" /tmp/cache.tar.gz; then
      echo "Cache hit from S3, storing in Redis"
      tar xzf /tmp/cache.tar.gz
      redis-cli -h $REDIS_HOST SETEX "$CACHE_KEY" 3600 "$(cat /tmp/cache.tar.gz)"
    else
      echo "Cache miss"
    fi

after_script:
  - |
    # Save cache to S3
    tar czf /tmp/cache.tar.gz node_modules/
    aws s3 cp /tmp/cache.tar.gz "$CACHE_BUCKET/$CACHE_KEY.tar.gz"
```

**Benefits:**
- ✅ Very fast for small cached items (Redis is in-memory)
- ✅ Works across all nodes
- ✅ Can handle large caches (S3) with fast small-item access (Redis)

**Trade-offs:**
- ⚠️ Complex setup (Redis, S3/MinIO, custom scripts)
- ⚠️ Requires application-level cache logic
- ⚠️ Additional infrastructure components

---

#### **Option 3: Use GitLab's Distributed Cache** ⭐ Simplest

Let GitLab Runner handle distributed caching using object storage (S3, GCS, Azure Blob).

**Configuration:**

```toml
concurrent = 10

[[runners]]
  name = "kubernetes-runner"
  executor = "kubernetes"
  builds_dir = "/builds"

  # Configure distributed cache using S3
  [runners.cache]
    Type = "s3"
    Shared = true  # Share cache across runners
    [runners.cache.s3]
      ServerAddress = "s3.amazonaws.com"
      BucketName = "gitlab-runner-cache"
      BucketLocation = "us-east-1"
      # Or use MinIO/compatible storage
      # ServerAddress = "minio.gitlab-runner.svc.cluster.local:9000"
      # Insecure = true  # For self-signed certs

  [runners.kubernetes]
    # No volume needed - cache handled by GitLab Runner via S3
    namespace = "gitlab-runner"

    [[runners.kubernetes.volumes.empty_dir]]
      name = "builds"
      mount_path = "/builds"
```

**Set S3 credentials via environment variables:**

```yaml
# In Helm values.yaml or config
runners:
  config: |
    [[runners]]
      environment = [
        "CACHE_S3_ACCESS_KEY=your-access-key",
        "CACHE_S3_SECRET_KEY=your-secret-key"
      ]
```

**Or use Kubernetes secrets:**

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-runner-cache-s3
  namespace: gitlab-runner
type: Opaque
stringData:
  accesskey: your-access-key
  secretkey: your-secret-key
```

```toml
[[runners]]
  [runners.cache]
    Type = "s3"
    [runners.cache.s3]
      ServerAddress = "s3.amazonaws.com"
      BucketName = "gitlab-runner-cache"
      # Credentials from env vars set by Kubernetes secret
```

**Benefits:**
- ✅ **Zero infrastructure on Kubernetes** (just use S3/GCS)
- ✅ Cache shared across all nodes and all runners
- ✅ Unlimited storage capacity
- ✅ Built-in GitLab feature (no custom scripts)
- ✅ Works with MinIO for self-hosted object storage

**Trade-offs:**
- ⚠️ Network latency to object storage (but optimized by GitLab)
- ⚠️ Requires S3/GCS/MinIO (additional cost or infrastructure)
- ⚠️ Compressed uploads/downloads (CPU overhead, but saves bandwidth)

**MinIO deployment for self-hosted:**

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: gitlab-runner
spec:
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: minio/minio:latest
        args:
        - server
        - /data
        - --console-address
        - ":9001"
        env:
        - name: MINIO_ROOT_USER
          value: "admin"
        - name: MINIO_ROOT_PASSWORD
          value: "your-secret-password"
        ports:
        - containerPort: 9000
        - containerPort: 9001
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: minio-data
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: gitlab-runner
spec:
  ports:
  - name: api
    port: 9000
    targetPort: 9000
  - name: console
    port: 9001
    targetPort: 9001
  selector:
    app: minio
```

---

### Recommendation by Cluster Type

| Cluster Type | Recommended Solution | Rationale |
|--------------|---------------------|-----------|
| **Single-node** | RWX PVC (original solution) | No cross-node concerns |
| **Small multi-node (2-5 nodes)** | Per-node hostPath + affinity | Fast, simple, good cache hit rate |
| **Large multi-node (5+ nodes)** | GitLab distributed cache (S3/MinIO) | Scales infinitely, cache shared across all nodes |
| **Cloud-hosted (EKS/GKE/AKS)** | GitLab distributed cache (S3/GCS/Azure) | Native cloud object storage integration |
| **Self-hosted, no object storage** | Per-node hostPath + affinity | Best performance without additional infrastructure |
| **High-performance needs** | Per-node local SSD + NVMe | Maximum I/O performance |

---

## Complete Configuration Examples

### Single-Node Cluster: `config.toml`

```toml
concurrent = 10

[[runners]]
  name = "kubernetes-runner"
  executor = "kubernetes"
  builds_dir = "/builds"
  cache_dir = "/cache"

  [runners.kubernetes]
    namespace = "gitlab-runner"
    limit = 10

    # Ephemeral builds directory (per-job isolation)
    [[runners.kubernetes.volumes.empty_dir]]
      name = "builds"
      mount_path = "/builds"

    # Shared cache with logical isolation (single node = no latency issue)
    [[runners.kubernetes.volumes.pvc]]
      name = "gitlab-runner-cache"
      mount_path = "/cache"
      read_only = false
```

### Multi-Node Cluster (Option 1): Per-Node Cache with Affinity

```toml
concurrent = 10

[[runners]]
  name = "kubernetes-runner"
  executor = "kubernetes"
  builds_dir = "/builds"
  cache_dir = "/cache"

  [runners.kubernetes]
    namespace = "gitlab-runner"
    limit = 10

    # Ephemeral builds directory
    [[runners.kubernetes.volumes.empty_dir]]
      name = "builds"
      mount_path = "/builds"

    # Per-node local cache (fast local disk)
    [[runners.kubernetes.volumes.host_path]]
      name = "node-cache"
      mount_path = "/cache"
      host_path = "/var/lib/gitlab-runner/cache"
      read_only = false

    # Pod affinity to increase cache hit rate
    [runners.kubernetes.pod_labels]
      "gitlab-project" = "$CI_PROJECT_PATH_SLUG"

    [runners.kubernetes.affinity]
      [runners.kubernetes.affinity.pod_affinity]
        [[runners.kubernetes.affinity.pod_affinity.preferred_during_scheduling_ignored_during_execution]]
          weight = 100
          [runners.kubernetes.affinity.pod_affinity.preferred_during_scheduling_ignored_during_execution.pod_affinity_term]
            topology_key = "kubernetes.io/hostname"
            [runners.kubernetes.affinity.pod_affinity.preferred_during_scheduling_ignored_during_execution.pod_affinity_term.label_selector]
              [[runners.kubernetes.affinity.pod_affinity.preferred_during_scheduling_ignored_during_execution.pod_affinity_term.label_selector.match_expressions]]
                key = "gitlab-project"
                operator = "In"
                values = ["$CI_PROJECT_PATH_SLUG"]
```

### Multi-Node Cluster (Option 2): GitLab Distributed Cache with S3

```toml
concurrent = 10

[[runners]]
  name = "kubernetes-runner"
  executor = "kubernetes"
  builds_dir = "/builds"

  # Distributed cache via S3 (no volume needed)
  [runners.cache]
    Type = "s3"
    Shared = true
    [runners.cache.s3]
      ServerAddress = "s3.amazonaws.com"
      BucketName = "gitlab-runner-cache"
      BucketLocation = "us-east-1"

  [runners.kubernetes]
    namespace = "gitlab-runner"
    limit = 10

    # Ephemeral builds directory
    [[runners.kubernetes.volumes.empty_dir]]
      name = "builds"
      mount_path = "/builds"

    # No cache volume - handled by S3
```

### Multi-Node Cluster (Option 3): Self-Hosted MinIO

```toml
concurrent = 10

[[runners]]
  name = "kubernetes-runner"
  executor = "kubernetes"
  builds_dir = "/builds"

  # Distributed cache via MinIO
  [runners.cache]
    Type = "s3"
    Shared = true
    [runners.cache.s3]
      ServerAddress = "minio.gitlab-runner.svc.cluster.local:9000"
      BucketName = "gitlab-runner-cache"
      Insecure = true  # Use with self-signed certs

  [runners.kubernetes]
    namespace = "gitlab-runner"
    limit = 10

    # Set MinIO credentials via environment
    [[runners.kubernetes.pod_annotations]]
      "vault.hashicorp.com/agent-inject" = "true"  # Optional: Vault integration

    environment = [
      "CACHE_S3_ACCESS_KEY=minio-access-key",
      "CACHE_S3_SECRET_KEY=minio-secret-key"
    ]

    [[runners.kubernetes.volumes.empty_dir]]
      name = "builds"
      mount_path = "/builds"
```

### Kubernetes PVC Manifest

**`pvc-gitlab-runner-cache.yaml`:**

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gitlab-runner-cache
  namespace: gitlab-runner
  labels:
    app: gitlab-runner
    component: cache
spec:
  accessModes:
    - ReadWriteMany  # Required for concurrent job access
  storageClassName: nfs-client  # Adjust to your RWX storage class
  resources:
    requests:
      storage: 100Gi  # Adjust based on project needs
```

### GitLab CI/CD Configuration

**`.gitlab-ci.yml`:**

```yaml
variables:
  # Optional: Enhanced build isolation
  # Ensures unique clone path even for same project/branch
  GIT_CLONE_PATH: $CI_BUILDS_DIR/$CI_CONCURRENT_PROJECT_ID/$CI_COMMIT_REF_SLUG

# Global cache configuration
cache:
  key: "$CI_PROJECT_PATH_SLUG-$CI_COMMIT_REF_SLUG"
  paths:
    - node_modules/
    - .cache/
    - vendor/

stages:
  - build
  - test

build_job:
  stage: build
  script:
    - npm install
    - npm run build
  cache:
    # Inherit global cache config
    policy: pull-push

test_job:
  stage: test
  script:
    - npm test
  cache:
    # Only pull cache, don't push
    policy: pull
```

---

## Deployment Steps

### 1. Create the Cache PVC

```bash
# Apply the PVC manifest
kubectl apply -f pvc-gitlab-runner-cache.yaml

# Verify PVC is bound
kubectl get pvc -n gitlab-runner
```

### 2. Update Runner Configuration

Update your `values.diff.yaml.tpl` or `config.toml` with the volume configurations shown above.

### 3. Deploy/Update GitLab Runner

```bash
# If using Helm
bash make.gitlab-runner.sh up

# Or manually
helm upgrade --install gitlab-runner gitlab/gitlab-runner \
  -f values.yaml \
  -n gitlab-runner
```

### 4. Update GitLab CI/CD Configurations

Update `.gitlab-ci.yml` files in your projects with appropriate cache keys.

### 5. Verify

Run a test pipeline and verify:

```bash
# Check runner pods
kubectl get pods -n gitlab-runner

# Check pod volumes
kubectl describe pod <runner-pod> -n gitlab-runner

# Check cache PVC usage
kubectl exec -n gitlab-runner <runner-pod> -- df -h /cache
```

---

## Comparison: Old vs New Approach

| Aspect | Pre-allocated PVCs (`builds-pvc-$CI_CONCURRENT_ID`) | **Recommended Solution** |
|--------|------------------------------------------------------|--------------------------|
| **Builds isolation** | Requires manual PVC creation (`builds-pvc-0..N`) | Automatic via emptyDir per pod |
| **Cache isolation** | Requires per-job PVCs OR shared with conflicts | Logical via cache keys |
| **Scalability** | Limited by number of pre-allocated PVCs | Unlimited concurrent jobs |
| **Storage efficiency** | Wastes space (many underutilized PVCs) | Optimal (ephemeral + shared) |
| **Cleanup** | Manual PVC lifecycle management | Automatic (builds), managed (cache) |
| **Configuration complexity** | High (pre-allocate, track indices) | Low (2 volume definitions) |
| **Storage cost** | High (N×2 PVCs for N concurrent jobs) | Low (1 shared PVC + emptyDir) |
| **RWX requirement** | No | Yes (for cache PVC only) |

---

## Monitoring and Maintenance

### Cache Size Monitoring

```bash
# Check cache PVC usage
kubectl exec -n gitlab-runner deployment/gitlab-runner -- du -sh /cache

# Detailed breakdown
kubectl exec -n gitlab-runner deployment/gitlab-runner -- du -h --max-depth=2 /cache
```

### Cache Cleanup

Implement periodic cleanup for stale caches:

```bash
# Find caches older than 30 days
kubectl exec -n gitlab-runner deployment/gitlab-runner -- \
  find /cache -type f -mtime +30 -delete
```

Or use a CronJob:

```yaml
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: gitlab-cache-cleanup
  namespace: gitlab-runner
spec:
  schedule: "0 2 * * 0"  # Weekly on Sunday at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: cleanup
            image: busybox
            command:
            - sh
            - -c
            - find /cache -type f -mtime +30 -delete
            volumeMounts:
            - name: cache
              mountPath: /cache
          volumes:
          - name: cache
            persistentVolumeClaim:
              claimName: gitlab-runner-cache
          restartPolicy: OnFailure
```

### Resource Quotas

Limit total resource consumption in the runner namespace:

```yaml
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gitlab-runner-quota
  namespace: gitlab-runner
spec:
  hard:
    requests.storage: "200Gi"  # Total storage across all PVCs
    persistentvolumeclaims: "5"  # Max number of PVCs
    pods: "20"  # Max concurrent job pods
    limits.cpu: "20"
    limits.memory: "40Gi"
```

---

## Troubleshooting

### Issue: PVC Not Binding

**Symptom:** PVC stuck in `Pending` state

**Check:**
```bash
kubectl describe pvc gitlab-runner-cache -n gitlab-runner
```

**Solutions:**
- Verify storage class exists and supports RWX
- Check storage provisioner is running
- Verify sufficient storage quota

### Issue: Cache Conflicts

**Symptom:** Jobs failing with corrupted cache or unexpected files

**Solutions:**
- Verify cache keys are unique per project/branch
- Check `.gitlab-ci.yml` cache configuration
- Consider adding `$CI_JOB_NAME` to cache key for job-level isolation

### Issue: Out of Disk Space on emptyDir

**Symptom:** Job fails with "no space left on device"

**Solutions:**
- Remove `medium = "Memory"` to use node disk instead of RAM
- Increase node disk space
- Add size limit: `size_limit = "10Gi"`
- Reduce `GIT_DEPTH` in `.gitlab-ci.yml`

### Issue: Slow Cache Access

**Symptom:** Cache operations take excessive time

**Solutions:**
- Verify storage class performance characteristics
- Consider local-path or SSD-backed storage for cache PVC
- Check network latency to storage backend
- Monitor NFS/storage server load

---

## Security Considerations

### PVC Access Control

Ensure only runner pods can access the cache PVC:

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gitlab-runner-cache
  namespace: gitlab-runner
  labels:
    app: gitlab-runner
    restricted: "true"
# ... spec ...
```

### Namespace Isolation

Run GitLab Runner in a dedicated namespace with RBAC:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: gitlab-runner
  labels:
    name: gitlab-runner
    pod-security.kubernetes.io/enforce: baseline
```

### Cache Encryption

For sensitive data in cache, consider:

1. Using encrypted storage class
2. Enabling encryption at rest on your storage backend
3. Avoiding caching sensitive files (use artifacts instead)

---

## References

- [GitLab Runner Kubernetes Executor](https://docs.gitlab.com/runner/executors/kubernetes.html)
- [GitLab CI/CD Caching](https://docs.gitlab.com/ee/ci/caching/)
- [Kubernetes Volumes](https://kubernetes.io/docs/concepts/storage/volumes/)
- [Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
