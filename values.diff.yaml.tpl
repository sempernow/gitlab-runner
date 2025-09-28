image:
  registry: $GLR_IMAGE_REGISTRY
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
    [[runners]]
      name      = "$GLR_JOBS"
      url       = "https://$GLR_HOST/"
      executor  = "kubernetes"

      [runners.kubernetes]
        ## See $GLR_RBAC
        service_account = "${GLR_JOBS}-sa"
        namespace       = "$GLR_JOBS"
        pull_policy     = "if-not-present"
        privileged      = false
        
        cpu_request     = "100m"
        memory_request  = "128Mi"
        cpu_limit       = "500m"
        memory_limit    = "256Mi"

        helper_memory_limit   = "250Mi"
        helper_memory_request = "250Mi"
        helper_memory_limit_overwrite_max_allowed = "1Gi"
