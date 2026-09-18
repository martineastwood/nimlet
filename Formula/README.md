# Homebrew formula

This directory makes the [nimlet](https://github.com/martineastwood/nimlet)
repository usable as a Homebrew tap.

## Install

```sh
brew tap martineastwood/nimlet https://github.com/martineastwood/nimlet
brew install nimlet
```

The formula builds from source. It depends on Homebrew `openssl@3` and `pcre`,
and recommends `ripgrep`. Nimble packages `nimgent`, `nimterm`, and `nimwire`
must be published for `nimble install -d` to succeed.

## After tagging a release

1. Tag the release (`v0.1.0`).
2. Compute the archive checksum:

```sh
curl -fsSL https://github.com/martineastwood/nimlet/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256
```

3. Uncomment and fill `url`, `sha256`, and `version` in `nimlet.rb`.
