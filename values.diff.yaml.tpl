image:
  registry: $GLR_IMAGE_REGISTRY
  ## The default helper image is chosen by this (main) image name, variant, version, and arch.
  image: $GLR_IMAGE_REPO/gitlab-runner 
  tag: $GLR_IMAGE_TAG

gitlabUrl: https://$GLR_HOST/

## Global max jobs across all runners under this controller.
## concurrent >= sum of all runner limits. See .runners.config (TOML) section.
concurrent: 4

rbac:
  create: false

## Inform the chart of this ServiceAccount, but create it elsewhere. 
## See $GLR_RBAC
serviceAccount: 
  create: false
  name: ${GLR_MANAGER}-sa

runners:
  config: |
    ## Concurrency TL;DR
    ## - concurrent: Global max jobs across all runners 
    ## - request_concurrency: Parallel job requests to GitLab (reduces queue latency)
    ## - limit: Max concurrent jobs for this specific runner/executor

    [[runners]]
      name        = "$GLR_JOBS"
      url         = "https://$GLR_HOST/"
      executor    = "kubernetes"
     
      #environment = ["FF_USE_ADAPTIVE_REQUEST_CONCURRENCY=true"] # Supposedly adaptive; DO NOT USE.
      request_concurrency = 4

      ## Authentication Token (obtained upon runner registration) is added by helm --set method

      ## Custom /builds and /cache
      ## See https://docs.gitlab.com/ci/runners/configure_runners/#custom-build-directories
      builds_dir  = "/builds" # Ephemeral
      # cache_dir   = "/cache"  # S3

      ## Not required (is default) at kubernetes executor
      # [runners.custom_build_dir]
      #   enabled = true

      [runners.kubernetes]
        ## See $GLR_RBAC
        service_account       = "${GLR_JOBS}-sa"
        namespace             = "$GLR_JOBS"
        privileged            = false
        pull_policy           = "if-not-present"
        image_pull_secrets    = ["$GLR_DOCKER_HUB_SECRET"]
        limit                 = 4 # Concurrency limit for this runner; less than global concurrent.
        cleanup_grace_period_seconds = 60
        poll_timeout                 = 180

        ## Main build container : Executes the active Job
        ## - Runs job scripts (build, test, deploy) : Does the heavy lifting.
        cpu_request     = "250m"
        cpu_limit       = "2000m"
        memory_request  = "512Mi"
        memory_limit    = "2Gi"

        ## Helper container : Setup/Teardown
        ## - Runs git clone/fetch, handle artifacts and cache ops : Short lived.
        helper_cpu_request    = "100m"
        helper_memory_request = "128Mi"
        helper_memory_limit   = "256Mi"

        ## Service container(s) : 1 per service
        ## - Each runs concurrently throughout the Job 
        service_cpu_request     = "100m"
        service_memory_request  = "128Mi"
        service_memory_limit    = "256Mi"

        [runners.kubernetes.pod_labels]
          ## Labels with valid K8s label values only (alphanumeric, -, _, .)
          gitlab-user-id        = "$GITLAB_USER_ID"
          ci-project-name       = "$CI_PROJECT_NAME"
          ci-commit-branch      = "$CI_COMMIT_BRANCH"
          ci-commit-sha         = "$CI_COMMIT_SHA"
          ci-pipeline-id        = "$CI_PIPELINE_ID"
          ci-job-name           = "$CI_JOB_NAME"
          ci-job-id             = "$CI_JOB_ID"

        [runners.kubernetes.pod_annotations]
          ## Annotations for values that may contain invalid label characters (URLs, paths, emails, colons)
          "gitlab.com/user-name"        = "$GITLAB_USER_NAME"
          "gitlab.com/project-path"     = "$CI_PROJECT_PATH"
          "gitlab.com/commit-timestamp" = "$CI_COMMIT_TIMESTAMP"
          "gitlab.com/commit-author"    = "$CI_COMMIT_AUTHOR"
          "gitlab.com/pipeline-url"     = "$CI_PIPELINE_URL"
          "gitlab.com/job-image"        = "$CI_JOB_IMAGE"

        [runners.kubernetes.pod_security_context]
          run_as_non_root = true
          run_as_user     = 1001
          fs_group        = 1001

        # [[runners.kubernetes.volumes.pvc]]
        #   ## Requires StorageClass having dynamic provisioning
        #   name = "builds-pvc-CI_CONCURRENT_ID"
        #   mount_path = "/builds"

        # [[runners.kubernetes.volumes.pvc]]  
        #   ## Share cache across jobs
        #   #name = "cache-pvc-CI_CONCURRENT_ID"
        #   name  = "shared-cache-pvc" 
        #   mount_path      = "/cache"
        #   #storage_class  = "fast-ssd"
        #   #storage_size   = "20Gi"

        [[runners.kubernetes.volumes.empty_dir]]
          name = "builds"
          mount_path = "/builds"
          medium = "Memory"  # Optional: /dev/shm : RAM-backed (tmpfs) for speed
          # OR omit 'medium' to use node disk storage

        [[runners.kubernetes.volumes.host_path]]
          name = "smb-data"
          mount_path = "/mnt/smb-data"
          ## Mount point of the SMB on node(s) 
          host_path = "/mnt/smb-data-01"

