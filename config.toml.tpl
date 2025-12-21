# /etc/gitlab-runner/config.toml
concurrent = 10  # Total concurrent jobs across all runners

# Runner 1: Shell executor (for general jobs)
[[runners]]
  name = "rhel-shell-runner"
  url = "https://$GITLAB_HOST"
  token = "$PROJECT_TOKEN_1"
  executor = "shell"
  tag_list = ["rhel", "shell"]  # Jobs with these tags will use this runner

  shell = "bash"
  builds_dir = "/home/gitlab-runner/builds"
  [runners.custom_build_dir]
  [runners.cache]
    [runners.cache.s3]
    [runners.cache.gcs]
    [runners.cache.azure]

# Runner 2: SSH executor (for deployment to specific hosts)
[[runners]]
  name = "ssh-prod-deploy"
  url = "https://$GITLAB_HOST"
  token = "$PROJECT_TOKEN_2"
  executor = "ssh"
  tag_list = ["rhel", "ssh"]  # Deployment jobs
  [runners.ssh]
    host = "production-server.example.com"
    port = "22"
    user = "deploy"
    password = ""  # Use SSH keys instead
    identity_file = "/home/gitlab-runner/.ssh/id_ed25519_deploy"
  [runners.cache]
    [runners.cache.s3]

# Runner 3: Docker executor (for isolated builds)
[[runners]]
  name = "docker-isolated-runner"
  url = "https://$GITLAB_HOST"
  token = "$PROJECT_TOKEN_3"
  executor = "docker"
  tag_list = ["rhel", "docker", "build", "test"]
  [runners.docker]
    image = "alpine:latest"
    privileged = false
    disable_entrypoint_overwrite = false
    oom_kill_disable = false
    disable_cache = false
    volumes = ["/cache", "/home/gitlab-runner/.ssh:/root/.ssh:ro"]
    shm_size = 0
    pull_policy = "if-not-present"
  [runners.cache]

# Runner 4: Another Docker executor with different configuration
[[runners]]
  name = "docker-custom-runner"
  url = "https://$GITLAB_HOST"
  token = "$PROJECT_TOKEN_4"
  executor = "docker"
  tag_list = ["rhel", "docker", "custom"]

  [runners.docker]
    image = "docker:stable"
    privileged = true  # For Docker-in-Docker
    volumes = ["/var/run/docker.sock:/var/run/docker.sock", "/cache"]