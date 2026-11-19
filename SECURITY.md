# Security and privacy

## How PhotoHub handles your data

- Everything runs on your Mac. The catalog, thumbnails, previews, face embeddings and settings stay in `~/Library/Application Support/PhotoHub`.
- PhotoHub uploads nothing. The only network traffic is what macOS already does for you: iCloud Drive downloads a file when PhotoHub reads it, and the Photos library syncs with iCloud Photos. The map tiles come from Apple Maps.
- The Photos database is read from a temporary copy and never changed. Changes to the Photos library happen only through PhotoKit, after a confirmation (sending to Photos, deleting into "Recently Deleted").
- The optional in-app agent runs the Claude Code CLI under your own account. It receives the text you type and the names, dates and folders of the selected shots, and acts only through the `photohub` command. If you do not use the agent, nothing is sent.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use [GitHub private vulnerability reporting](../../security/advisories/new) for this repository, with the steps to reproduce and the macOS version. You will get an answer within a week. Do not include your own photos or catalog in the report.

Supported version: the latest commit on `main`.
