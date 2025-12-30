
# [GitLab Runners on RHEL](https://chat.deepseek.com/share/u6s8c9cy25pi4h51j1)

GitLab Runner Architecture

    GitLab Server
        |
        | (API)
        |
    GitLab Runner Process (on remote host)
        |
        |-- Runner Instance 1 (shell) -- Token 1
        |-- Runner Instance 2 (ssh) --- Token 2  
        |-- Runner Instance 3 (docker) - Token 3
        |-- Runner Instance 4 (ssh) --- Token 4


## Register a host runner

A runner may have __many executors__, 
but each is registered (unique) at GtiLab host; 
each has their own token.

See [`config.toml.tpl`](config.toml.tpl)

1. At GitLab host Web UI

__Groups__ > `<select the group>` > __Build__ > __Runners__ > __Create group runner__ (button)

Copy the token `glrt-REDACTED`

2. At `gitlab-runner` host

```bash
glrt=glrt-REDACTED # Obtained from GitLab host
gitlab-runner register  --url https://$GITLAB_HOST  --token $glrt
```

### ssh executor

Target host(s), where Jobs of this ssh executor are performed, 
must have the SSH user (`gitlab-runner`).

@ `/etc/gitlab-runner/config.toml`

```toml
[[runners]]
  name = "fips-ssh-executor"
  executor = "ssh"
  [runners.ssh]
    user = "gitlab-runner"
    host = "glr01"
    # Key per project
    identity_file = "/etc/gitlab-runner/keys/prj_${CI_PROJECT_NAMESPACE}_ecdsa"
    # FIPS-compliant SSH options
    ssh_config = "/etc/gitlab-runner/ssh_config"
```

Add audit trail 

@ `.gitlab-ci.yml`

```yaml
before_script:
  - |
    echo "=== Pipeline Trigger Information ==="
    echo "Triggered by: $GITLAB_USER_NAME ($GITLAB_USER_EMAIL)"
    echo "User ID: $GITLAB_USER_ID"
    echo "Pipeline: $CI_PIPELINE_ID"
    echo "Job: $CI_JOB_NAME"
    echo "====================================="
```

#### Security Context

While you can identify the GitLab user, 
the SSH executor runs as the configured SSH user __regardless of who triggered the pipeline__. 

This means:

- All users share the same system-level permissions on the runner host.
- Cannot enforce user-specific system permissions at the OS level.
- Auditing must happen through GitLab's pipeline logs, not system log.

---

# [`gitlab-runner` on K8S](https://docs.gitlab.com/runner/install/kubernetes/)


## [`[runners.kubernetes]`](https://docs.gitlab.com/runner/configuration/advanced-configuration/#the-runnerskubernetes-section)

- [Helper image](https://docs.gitlab.com/runner/configuration/advanced-configuration/#helper-image) handles Git, artifacts, and cache operations. Override default helper image by setting `runners.kubernetes.helper_image` key. Default helper image is set according to (main) runner image name, variant, version and arch.

- [`[runners.custom_build_dir]`](https://docs.gitlab.com/runner/configuration/advanced-configuration/#the-runnerscustom_build_dir-section) is __enabled by default__ if `executor` is `kubernetes`. 
It requires that `GIT_CLONE_PATH` is in a path defined in `runners.builds_dir`. 
To use the `builds_dir`, use the `$CI_BUILDS_DIR` variable.

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


## Storage Isolation 

Regarding GitLab CI pipelines having a kubernetes executor configured for default `/build` and `/cache` locations, __filesystem and build isolation__ must be managed at pipeline definition, `.gitlab-ci.yml`, if concurrent jobs per runner are allowed, else &hellip;

__Problem__:

- `/builds`: By default, this is a Persistent Volume Claim (PVC) shared by all jobs on the runner. Concurrent jobs will have their project directories created here (e.g., `/builds/group-name/project-name/`). If _two jobs from the same project_ run concurrently, they will likely _clone into the same directory_, causing corruption.
- `/cache`: This is also a shared PVC. If concurrent jobs read from and write to the cache simultaneously, you can experience race conditions, corrupted cache archives, or jobs using incomplete cache.

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
# Max number of jobs a single runner process can handle simultaneously
concurrent = 4 # Each requires a PVC/PV pair.

[[runners]]
  builds_dir = "/mnt/builds"
  cache_dir = "/mnt/cache"

  # This block is not required if executor = kubernetes
  [runners.custom_build_dir]
    enabled = true

  [runners.kubernetes]
    limit = 4 # Concurrency per runner; cannot exceed global concurrent 
    [[runners.kubernetes.volumes.pvc]]
      # Requires StorageClass providing DYNAMIC PROVISIONING
      name = "builds-pvc-$CI_CONCURRENT_ID" 
      mount_path = "/mnt/builds"

    [[runners.kubernetes.volumes.pvc]]  
      #name = "cache-pvc-$CI_CONCURRENT_ID"
      name = "shared-cache-pvc" # Shared across concurrency
      mount_path = "/mnt/cache"
      storage_class = "fast-ssd"
      storage_size = "20Gi"

```
- Enable long polling at `/etc/gitlab/gitlab.rb`
  - `gitlab_workhorse['api_ci_long_polling_duration'] = "30s"`

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

Without isolation at the gitlab-runner TOML definition, 
we can do this at `.gitlab-ci.yml`

```yaml
job_a:
  variables:
    GIT_CLONE_PATH: $CI_BUILDS_DIR/$CI_PROJECT_NAMESPACE/$CI_PROJECT_NAME-$CI_JOB_NAME
  cache:
    key: "$CI_JOB_NAME-$CI_COMMIT_REF_SLUG"
    paths:
      - node_modules/
  script:
    - echo "This job clones into a unique directory."

job_b:
  variables:
    GIT_CLONE_PATH: $CI_BUILDS_DIR/$CI_PROJECT_NAMESPACE/$CI_PROJECT_NAME-$CI_JOB_NAME
  cache:
    key: "$CI_JOB_NAME-$CI_COMMIT_REF_SLUG"
    paths:
      - node_modules/
  script:
    - echo "So does this one, avoiding conflicts with job_a."
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

### Runners per Job Size

```toml
# Runner for lightweight jobs
[[runners]]
  name = "small-jobs"
  token = "token-small"
  limit = 8  # Can handle many small jobs
  tag_list = ["small", "test"]

# Runner for heavyweight jobs
[[runners]]
  name = "large-jobs" 
  token = "token-large"
  limit = 2  # Only 2 large jobs at once
  tag_list = ["large", "build"]
```

### `ResourceQuota` Management

CI/CD Jobs namespace should differ from that of 
the deployed applications built by those CI/CD pipelines.

```yaml
---
# CI namespace - limit runner resources
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gitlab-runner-quota
  namespace: gitlab-ci
spec:
  hard:
    pods: "20"
    limits.cpu: "16"
    limits.memory: "32Gi"
---
# App namespace - separate quota
apiVersion: v1
kind: ResourceQuota
metadata:
  name: app-production-quota
  namespace: my-app-production
spec:
  hard:
    pods: "50"
    limits.cpu: "32"
    limits.memory: "64Gi"
```

### RBAC Isolation

```yaml
---
# GitLab Runner has limited permissions
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: gitlab-ci
rules:
- apiGroups: [""]
  resources: ["pods", "pods/exec"]
  verbs: ["get", "list", "create", "delete"]
---
# App namespace has different permissions  
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: my-app-production
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "create", "patch"]
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



