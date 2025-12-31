image:
  registry: $GLR_IMAGE_REGISTRY
  ## The default helper image is chosen by this (main) image name, variant, version, and arch.
  image: $GLR_IMAGE_REPO/gitlab-runner 
  tag: $GLR_IMAGE_TAG

gitlabUrl: https://$GLR_HOST/

concurrent: 5

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
    ## - Controlled by two ill-defined parameters, "concurrency" and "request_concurrency", smeared across different TOML contexts.
    ## - Their defaults result in several fail modes. 
    ## - Set both to same value; the desired maximum number of concurrent runners.
    ## - Ignore all the ill-worded documentation on this topic that is peppered across "GitLab Docs".
    
    concurrent  = 4

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

        ## Main build container : Executes the active Job 
        ## - Runs job scripts (build, test, deploy) : Does the heavy lifting.
        cpu_request     = "100m"
        cpu_limit       = "500m"
        memory_request  = "128Mi"
        memory_limit    = "256Mi"

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
          ## Some of the labels delared here are also captured in pod.metadata.annotations 
          ## or host-created pod.metatada.labels at project.runner.<HOST_FQDN>/* keys.
          gitlab-user-name      = "GITLAB_USER_NAME"
          gitlab-user-id        = "GITLAB_USER_ID"
          ci-project-name       = "CI_PROJECT_NAME"
          ci-project-path       = "CI_PROJECT_PATH"
          ci-commit-branch      = "CI_COMMIT_BRANCH"
          ci-commit-sha         = "CI_COMMIT_SHA"
          ci-commit-timestamp   = "CI_COMMIT_TIMESTAMP"
          ci-commit-author      = "CI_COMMIT_AUTHOR"
          ci-pipeline-id        = "CI_PIPELINE_ID"
          ci-pipeline-url       = "CI_PIPELINE_URL"
          ci-job-name           = "CI_JOB_NAME"
          ci-job-id             = "CI_JOB_ID"
          ci-job-image          = "CI_JOB_IMAGE"

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
