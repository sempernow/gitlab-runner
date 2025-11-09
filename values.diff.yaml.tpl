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
    ## The total number of concurrent jobs per runner
    concurrent  = 10

    [[runners]]
      name        = "$GLR_JOBS"
      url         = "https://$GLR_HOST/"
      executor    = "kubernetes"
      
      ## Authentication Token (obtained upon runner registration) is added by helm --set method

      ## Custom /builds and /cache
      ## Tunable params; StorageClass, size, ...
      # builds_dir  = "/mnt/builds"
      # cache_dir   = "/mnt/cache"

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
        limit = 4 # Concurrency limit for this runner; less than global concurrent.

        cpu_request     = "100m"
        memory_request  = "128Mi"
        cpu_limit       = "500m"
        memory_limit    = "256Mi"

        helper_memory_limit   = "250Mi"
        helper_memory_request = "250Mi"
        helper_memory_limit_overwrite_max_allowed = "1Gi"

        # [[runners.kubernetes.volumes.pvc]]
        #   ## Requires StorageClass having dynamic provisioning
        #   name = "builds-pvc-$CI_CONCURRENT_ID"
        #   mount_path = "/mnt/builds"

        # [[runners.kubernetes.volumes.pvc]]  
        #   ## Share cache across jobs
        #   #name = "cache-pvc-$CI_CONCURRENT_ID"
        #   name  = "shared-cache-pvc" 
        #   mount_path      = "/mnt/cache"
        #   #storage_class  = "fast-ssd"
        #   #storage_size   = "20Gi"
