# [Kubernetes executor](https://docs.gitlab.com/runner/executors/kubernetes/ "GitLab Docs : /runner/executors/kubernetes")

# Job Containers

The __three types__ of __containers__ referenced in 
the runner's TOML configuration file are:

## 1. **Main Build Container**
The container defined in your job (`.gitlab-ci.yml`):
- **Parameters**: `cpu_request`, `memory_limit`
- **Purpose**: Executes your actual CI/CD job scripts (build, test, deploy)
- **Heavy lifting**: **YES - THIS DOES THE HEAVY LIFTING**
- **What it runs**: Your actual job commands like `npm install`, `mvn compile`, `docker build`
- Resources: Typically needs the most CPU/memory for compilation, testing, etc.

## 2. **Helper Container**
- **Parameters**: `helper_cpu_request`, `helper_memory_limit`
- **Purpose**: Clones your Git repository and handles artifacts
- **Heavy lifting**: No (auxiliary role)
- **What it runs**: GitLab Runner helper image operations:
  - Git clone/fetch
  - Upload/download artifacts
  - Cache operations
- Typically needs minimal resources (just enough for Git operations)

## 3. **Services Container(s)**
- **Parameters**: `service_cpu_request`, `service_memory_limit` (per service)
- **Purpose**: Runs dependent services like databases, Redis, etc.
- **Heavy lifting**: No (supporting infrastructure)
- **What it runs**: Services defined in `services:` section of `.gitlab-ci.yml`
  - PostgreSQL, MySQL, Redis
  - Docker-in-Docker (dind)
  - Other application dependencies
- Resources: Varies based on service requirements

## Configuration Example in TOML:
```toml
[[runners]]
  executor = "kubernetes"
  [runners.kubernetes]
    cpu_request = "1"          # Main build container
    memory_request = "1Gi"
    cpu_limit = "2"
    memory_limit = "2Gi"
    
    helper_cpu_request = "200m"   # Helper container
    helper_memory_request = "256Mi"
    helper_memory_limit = "512Mi"
    
    service_cpu_request = "100m"  # Each service container
    service_memory_request = "128Mi"
    service_memory_limit = "256Mi"
```

## Key Points:
- **Main build container** consumes the most resources during active job execution
- **Helper container** is short-lived (mainly during job setup/teardown)
- **Services containers** run concurrently throughout the job
- Resource limits prevent any single container from hogging cluster resources
- CPU is often measured in millicores (1000m = 1 core)
- Memory is typically in Mi (Mebibytes) or Gi (Gibibytes)

For optimal performance, allocate resources based on your actual job requirements:
- Build jobs: More CPU for compilation
- Test jobs: Balance CPU/memory based on test framework
- Deploy jobs: Often minimal resources needed

---

# If Helper Container is Hogging Resources

A GitLab helper container using **3 GiB of memory is abnormal** 
and typically indicates one of three primary issues:


| Likelihood | Root Cause | Description |
| :--- | :--- | :--- |
| **Most Likely** | **Large Repository or Cache** | The helper handles Git cloning and cache restoration. Operations on repositories with __massive histories__, __binaries__, or a very large cache archive can spike memory usage. |
| **Very Likely** | **Configuration Limits or Bugs** | The container's `helper_memory_limit` may be set to 3GiB or higher, or a bug (like one related to `restore_cache`) could cause excessive memory consumption. |
| **Possible** | **Unrelated High Memory Use** | Another process (e.g., your main build script running in the wrong container) or a system-level issue might be consuming memory that is incorrectly attributed to the helper container. |

### 🔍 How to Diagnose and Resolve the Issue
To find the exact cause, follow this checklist:

1.  **Check Your Configuration**: First, inspect your runner's `config.toml` to see if a high `helper_memory_limit` is explicitly set. Also, review your job's `.gitlab-ci.yml` for any custom `resources:limits` applied to the helper.
2.  **Examine Repository and Cache**: Look at your project's size. Are you using Git LFS or storing large binaries? Check the size of your CI cache archives; they can bloat over time.
3.  **Review Job Logs**: Look at the detailed logs from the **Pre-build** stage. Logs for Git cloning or cache restoration (especially `restore_cache`) may show operations on large files. Increase the runner's `log_level` to `debug` for more detail.
4.  **Monitor Live Usage**: If possible, use `kubectl` commands to observe the pod while the job runs:
    ```bash
    # Watch resource usage for the specific pod
    kubectl top pod <your-gitlab-runner-pod-name> --containers
    ```
5.  **Search for Known Issues**: Check the GitLab Runner issue tracker for bugs related to helper memory, using keywords like "helper memory" or the issue number `#38870`.

### 💡 Actionable Solutions Based on the Cause
Once you identify the likely cause, you can apply a targeted fix:

- **If the issue is large repositories/cache**:
    - Optimize your repository by cleaning history or moving binaries to external storage.
    - Implement a more granular cache strategy to avoid huge archives (e.g., split cache by project part).
    - Consider using shallow Git cloning (`GIT_DEPTH`) in your CI job variables.

- **If the issue is configuration or a bug**:
    - Ensure `helper_memory_limit` is set to a reasonable value (e.g., `512Mi`).
    - Update GitLab Runner to the latest stable version, as memory-related bugs are often patched.

- **For general optimization**:
    - **Pre-clone**: For very large repos, use the [pre-clone script feature](https://docs.gitlab.com/runner/configuration/advanced-configuration.html#the-runnerspreclonescript-section) to maintain a ready-to-use copy on the runner host.
    - **Distribute Work**: For heavy processing, ensure it happens in the main **build container**, not the helper.

By systematically checking these areas—starting with your configuration and logs—you should be able to pinpoint why the helper container's memory is so high and take steps to bring it back to a normal range (typically a few hundred MiB).
