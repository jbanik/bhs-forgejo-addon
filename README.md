# BHS Forgejo Add-on Repository for Home Assistant

[![Version](https://img.shields.io/github/v/release/jbanik/bhs-forgejo-addon?label=version)](https://github.com/jbanik/bhs-forgejo-addon/releases)
[![Lint](https://github.com/jbanik/bhs-forgejo-addon/actions/workflows/lint.yml/badge.svg)](https://github.com/jbanik/bhs-forgejo-addon/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[![Open your Home Assistant instance and show the add add-on repository dialog with a specific repository URL pre-filled.](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fjbanik%2Fbhs-forgejo-addon)

Self-hosted Forgejo Git server as a Home Assistant Add-on, with bundled PostgreSQL and automatic database backups.

## Add-ons in this repository

| Add-on | Description |
|---|---|
| **Forgejo** | A self-hosted Git server (Forgejo) bundled with PostgreSQL 16 and scheduled database backups. Designed to run behind an external reverse proxy (e.g. Pangolin). |

## Installation

1. In Home Assistant, navigate to **Settings -> Add-ons -> Add-on Store**.
2. Click the three-dots menu (top-right) -> **Repositories**.
3. Add the repository URL:

   ```
   https://github.com/jbanik/bhs-forgejo-addon
   ```

4. Refresh the store. The "Forgejo" add-on appears under "BHS Forgejo Add-ons".
5. Install, configure (at minimum the `root_url` option), then start.

See the per-add-on README and DOCS for details.
