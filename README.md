# Koi

A terminal workspace for macOS.

Your shells keep running when you close the app. Come back to the same work,
on your Mac or a remote machine.

- **Room to work.** Arrange shells in split panes, tabs and groups.
- **Local and remote.** Connect over SSH, with encrypted UDP for terminal traffic
  and an SSH relay as a fallback.
- **Find your place.** Jump to a session from the command palette, or save a
  project layout to open fresh shells in the right directories.

## Build

Koi is under active development. Building requires an **Apple silicon Mac
running macOS 26+**, Xcode with Swift 6.2+, Zig 0.17.0, Python 3 and Git.

```sh
git clone https://github.com/arocomputer/koi.git
cd koi
scripts/bundle.sh
open build/Koi.app
```

The first build downloads dependencies. The app is built in `build/Koi.app`;
it is not installed into Applications.

For development and testing, use the separate Koid app. See
[Contributing](CONTRIBUTING.md) for setup and validation.

---

[Settings & shortcuts](docs/configuration.md) · [Command line](docs/cli.md)

Licensed under [GPL-3.0-only](LICENSE).
[Third-party notices](THIRD_PARTY_NOTICES.md).
