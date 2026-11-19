# Forgejo-runner-windows-builder

[![License](https://img.shields.io/github/license/Crown0815/Forgejo-runner-windows-builder)](https://github.com/Crown0815/Forgejo-runner-windows-builder/blob/main/LICENSE)
[![Release](https://img.shields.io/github/v/release/Crown0815/Forgejo-runner-windows-builder)](https://github.com/Crown0815/Forgejo-runner-windows-builder/releases)
[![Issues](https://img.shields.io/github/issues/Crown0815/Forgejo-runner-windows-builder)](https://github.com/Crown0815/Forgejo-runner-windows-builder/issues)
[![Forgejo Version](https://img.shields.io/badge/Forgejo-1.22+-blue)](https://forgejo.org)
[![Windows](https://img.shields.io/badge/Platform-Windows-blue)](https://github.com/Crown0815/Forgejo-runner-windows-builder)

A Windows-compiled version of the Forgejo Runner, providing a pre-built binary for executing Forgejo Actions workflows on Windows systems. 
This repository offers convenient downloads for users seeking a straightforward installation without the need for manual compilation.

## Status: experimental community build (Runner v13.2.1, Windows amd64, host jobs)

Upstream only supports Linux; this build is unofficial. The `Build Release` workflow (manual dispatch, defaults: tag `v13.2.1`, goal `draft`) builds the unmodified upstream tag for **Windows amd64** only and runs:

- the upstream `./internal/...` and `./act/...` Go tests on Windows (`test-runner` and `test-act`);
- an end-to-end test (`test-e2e`, [`e2e/run.ps1`](e2e/run.ps1)) against throwaway **Forgejo 15.0.12 (LTS) and 17.0.1** servers: it creates a repository-level runner through the API, connects the built `.exe` via `server.connections` with label `windows:host` and its own `host.workdir_parent`, cancels a running job (run must end `cancelled`, the step's process must be gone), then runs [`e2e/smoke.yml`](e2e/smoke.yml): `actions/checkout@v4`, the default shell (`pwsh`), `shell: powershell` (Windows PowerShell 5.1), `dotnet --version`, a job summary (checked on 17 only: Forgejo 15 does not show job summaries), and `forgejo/upload-artifact@v4` → `forgejo/download-artifact@v4` in a second job.

A release is only published as non-draft when all of these pass and goal is `release`. To try a build next to an existing setup (nothing else is changed):

1. Download `forgejo-runner-windows-amd64.exe` from a workflow run's artifacts or a draft release to e.g. `C:\forgejo-runner-test\`.
2. In a test repository: *Settings > Actions > Runners > Create new runner*. A repository-level runner only takes jobs from that repository.
3. Copy [`examples/windows-test/config.yml`](examples/windows-test/config.yml) next to the `.exe` and paste the `server.connections` snippet Forgejo shows (url, uuid, token).
4. Start it: `.\forgejo-runner-windows-amd64.exe daemon --config config.yml` (`register`/`create-runner-file` are deprecated in v13).
5. Add [`examples/windows-test/windows-test.yml`](examples/windows-test/windows-test.yml) to `.forgejo/workflows/` and start it via *Actions > Run workflow*; jobs use `runs-on: windows-test` and the default shell `pwsh`.

**Security:** host jobs run the repository's workflow code directly on the machine with the rights of the runner's Windows account; there is no container isolation. Do not run jobs from untrusted repositories or public pull requests on a machine that holds secrets or has access to anything you care about.

**Known limitations:**

- Only native Windows host jobs are tested. Docker/container jobs, Windows containers, `386` and `arm64` are not built or tested.
- `test-act` skips two upstream Docker CLI parsing tests (`TestParseRunLinks/bridge/onelink`, `TestParseNetworkConfig/invalid-mixed-network-types`): they assume Linux network semantics and fail on Windows, where the Docker API treats `bridge`/`host` as user-defined networks. This only concerns the Docker backend.
- `actions/upload-artifact@v4+`/`download-artifact@v4+` refuse non-GitHub servers (`GHESNotSupportedError`); use `forgejo/upload-artifact@v4` / `forgejo/download-artifact@v4` (or `@v3`). This is not Windows-specific.
- Keep `host.workdir_parent` short (default `%USERPROFILE%\.cache\act` works). The runner caches actions as `<workdir_parent>\…\xx\<62 hex>` with Git worktree metadata under `worktrees\<62 hex>`; when those paths exceed 260 characters Git fails with `gitfile does not point to a valid repository`, and `core.longpaths=true` did not help in our tests. Upstream `TestClone/Offline_mode_*` hits this from the default `%TEMP%` (`C:\Users\RUNNER~1\AppData\Local\Temp`), so `test-act` runs with `TMP`/`TEMP` set to the shorter `runner.temp`; the test itself still runs and passes.
- The e2e test covers one runner on a GitHub-hosted `windows-latest` VM, not long-running service installs, upgrades or your production setup.

## What is Forgejo?

Forgejo is a self-hosted, lightweight software forge designed for version control and collaboration. 
It is a community-driven [hard-fork of Gitea](https://forgejo.org/2024-02-forking-forward/), emphasizing ease of installation, low maintenance, and an inclusive governance model. 
Forgejo supports features such as Git repository hosting, issue tracking, pull requests, wikis, and continuous integration through Actions. 
It is suitable for individuals, teams, and organizations requiring a reliable, open-source alternative to proprietary platforms like GitHub.

Key characteristics include:

- **Lightweight and Efficient**: Minimal resource usage, making it ideal for deployment on modest hardware.
- **Self-Hosted**: Full control over data and infrastructure.
- **Community-Focused**: Governed by a transparent, democratic process.

For more details, refer to the [official Forgejo website](https://forgejo.org) and [documentation](https://forgejo.org/docs/latest/).

## What is the Forgejo Runner?

The Forgejo Runner is a daemon application responsible for executing jobs defined in Forgejo Actions workflows. 
It connects to a Forgejo instance, polls for pending jobs, runs them in isolated environments, and reports results back to the server. 
This enables continuous integration and deployment (CI/CD) pipelines, automated testing, and other automation tasks directly within your Forgejo repositories.

The official runner supports Linux only and can be configured to use various execution modes such as containerized (e.g., Docker) or host-based environments. 
It fetches workflows from the Forgejo server, executes steps defined in YAML files, and handles artifacts, logs, and status updates.

This repository provides a **pre-compiled Windows binary** of the Forgejo Runner, simplifying setup for Windows users.
It is a build of the official [Forgejo Runner source code](https://code.forgejo.org/forgejo/runner) repository, with **no modifications of the source tree**.

### Key Features of the Forgejo Runner
- **Scalability**: Multiple runners can be registered to a single Forgejo instance for distributed execution.
- **Security**: Runs jobs in isolated contexts to prevent interference with the host system.
- **Customization**: Supports custom labels for targeting specific runners (e.g., Windows-specific jobs).
- **Integration**: Seamless compatibility with [Forgejo Actions](https://forgejo.org/docs/latest/user/actions/reference/) syntax, which is similar to [GitHub Actions](https://github.com/features/actions).

## Installation and Usage

1. **Download the Binary**:
    - Visit the [Releases page](https://github.com/Crown0815/Forgejo-runner-windows-builder/releases) to download the latest Windows executable (e.g., `forgejo-runner.exe`).

2. **Configure the Runner**:
    - Follow the [official documentation](https://forgejo.org/docs/latest/admin/actions/runner-installation/) for runner configuration.

3. **Configure as a Service** (Optional, for persistent operation):
    - Use Windows Task Scheduler or a third-party tool to run the daemon as a background service.
4. **Verify Registration**:
    - Return to your Forgejo instance's Actions settings to confirm the runner appears online and is available for jobs.

5. **Running Workflows**:
    - In your repository, create `.forgejo/workflows/your-workflow.yml` files defining jobs that target Windows (e.g., using `runs-on: [self-hosted, windows]` labels).
    - Trigger a workflow (e.g., via push or manual dispatch) and monitor execution in the Actions tab.

For additional configuration, such as enabling Docker support or custom environment variables, consult the [official documentation](https://forgejo.org/docs/latest/admin/actions/runner-installation/).

### Troubleshooting
- Ensure the runner has network access to your Forgejo instance.
- Check logs in the `--logdir` (if specified) for errors.
- If registration fails, verify the token's validity and instance URL.
- Windows-specific issues may involve antivirus software interfering with executables; add exceptions as needed.

## Relevant Resources

Here is a curated list of links to official and helpful resources for Forgejo, the Runner, and related tools:

### Forgejo Core
- [Forgejo Official Website](https://forgejo.org/) – Introduction, downloads, and community information.
- [Forgejo Documentation (Latest)](https://forgejo.org/docs/latest/) – Comprehensive guides for installation, administration, and usage.
- [Forgejo Installation Guide](https://forgejo.org/docs/latest/admin/installation/) – Step-by-step setup for deploying Forgejo.
- [User Guide](https://forgejo.org/docs/latest/user/) – Tutorials for repository management, issues, and more.
- [Administrator Guide](https://forgejo.org/docs/latest/admin/) – Advanced configuration, including security and performance.

### Forgejo Actions and Runner
- [Forgejo Actions Administrator Guide](https://forgejo.org/docs/latest/admin/actions/) – Detailed setup for enabling and managing Actions on your instance.
- [Forgejo Actions User Guide](https://forgejo.org/docs/latest/user/actions/) – How to write and run workflows.
- [Actions Reference](https://forgejo.org/docs/latest/user/actions/reference/) – Syntax and built-in functions for YAML workflows.
- [Quick Start for Actions](https://forgejo.org/docs/latest/user/actions/quick-start/) – Beginner tutorial for creating your first workflow.
- [Official Forgejo Runner Repository](https://code.forgejo.org/forgejo/runner) – Source code, issues, and build instructions for the runner.
- [Runner Installation Guide](https://forgejo.org/docs/latest/admin/actions/runner-installation/) – Official instructions for installing and configuring the runner.

### Community and Support
- [Forgejo Discourse Forum](https://codeberg.org/forgejo/discussions) – Community discussions and support threads.
- [Forgejo Matrix Channel](https://matrix.to/#/#forgejo:matrix.org) – Real-time chat for developers and users.
- [Codeberg Documentation on Forgejo Actions](https://docs.codeberg.org/ci/actions/) – Practical guide from a Forgejo hoster.
- [Gitea Actions Documentation](https://docs.gitea.com/usage/actions/overview) – Compatible reference, as Forgejo Actions are derived from Gitea (note version differences).

## Contributing

Contributions to improve documentation or binaries are welcome via pull requests. 
For issues specific to this Windows build, open a new issue in this repository.