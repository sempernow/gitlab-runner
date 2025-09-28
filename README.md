
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

#### [`gitlab-runner.sh`](gitlab-runner.sh)

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

Inject secret at runtime using `--set` override

```bash
helm upgrade ... --set runnerToken="$(<$secret.key)"
```
