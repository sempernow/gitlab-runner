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
    ## The total number of concurrent jobs across all runners of this controller
    concurrent  = 10

    [[runners]]
      name        = "$GLR_JOBS"
      url         = "https://$GLR_HOST/"
      executor    = "kubernetes"
      ## Authentication Token (obtained upon runner registration) is added by helm --set method

      [runners.kubernetes]
        ## See $GLR_RBAC
        service_account       = "${GLR_JOBS}-sa"
        namespace             = "$GLR_JOBS"
        privileged            = false
        pull_policy           = "if-not-present"
        image_pull_secrets    = ["$GLR_DOCKER_HUB_SECRET"]

        cpu_request     = "100m"
        memory_request  = "128Mi"
        cpu_limit       = "500m"
        memory_limit    = "256Mi"

        helper_memory_limit   = "250Mi"
        helper_memory_request = "250Mi"
        helper_memory_limit_overwrite_max_allowed = "1Gi"
