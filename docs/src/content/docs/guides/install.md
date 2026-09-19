---
title: Install
description: Install the nimlet release binary on macOS, Linux, or Windows through WSL.
---

You can install nimlet with a one-line script that downloads the latest release
tarball (binary plus bundled OpenSSL and PCRE). No Nim toolchain or source
checkout is required.

After install, continue with the [Quickstart](/guides/quickstart/) to set a
provider key and run your first turn.

## macOS and Linux

```sh
curl -fsSL https://nimlet.niminal.dev/install.sh | sh
```

The installer puts nimlet under `~/.local/lib/nimlet` and a launcher at
`~/.local/bin/nimlet`. Add `~/.local/bin` to your `PATH` if it is not already
there. Open a new shell after install if the script warns that `nimlet` is not
on your path yet.

Pin a release with `NIMLET_VERSION=v0.1.1` before the curl command, or override
the install location with `NIMLET_INSTALL_DIR` / `NIMLET_BIN_DIR`.

## Windows (WSL)

There is no native Windows binary yet. On Windows, install nimlet inside
[WSL](https://learn.microsoft.com/en-us/windows/wsl/) and use the Linux steps
above from your WSL shell (Ubuntu, Debian, or another WSL distro).

WSL presents a Linux environment to the installer, so the same release tarball
and install script work there. Run nimlet from WSL when you work on projects
under your Linux home directory or Windows paths mounted at `/mnt/c/...`.

Use a WSL terminal (Windows Terminal, VS Code's WSL integration, or your distro's
shell), not PowerShell or Command Prompt, for the curl command and for running
`nimlet`.

## Build from source

To build from a source checkout instead, install Nim 2.0 or later and run
`nimble release`, which writes `build/nimlet`.

## Next steps

- [Quickstart](/guides/quickstart/) for provider setup and your first turn
- [Configuration](/guides/configuration/) for `~/.nimlet/config.json` and credentials
