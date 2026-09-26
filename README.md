# github-runner

Containerized GitHub Actions self-hosted runner for Coolify or any other self-hosted environment.

This image follows GitHub's self-hosted runner model by downloading the official `actions/runner`, configuring it in unattended mode, and then starting the runner process inside the container.

## Features

- Runs the official GitHub self-hosted runner
- Works in Coolify or any Docker-compatible self-hosted platform
- Supports Node.js and pnpm inside the runner container
- Configurable entirely with environment variables
- Can target repository, organization, or enterprise runners
- Can be deployed multiple times for different repos, projects, organizations, or users

## Environment variables

Copy `/home/runner/work/github-runner/github-runner/.env.example` and set the values for your deployment.

### Required

- `GITHUB_URL`: Repository, organization, or enterprise URL to register against
  - Repository example: `https://github.com/OWNER/REPOSITORY`
  - Organization example: `https://github.com/ORG`
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
  github-runner
```

## Coolify deployment

Use the repository as a Dockerfile-based service in Coolify and set the same environment variables from `.env.example`.

To deploy runners for multiple repositories, projects, organizations, or users, create multiple Coolify services (or multiple container instances) and give each deployment its own:

- `GITHUB_URL`
- runner token or PAT
- `RUNNER_NAME`
- optional label set

That keeps each runner independently scoped while reusing the same image.

## Notes

- If you provide `GITHUB_PAT` or `GITHUB_TOKEN`, the container can request both registration and removal tokens from GitHub and will deregister the runner when the container exits.
- If you provide only `RUNNER_TOKEN`, the runner can register, but deregistration on shutdown is skipped because GitHub requires a separate remove token.
- Node.js and pnpm are prepared inside the container so workflows can use them without extra setup.

## Reference

- https://docs.github.com/en/actions/concepts/runners/self-hosted-runners