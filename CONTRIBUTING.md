# Contributing

Thanks for your interest in PhotoHub.

- **Bugs and ideas:** open an issue. For a bug, say which macOS version, how the archive is stored (iCloud Drive, external disk) and what you expected. Never attach your own photos or your catalog; reproduce with the demo library (`scripts/demo.sh`) if you can.
- **Code:** open a pull request against `main`. Keep it focused on one change. Build with `scripts/build_app.sh` and check the change in the demo library.
- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/): `fix: …`, `feat: …`, `docs: …`, `chore: …`, `refactor: …`, `test: …`, lowercase and imperative after the colon.
- **Style:** no explanatory comments or docstrings in code; the reasoning goes into the commit message or the pull request. Everything in the repository is in English.
- **Privacy:** PhotoHub must keep working fully offline on the user's Mac. Do not add network calls, telemetry or uploads.
- **Safety:** nothing may delete or move user files without an explicit confirmation; deleted items go to the Trash or to "Recently Deleted".

How the parts fit together, the data files and the self-snapshot mode used for UI checks are described in [docs/development.md](docs/development.md).

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE) and that you follow the [Code of Conduct](CODE_OF_CONDUCT.md).
