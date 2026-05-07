# Changelog

## 0.4.0 - 2026-05-06

### ⚠️ Breaking

- **Default HTTP host port mapping changes from `3000` to `3080`.** This is a HA Network-section default; users who rely on `3000` (e.g. with a reverse proxy route hardcoded to `<haos>:3000`) will lose external connectivity unless they either:
  1. Update their reverse proxy upstream to `<haos>:3080`, or
  2. Manually set the host port back to `3000` in the add-on's **Network** section after updating.
- See [DOCS.md — Migrating from v0.3.x](DOCS.md#migrating-from-v03x) for step-by-step.

### Added

- **Optional SSH push.** New options `enable_ssh` (default `false`) and `ssh_port` (default `3022`). When enabled, Forgejo's built-in SSH server runs alongside HTTP — no separate daemon, no extra container service.
- New container port `3022/tcp` exposed for SSH (only used when `enable_ssh: true`).
- DOCS.md: full SSH setup section including Pangolin TCP-stream forwarding steps.

## 0.3.2 - 2026-05-06

- Add MIT LICENSE file at repo root.
- README: add status badges (version, CI lint, license) and a "My Home Assistant" one-click button to add this repository to a HA instance.
- GitHub repo metadata: description and topics set for discoverability.

## 0.3.1 - 2026-05-06

- Security fix: redact PASSWD, SECRET_KEY, INTERNAL_TOKEN, JWT_SECRET and LFS_JWT_SECRET values in `/config/forgejo/app.ini.generated`. The snapshot is meant for inspection of HA-generated settings; secrets must not leak into the user-visible `/config/` tree (Samba shares, File Editor, off-site snapshots, etc.). Forgejo continues to use the real values from `/data/forgejo/conf/app.ini`, which is not user-visible.

## 0.3.0 - 2026-05-06

- Move database backups to `/config/backups/` so they're visible in HA's File Editor / Samba (under `addon_configs/<slug>/backups/`).
- Add app.ini override mechanism: drop a file at `/config/forgejo/app.ini.override` to add or override any Forgejo setting that the add-on UI doesn't expose. Last-key-wins semantics; safe to use for any non-database, non-secret setting.
- Snapshot of HA-generated config available read-only at `/config/forgejo/app.ini.generated` for inspection.

## 0.2.0 - 2026-05-06

- Remove redundant `http_port` add-on option (Home Assistant's Network UI controls the host-side port; the option was never wired into Forgejo's app.ini).
- Add `webui:` field so the add-on detail page shows an "OPEN WEB UI" button that opens Forgejo directly.
- Documentation: how to add a Forgejo sidebar entry in Home Assistant via `panel_iframe` in `configuration.yaml`.

## 0.1.2 - 2026-05-06

- Fix CI build for armv7: HA builder passes TARGETARCH=arm (not arm/v7), now matched in the Dockerfile case statement.
- Fix CI lint: exclude execlineb-shebanged s6 service files from ShellCheck (they are not shell scripts), quiet SC1003 false positive in app.ini sanitizer, and quote HTTP_PORT in smoke test curl URLs.

## 0.1.1 - 2026-05-06

- Fix CI lint: silence hadolint DL3006 by pinning a default BUILD_FROM.
- Fix CI build: switch GitHub Actions builder args to a YAML folded scalar so all flags reach docker run (the previous block-literal broke the command after the first arg, so --target was never passed and the build failed at config.json lookup).

## 0.1.0 - 2026-05-05

- Initial release.
- Forgejo 12.0.1 + PostgreSQL 16 in a single container.
- Daily database backups via configurable cron expression.
- Persistent data under `/data/`, captured in HA snapshots.
- HTTPS push only (SSH disabled).
- Designed for use behind an external reverse proxy (Pangolin etc.).
