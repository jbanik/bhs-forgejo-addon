# Forgejo Home Assistant Add-on — Design

**Datum:** 2026-05-05
**Status:** Spec, Implementierungsplan folgt
**Autor:** jb / Claude (Brainstorming-Session)

## Ziel

Ein installierbares Home Assistant Add-on bereitstellen, das eine vollständige Forgejo-Instanz inklusive PostgreSQL-Datenbank und automatischen DB-Backups in einem einzigen Container bündelt. Zugriff erfolgt über einen konfigurierbaren HTTP-Port, der von einem extern laufenden Pangolin-Reverse-Proxy nach außen veröffentlicht wird.

## Nicht-Ziele

- Eingebauter SSH-Server für Git-Push (HTTPS-Push reicht).
- HA-Sidebar-Integration via Ingress.
- Externe DBs (MariaDB/MySQL/SQLite/Postgres-Cluster).
- E-Mail/SMTP-Konfiguration als HA-Option (kann bei Bedarf nachgezogen werden).
- Automatische Admin-User-Provisionierung.
- Forgejo-MCP-Server (separates Projekt).

## Zielumgebung

- **Home Assistant Installation:** HAOS (Add-on-fähig).
- **Hardware:** primär `amd64`. Add-on baut auch für `aarch64` und `armv7`, getestet wird auf `amd64`.
- **Externer Reverse Proxy:** Pangolin (HTTPS-Termination, Domain-Routing). Add-on selbst macht kein TLS.

## Architektur

### Container-Aufbau

Single-Container Add-on auf Basis von `ghcr.io/hassio-addons/base` (Alpine + s6-overlay + bashio). s6-overlay verwaltet drei langlebige Services und drei einmalige Init-Skripte.

**Komponentenversionen (initial gepinnt):**

- Forgejo: `12.x` (aktueller stabiler Release zur Implementierungszeit, exakte Patch-Version im Dockerfile)
- PostgreSQL: `16` (aus Alpine-Repo, paketiert als `postgresql16`)
- Base-Image: `ghcr.io/hassio-addons/base` aktuelle Stable-Version

```
┌─────────────────────────────────────────────────────────┐
│ Container (s6-overlay als Init)                         │
│                                                         │
│  ┌──────────────┐    ┌──────────────┐   ┌────────────┐  │
│  │  PostgreSQL  │◄───│   Forgejo    │   │   crond    │  │
│  │  127.0.0.1   │    │   0.0.0.0    │   │  pg_dump   │  │
│  │  :5432       │    │   :3000      │   │  konfig.   │  │
│  └──────┬───────┘    └──────┬───────┘   └─────┬──────┘  │
│         │                   │                 │         │
└─────────┼───────────────────┼─────────────────┼─────────┘
          │                   │                 │
   /data/postgres/     /data/forgejo/    /data/backups/
        (DB)            (repos, ini)      (sql.gz Dumps)
```

### Sicherheitsgrenzen

- PostgreSQL bindet ausschließlich an `127.0.0.1` und ist von außen nicht erreichbar.
- Forgejo bindet auf `0.0.0.0:3000` im Container, wird per Add-on-Option auf einen Host-Port gemappt.
- DB-Credentials werden beim ersten Start zufällig generiert und in `/data/.db_password` (Mode 0600) abgelegt — niemals in HA-Optionen exponiert.
- `disable_registration: true` als Default, damit nicht versehentlich öffentlich offene Registrierung läuft.

## Repository-Struktur

```
bhs-forgejo-addon/
├── README.md
├── repository.yaml
└── forgejo/
    ├── config.yaml
    ├── Dockerfile
    ├── README.md
    ├── DOCS.md
    ├── icon.png
    ├── logo.png
    ├── translations/
    │   ├── en.yaml
    │   └── de.yaml
    └── rootfs/
        ├── etc/
        │   ├── cont-init.d/
        │   │   ├── 10-postgres-init.sh
        │   │   ├── 20-forgejo-config.sh
        │   │   └── 30-cron-setup.sh
        │   └── services.d/
        │       ├── postgres/run
        │       ├── forgejo/run
        │       └── crond/run
        └── usr/local/bin/
            └── forgejo-backup.sh
```

## Add-on-Optionen

Konfigurierbar in der HA-Add-on-UI; Default-Werte und Schema-Validierung in `forgejo/config.yaml`.

| Option | Default | Schema | Zweck |
|---|---|---|---|
| `http_port` | `3000` | `port` | Host-Port, auf den Forgejos Port 3000 gemappt wird. |
| `root_url` | `https://git.banik-haustechnik-schwabach.de/` | `url` | Externe URL (typisch die Pangolin-URL). Wird als `[server] ROOT_URL` und `[server] DOMAIN` nach `app.ini` geschrieben. |
| `site_name` | `Forgejo` | `str` | Anzeigename in der Forgejo-UI. |
| `disable_registration` | `true` | `bool` | Self-Signup blockieren. |
| `require_signin_view` | `false` | `bool` | Anonymes Browsen verhindern. |
| `log_level` | `Info` | `list(...)` | Forgejo-Log-Level. |
| `backup_cron` | `0 3 * * *` | `match(...)` | Cron-Expression für DB-Dump. |
| `backup_retention_days` | `7` | `int(1,365)` | Aufbewahrungsdauer für Dumps. |

Was bewusst **nicht** als Option exponiert wird: DB-Typ/Host/User/Passwort, SSH-Server, alle Forgejo-Settings die im Web-UI selbst änderbar sind.

## Konfigurations-Lifecycle

`app.ini` wird bei **jedem Start** aus den HA-Optionen frisch generiert. Das macht die HA-UI zur Source-of-Truth und vermeidet Drift; manuelle Änderungen an `app.ini` werden überschrieben — das ist Absicht.

Erstellt der User Forgejo-Tokens, OAuth-Apps oder ähnliches über die Web-UI: das landet in der Datenbank, nicht in `app.ini`, und bleibt erhalten.

## Init-Reihenfolge (s6 cont-init.d)

1. **`10-postgres-init.sh`** — wenn `/data/postgres/` leer:
   - `initdb` mit lokalisierungsfreien Defaults
   - Random-Passwort für DB-User `forgejo` generieren, in `/data/.db_password` ablegen
   - Postgres temporär starten, `CREATE DATABASE forgejo; CREATE USER forgejo WITH PASSWORD ...; GRANT ALL ...;`, sauber stoppen
   - Andernfalls: skip
2. **`20-forgejo-config.sh`** — `bashio::config` lesen, `app.ini` nach `/data/forgejo/conf/app.ini` schreiben, DB-Credentials aus `/data/.db_password` einsetzen
3. **`30-cron-setup.sh`** — `crontab` aus `backup_cron` generieren, der `forgejo-backup.sh` aufruft

Danach starten die `services.d/`-Services in der Reihenfolge, in der s6 sie hochfährt (Postgres muss vor Forgejo bereit sein — wird in `services.d/forgejo/run` per Wait-Loop auf `127.0.0.1:5432` sichergestellt).

## Backup-Strategie

### Mechanik

`/data/` wird automatisch von HA-Snapshots erfasst. Die rohen Postgres-Dateien sind beim Snapshot eines laufenden DBMS *nicht garantiert konsistent*. Deshalb läuft per Cron `pg_dump` und schreibt einen konsistenten SQL-Dump nach `/data/backups/`.

### Backup-Skript (`/usr/local/bin/forgejo-backup.sh`)

1. `pg_dump -U forgejo forgejo | gzip > /data/backups/forgejo-$(date +%F_%H-%M).sql.gz`
2. `find /data/backups -name 'forgejo-*.sql.gz' -mtime +$RETENTION -delete`
3. Logging nach stdout (HA-Add-on-Log)

### Restore

- **Standardfall:** HA-Snapshot zurückspielen. `/data/` ist wieder da, Add-on startet, Postgres-Dateien sind in 95% der Fälle konsistent.
- **Notfall:** Wenn DB-Dateien nach Restore inkonsistent sind, Anleitung in `DOCS.md`:
  1. Add-on stoppen
  2. `/data/postgres/` löschen → Init-Script erstellt frische DB
  3. `gunzip < /data/backups/forgejo-LATEST.sql.gz | psql -U forgejo forgejo`

## Update-Strategie

- Forgejo-Version im `Dockerfile` als `ARG FORGEJO_VERSION=...` fest verdrahtet (kein `latest`).
- Add-on-Version in `config.yaml` folgt SemVer:
  - **Patch-Bump** bei Forgejo-Patch-Releases
  - **Minor-Bump** bei neuen Add-on-Features
  - **Major-Bump** bei Breaking Changes (z.B. Postgres-Major-Upgrade)
- HA prüft das Repo automatisch, zeigt Update-Banner.
- **Postgres-Major-Upgrade** (z.B. 16 → 17) erfordert manuellen `pg_dumpall` + frische Init und wird im Release-Banner explizit gewarnt. Dedizierte Anleitung in `DOCS.md`.

## Erst-Inbetriebnahme (User-Sicht)

1. Add-on-Repo in HA hinzufügen: *Settings → Add-ons → Add-on Store → ⋮ → Repositories*
2. "Forgejo" Add-on installieren
3. Mindestens `root_url` auf die Pangolin-URL setzen (z.B. `https://git.beispiel.de/`)
4. Add-on starten, Logs zeigen "Forgejo running on 0.0.0.0:3000"
5. Im Browser auf `http://homeassistant.local:<http_port>` → Forgejo Install-Screen erscheint → Admin-User anlegen
6. Pangolin-Route einrichten: `git.beispiel.de` → `<homeassistant-ip>:<http_port>`

## User-Aktionen außerhalb des Codes

Was du selbst tun musst, bevor/während/nach der Implementierung:

| Wann | Aktion |
|---|---|
| Vor Veröffentlichung | Leeres öffentliches Repo `bhs-forgejo-addon` unter `https://github.com/jbanik/bhs-forgejo-addon` anlegen |
| Bei Test-Installation | In HA das Repo per URL hinzufügen: `https://github.com/jbanik/bhs-forgejo-addon` |
| Bei Test-Installation | Pangolin-Route konfigurieren: `git.banik-haustechnik-schwabach.de` → `<homeassistant-ip>:<http_port>` |
| Nach erstem Start | Admin-User über die Forgejo Install-UI anlegen |
| Optional | Repo später in dein eigenes Forgejo spiegeln und HA-Repo-URL umstellen |

Brand-Assets werden aus dem offiziellen Forgejo-Brand-Repository bezogen: https://codeberg.org/forgejo/meta/src/branch/readme/branding (passend skaliert auf `icon.png` 256×256 und `logo.png` 250×100).

## Offene Punkte (bewusst nicht entschieden)

- **SMTP/E-Mail-Notifications:** wird kommen, wenn Bedarf entsteht. Erweiterung: ein optionaler Block in `config.yaml`-Schema.
- **SSH-Push:** kann später als optionaler zweiter Service mit konfigurierbarem `ssh_port` ergänzt werden.
- **HA-Ingress:** explizit nicht gewollt.

## Akzeptanzkriterien

- Add-on installiert sich aus dem Repo in HAOS amd64 ohne manuelle Schritte.
- Nach Start ist Forgejo unter `http://homeassistant.local:<http_port>` erreichbar.
- Install-Screen läuft durch, Admin-User kann angelegt werden, ein Test-Repo kann angelegt und per HTTPS gepusht/gepullt werden.
- DB-Dump erscheint nach erstem Cron-Trigger in `/data/backups/`.
- Alte Dumps werden gemäß `backup_retention_days` gelöscht.
- HA-Snapshot enthält `/data/`-Inhalt; Restore in eine frische HAOS-VM stellt Forgejo wieder her.
- Healthcheck `/api/healthz` liefert 200; HA zeigt grünen Status.
