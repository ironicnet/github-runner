# github-runner

Containerized GitHub Actions self-hosted runner for Coolify or any other self-hosted environment.

This image follows GitHub's self-hosted runner model by downloading the official `actions/runner`, configuring it in unattended mode, and then starting the runner process inside the container.

## Features

- Runs the official GitHub self-hosted runner
- Works in Coolify or any Docker-compatible self-hosted platform
- Supports Docker CLI, Docker Compose, and Buildx through the host Docker daemon
- Supports Node.js and pnpm inside the runner container
- Configurable entirely with environment variables
- Can target repository, organization, or enterprise runners
- Can be deployed multiple times for different repos, projects, organizations, or users

## Environment variables

Copy `.env.example` and set the values for your deployment.

### Required

- `GITHUB_URL`: Repository, organization, or enterprise URL to register against
  - Repository example: `https://github.com/OWNER/REPOSITORY`
  - Organization example: `https://github.com/ORG`
  - GitHub Enterprise Server organization example: `https://GITHUB_HOST/orgs/ORG/settings/actions/runners`
  - Enterprise example: `https://github.com/enterprises/ENTERPRISE`
- One of:
  - `RUNNER_TOKEN`: short-lived runner registration token from GitHub
  - `GITHUB_PAT`: personal access token or fine-grained token that can create/remove self-hosted runner registration tokens
  - `GITHUB_TOKEN`: alternate token variable name for the same purpose

### Optional

- `GITHUB_API_URL`: override API base URL, useful for GitHub Enterprise Server
- `RUNNER_NAME`: custom runner name; defaults to `hostname-random`
- `RUNNER_WORKDIR`: runner work directory, default `_work`
- `RUNNER_LABELS`: comma-separated labels, default `self-hosted,linux`
- `RUNNER_GROUP`: runner group for organization or enterprise runners
- `RUNNER_EPHEMERAL`: `true` to use an ephemeral runner
- `RUNNER_REPLACE`: `true` to replace an existing runner with the same name
- `RUNNER_DISABLE_UPDATE`: `true` to disable automatic runner updates
- `RUNNER_NO_DEFAULT_LABELS`: `true` to omit default labels
- `DOCKER_SOCKET`: Docker socket path to use for host-daemon access, default `/var/run/docker.sock`
- `NODE_VERSION`: Node.js version to install/activate at startup, default `22`
- `PNPM_VERSION`: pnpm version to activate with Corepack, default `10.17.1`
- `RUNNER_HOME`: runner installation directory, default `/home/runner/actions-runner`

## Build

```bash
docker build -t github-runner .
```

## Run

```bash
docker run --rm \
  --env-file .env \
  -v /var/run/docker.sock:/var/run/docker.sock \
  github-runner
```

The container is designed to use the host Docker daemon through a mounted socket instead of Docker-in-Docker. On startup, the entrypoint detects the socket GID and grants the `runner` user access dynamically so host-specific Docker group IDs do not need to be hard-coded into the image.

## Coolify deployment

Use the repository as a Dockerfile-based service in Coolify and set the same environment variables from `.env.example`.

To deploy runners for multiple repositories, projects, organizations, or users, create multiple Coolify services (or multiple container instances) and give each deployment its own:

- `GITHUB_URL`
- runner token or PAT
- `RUNNER_NAME`
- optional label set

That keeps each runner independently scoped while reusing the same image.

For Docker-based CI workloads, mount `/var/run/docker.sock` into the service so workflows can use `docker`, `docker compose`, and `docker buildx` against the host daemon.

## Validation workflow

Normal push and pull request validation is intended to run on a self-hosted runner labeled `github-runner`:

```yaml
runs-on: [self-hosted, github-runner]
```

The repository also keeps a manual `workflow_dispatch` bootstrap path on `ubuntu-latest` so the very first runner can still be validated before self-hosted infrastructure is available.

## Runner version updates

`Dockerfile` pins a specific `actions/runner` release. Keep it reasonably current by periodically reviewing upstream releases and updating `RUNNER_VERSION` after validating the new artifact URLs and image build. The validation workflow checks the pinned download URLs for both supported architectures so stale pins fail quickly.

## Notes

- If you provide `GITHUB_PAT` or `GITHUB_TOKEN`, the container can request both registration and removal tokens from GitHub, deregister the runner when the container exits, and then register it again on the next startup. Persisting `RUNNER_HOME` in that mode keeps the local runner files, but the registration itself is recreated on each container start.
- If you provide only `RUNNER_TOKEN`, the runner can register, but deregistration on shutdown is skipped because GitHub requires a separate remove token.
- If you persist `RUNNER_HOME` and later change `GITHUB_URL`, `RUNNER_NAME`, labels, or related runner settings, provide `GITHUB_PAT` or `GITHUB_TOKEN` so the container can safely remove the old registration and create a new one.
- If `RUNNER_EPHEMERAL=true`, treat `RUNNER_HOME` as non-persistent storage. When a PAT/token is available the container will remove the ephemeral registration on exit; without one, terminating the container before the runner completes a job can leave a stale remote registration in GitHub.
- The default labels include `github-runner` and `docker` so the repository can target these runners for self-validation while still advertising Docker-capable execution.
- Node.js and pnpm are prepared inside the container so workflows can use them without extra setup.

## Reference

- https://docs.github.com/en/actions/concepts/runners/self-hosted-runners