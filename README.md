
# [`gitlab-runner` on K8S](https://docs.gitlab.com/runner/install/kubernetes/)

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

## [GitLab Runner](https://gitlab.com/gitlab-org/gitlab-runner) | [Releases](https://gitlab.com/gitlab-org/gitlab-runner/-/releases)


### [Helm chart : How To](https://docs.gitlab.com/runner/install/kubernetes/)

```bash
repo=gitlab
chart=gitlab-runner
ver=0.76.3 # runner: v17.11.3
ns=glr-manager # gitlab-runner : Controller only
release=$chart
values=values.yaml
secret=glrt-secret
tkn="$(<$secret.key)"

# Instead of this, add token secret at helm upgrade using --set method
# kubectl create ns $ns
# kubectl create secret generic $secret \
#     --from-literal=runner-token="$tkn" \
#     -n $ns

# Apply RBAC for both Manager and Jobs
kubectl apply -f rbac.$release.yaml

# Add repo
helm repo update $repo ||
    helm repo update $repo

# Available versions : chart vs. runner
helm search repo -l $repo/$chart

# Pull chart to extract values.yaml
helm pull $repo/$chart --version $ver &&
    tar -xaf ${chart}-$ver.tgz &&
        cp gitlab-runner/values.yaml values.default.yaml &&
            rm ${chart}-$ver.tgz

# Mod : Keep only the modified sections 
vi $values

# Compare
diff values.default.yaml values.yaml |grep -- '>'

# Generate declared state : K8s manifest (YAML)
helm template $release $repo/$chart --version $ver -n $ns \
    --values $values \
    --set runnerToken="$(<$secret.key)" \
    |tee helm.template.yaml

# Install/Upgrade
helm upgrade $release $repo/$chart --install --version $ver -n $ns \
    --create-namespace \
    --values $values \
    --set runnerToken="$(<$secret.key)" \
    --debug \
    --atomic \
    --timeout 2m \
    |tee helm.upgrade.log

# Capture the running state
helm get manifest $release -n $ns |tee helm.manifest.yaml

# Compare declared v. running
diff helm.template.yaml helm.manifest.yaml

```
- [`helm.template.yaml`](helm.template.yaml)


Logs

```bash
☩ k logs pod/gitlab-runner-dff845bf9-2g7x8 -f
Registration attempt 1 of 30
...
Runner registered successfully. ...
...

```

App

```bash
☩ k get $all -l app=gitlab-runner
NAME                                           CREATED AT
role.rbac.authorization.k8s.io/gitlab-runner   2025-09-27T18:04:20Z

NAME                                                  ROLE                 AGE
rolebinding.rbac.authorization.k8s.io/gitlab-runner   Role/gitlab-runner   9m38s

NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/gitlab-runner   1/1     1            1           9m38s

NAME                                 READY   STATUS    RESTARTS   AGE
pod/gitlab-runner-86d4977ff7-xjwmm   1/1     Running   0          6m

NAME                      DATA   AGE
configmap/gitlab-runner   6      9m38s

NAME                   TYPE     DATA   AGE
secret/gitlab-runner   Opaque   2      9m38s
```

### [Configuration Settings](https://docs.gitlab.com/runner/executors/kubernetes/#configuration-settings)

```yaml
  config.template.toml:   |
    [[runners]]
      # Per-job (ephemeral) runners 
      [runners.kubernetes]
        service_account = "gitlab-runner"
        namespace = "glr-jobs"

        cpu_request = "100m"
        memory_request = "128Mi"
        cpu_limit = "1"
        memory_limit = "512Mi"

        helper_memory_limit = "250Mi"
        helper_memory_request = "250Mi"
        helper_memory_limit_overwrite_max_allowed = "1Gi"

```
- Limits for helper:
    - Workloads with caching/artifact generation: Minimum __`250 MiB`__
    - Basic workloads sans cache/artifacts: Might work with lower limits (128-200 MiB)



## Create a New Runner

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

Create K8s Secret `data.runner-token` expected by Helm chart

```bash
ns=glr-manager
secret=glrt-secret
tkn="$(<$secret.key)"

# Case 1. gitlab-runner on host
type gitlab-runner &&
    gitlab-runner register --url https://gitlab.com  --token $tkn

# Case 2. gitlab-runner on K8s
kubectl create ns $ns
kubectl create secret generic glrt-secret \
    --from-literal=runner-token="$tkn" \
    -n $ns

# Verify
kubectl -n $ns get secret glrt-secret -o jsonpath='{.data.runner-token}' |base64 -d

# Inject into values.yaml (idempotent) : No such key in this chart version
#sed -i 's/runnerTokenSecret: ""/runnerTokenSecret: "'$secret'"/' values.yaml

```

Inject secret at runtime using `--set` override

```bash
helm upgrade ... --set runnerToken="$(<$secret.key)"
```

## Project `cicd-test`

Success at CI Job requesting protected Job endpoint !

@ `.gitlab-ci.yml`

```yaml
default:
  image: badouralix/curl-jq
  tags:
    - k8s1

stages:
  - test

test-job:
  stage: test
  script: |
    url="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines/${CI_PIPELINE_ID}/jobs"
    echo URL - $url
    echo CI_JOB_TOKEN - $CI_JOB_TOKEN
    curl --fail --show-error --silent --header "JOB-TOKEN: ${CI_JOB_TOKEN}" "$url" | jq . 

```

See [`cicd-test.jobs.11523146153.log`](cicd-test/cicd-test.jobs.11523146153.log)