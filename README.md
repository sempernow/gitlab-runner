
# [`gitlab-runner` on K8S](https://docs.gitlab.com/runner/install/kubernetes/)

## [`[runners.kubernetes]`](https://docs.gitlab.com/runner/configuration/advanced-configuration/#the-runnerskubernetes-section)

- [Helper image](https://docs.gitlab.com/runner/configuration/advanced-configuration/#helper-image) handles Git, artifacts, and cache operations. Override default helper image by setting `runners.kubernetes.helper_image` key. Default helper image is set according to (main) runner image name, variant, version and arch.

- [`[runners.custom_build_dir]`](https://docs.gitlab.com/runner/configuration/advanced-configuration/#the-runnerscustom_build_dir-section) is __enabled by default__ if `executor` is `kubernetes`. 
It requires that `GIT_CLONE_PATH` is in a path defined in `runners.builds_dir`. 
To use the `builds_dir`, use the `$CI_BUILDS_DIR` variable.


## Storage Isolation 

### 1. K8s Infra Level

__Pre-allocate__ the per-concurrency volumes (__`builds-pvc-*`__).

Create the PVC/PV resources ___before___ __configuring runner__.

@ `pvc.yaml`

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: builds-pvc-0
  namespace: ci-jobs
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: fast-ssd  # ← Storage class here
  resources:
    requests:
      storage: 20Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: builds-pvc-1
  namespace: ci-jobs
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: fast-ssd  # ← Same storage class
  resources:
    requests:
      storage: 20Gi
```
- Dynamic provisioner, so PV created upon PVC creation.
    - Want : "`reclaimPolicy: Delete`", else `Recycle`  
      See "`kubectl explain sc.reclaimPolicy`"

```toml
concurrent = 4 # Each requires a PVC/PV pair.

[[runners]]
  builds_dir = "/mnt/builds"
  cache_dir = "/mnt/cache"
  
  [runners.kubernetes]
    [[runners.kubernetes.volumes.pvc]]
      name = "builds-pvc-$CI_CONCURRENT_ID"
      mount_path = "/mnt/builds"

    [[runners.kubernetes.volumes.pvc]]  
      #name = "cache-pvc-$CI_CONCURRENT_ID"
      name = "shared-cache-pvc" # Shared across concurrency
      mount_path = "/mnt/shared-cache"
      storage_class = "fast-ssd"
      storage_size = "20Gi"

```

### `/builds`

- Purpose: Where project source code is cloned and built
- Contains: Git repositories, build artifacts, temporary files
- __Isolation__: Critical for __concurrent jobs__

### `/cache`

- Purpose: Where pipeline caches are stored between jobs
- Contains: Dependency caches (`pip`, `npm`, etc.), build caches
- __Isolation__: __Per-project/branch__ cache isolation


### 2. GitLab Logic Level

Job definition has associated isoluation scheme

```yaml
cache:
  key: "$CI_COMMIT_REF_SLUG"  # ← Logical isolation
  paths:
    - node_modules/
    - .cache/
```
- __Dynamic cache__ keys __per project__/__branch__/__MR__
- Logical isolation - different projects/branches don't share cache
- Unlimited combinations - automatically managed by GitLab

### How (1.) + (2.) work together

```
Physical Layer (K8s PVCs):
build-pvc-0 → /builds/ (Job 1 running)
build-pvc-1 → /builds/ (Job 2 running) 
build-pvc-2 → /builds/ (Job 3 running)
build-pvc-3 → /builds/ (Job 4 running)

Logical Layer (GitLab Cache):
/builds/project-123/main/.cache/     (on build-pvc-0)
/builds/project-123/feature/.cache/  (on build-pvc-1) 
/builds/project-456/main/.cache/     (on build-pvc-2)
/builds/project-123/main/.cache/     (on build-pvc-3) ← Same logical cache, different physical slot!
```

### Repo Size per Clone depth

Default for GitLab runner is   
"`git clone --depth 50 $url`"

```bash
# 1. Generate single-file *.bundle of various depths
git bundle create full.bundle --all
git bundle create depth-50.bundle --all --depth=50
git bundle create depth-1.bundle --all --depth=1
# 2. Then compare their sizes
#find -name '*.bundle' -printf "%k\t%P\n"
ls -hl *.bundle
```

## [GitLab Runner](https://gitlab.com/gitlab-org/gitlab-runner) | [Releases](https://gitlab.com/gitlab-org/gitlab-runner/-/releases)


### Images

Helm chart does not reference the helper.   
Rather, automatically pulls that matching runner

```bash
version=17.11.3
arch=x86_64

runner=gitlab-org/gitlab-runner:v$version
helper=gitlab-org/gitlab-runner/gitlab-runner-helper:${arch}-v${version}

```
### GitLab Container Registry

- [Base images](https://gitlab.com/gitlab-org/ci-cd/runner-tools/base-images/-/tree/main/dockerfiles/runner)
    - [`registry.gitlab.com/gitlab-org/gitlab-runner`](https://gitlab.com/gitlab-org/gitlab-runner/container_registry)
    - [`registry.gitlab.com/gitlab-org/ci-cd/runner-tools`](https://gitlab.com/gitlab-org/ci-cd/runner-tools)

&nbsp;

```bash
☩ dit
IMAGE ID       REPOSITORY:TAG                                                                                 SIZE
02c727a1f782   registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:alpine3.21-x86_64-v17.11.3   90.9MB
d29f67270c65   registry.gitlab.com/gitlab-org/gitlab-runner:alpine3.21-v17.11.3                               198MB
```
```bash
img=registry.gitlab.com/gitlab-org/gitlab-runner:alpine3.21-v17.11.3
trivy image --scanners vuln --severity CRITICAL,HIGH $img

```


## [Helm chart : How To](https://docs.gitlab.com/runner/install/kubernetes/)

### [`make.gitlab-runner.sh`](make.gitlab-runner.sh)

```bash
bash make.gitlab-runner.sh up
```

### [`values.diff.yaml.tpl`](values.diff.yaml.tpl) | [Configuration Settings](https://docs.gitlab.com/runner/executors/kubernetes/#configuration-settings)


## @ GitLab host : Create a New Runner

At left-side menu:

__Groups__ > `<select the group>` > __Build__ > __Runners__ > __Create group runner__ (button)

Response page:

```
GitLab Runner must be installed before you can register a runner. How do I install GitLab Runner?

Step 1
Copy and paste the following command into your command line to register the runner.

gitlab-runner register  --url https://gitlab.com  --token glrt-REDACTED
 The runner authentication token glrt-REDACTED  displays here for a short time only. After you register the runner, this token is stored in the config.toml and cannot be accessed again from the UI.

Step 2
Choose an executor when prompted by the command line. Executors run builds in different environments. Not sure which one to select? 

Step 3 (optional)
Manually verify that the runner is available to pick up jobs.

gitlab-runner run
This may not be needed if you manage your runner as a system or user service .
```

Inject secret at runtime using `--set` override

```bash
helm upgrade ... --set runnerToken="$(<$secret.key)"
```
