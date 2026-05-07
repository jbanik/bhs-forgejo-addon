# Forgejo SSH-Push Support — Design

**Datum:** 2026-05-06
**Status:** Spec, Implementierungsplan folgt
**Autor:** jb / Claude
**Branch:** `feature/ssh-support` → ziel-Release `v0.4.0`

## Ziel

Optionalen SSH-Push für die Forgejo-Add-on-Instanz aktivierbar machen. Forgejo's eingebauter SSH-Server wird verwendet (in-process, kein separater OpenSSH-Daemon). Externer SSH-Zugriff läuft über Pangolin TCP-Stream-Forwarding; Web-UI bleibt wie bisher Pangolin-HTTP-vorgelagert.

## Nicht-Ziele

- Eigener OpenSSH-Daemon im Container (Forgejo's built-in genügt vollständig).
- SSH-Key-Verwaltung im Add-on (Forgejo's Web-UI macht das in `Settings → SSH/GPG Keys`).
- LFS via SSH (Forgejo unterstützt LFS-via-HTTPS; SSH-Push überträgt LFS-Pointer-Files normal).
- Dokumentation für andere Reverse Proxies als Pangolin (kommt nur ein generischer „configure TCP-stream forwarding" Absatz).

## Designentscheidungen

### Implementation: Forgejo's built-in SSH

- Forgejo bringt einen Go-basierten SSH-Server mit, der ausschließlich `git-shell` versteht (kein interaktiver Login möglich).
- Aktivierung über zwei `app.ini`-Settings: `[server] DISABLE_SSH = false` und `[server] START_SSH_SERVER = true`.
- Host-Keys werden beim ersten Start generiert und in `/data/forgejo/ssh/` abgelegt — persistieren über Container-Restarts und HA-Snapshots.
- Public-Keys verwaltet Forgejo selbst, gespeichert in der Postgres-DB (Tabelle `public_key`).

### Externer Zugriff: Pangolin TCP-Stream

- Pangolin bietet Resource Type **„Raw TCP"** für transparentes Stream-Forwarding ohne TLS-Termination.
- User legt einmalig eine zweite Pangolin-Resource an: externer Port (z.B. 22 oder 3022) → HAOS:`<host-ssh-port>`.
- Die externe Port-Wahl bestimmt den Wert von `ssh_port` in den Add-on-Optionen (= was in Clone-URLs steht).

### `SSH_DOMAIN`-Ableitung

`SSH_DOMAIN` ist der Hostname-Teil von `ROOT_URL`, ohne Schema und ohne Port. Wird vom bestehenden DOMAIN-Helper im Init-Script wiederverwendet:

```bash
SSH_DOMAIN=$(echo "$ROOT_URL" | sed -E 's#^https?://##; s#/.*##; s#:.*##')
```

Bei Sonderfällen (anderer externer SSH-Hostname als Web) kann der User das via `app.ini.override` überschreiben — keine separate HA-Option dafür.

## Komponenten

### Neue Add-on-Optionen

| Option | Default | Schema | Zweck |
|---|---|---|---|
| `enable_ssh` | `false` | `bool` | SSH-Server an/aus |
| `ssh_port` | `3022` | `port` | **Werbe-Port** — erscheint in Clone-URLs (`git@host:<ssh_port>/user/repo.git`). Muss dem extern erreichbaren Port entsprechen: Host-Port direkt (LAN) oder Pangolin-Front-Port (externer Zugriff). **NICHT** der Container-interne Port. |

### Port-Architektur (drei unabhängige Ebenen)

| Ebene | Port | Konfiguration | Notizen |
|---|---|---|---|
| Container intern | **fest 3022** | hardcoded in `app.ini` als `SSH_LISTEN_PORT = 3022`, korrespondiert mit `ports.3022/tcp` Eintrag in `config.yaml` | Forgejo lauscht hier; nicht user-konfigurierbar |
| Host-Port-Mapping | default 3022 | HA Network UI | User darf in HA umstellen; betrifft nur LAN-Zugriff direkt zur HAOS |
| Werbe-Port (Clone-URLs) | default 3022 | `ssh_port` Add-on Option → `SSH_PORT` in app.ini | User setzt = externer Front-Port (Host oder Pangolin) |

Beispiel-Konstellationen:
- **LAN-only, alles default:** ssh_port=3022, HA Host-Port=3022 → `git clone ssh://git@<haos>:3022/...`
- **Via Pangolin auf Standard-22:** ssh_port=22, HA Host-Port=3022 (default), Pangolin-Front-Port=22 → `git clone ssh://git@git.banik...:22/...` (oder ohne `:22` da Standard-Port)
- **Via Pangolin auf 3022:** ssh_port=3022 (default), HA Host-Port=3022 (default), Pangolin-Front-Port=3022 → `git clone ssh://git@git.banik...:3022/...`

### Geänderte Optionen / Defaults

- `ports.3000/tcp`: Default-Host-Port-Mapping ändert sich von `3000` auf **`3080`**. Bewusst Breaking — siehe Migration unten.
- Neuer `ports.3022/tcp: 3022` Eintrag.

### Geänderte Skripte

`forgejo/rootfs/etc/cont-init.d/20-forgejo-config.sh` bekommt einen Block, der zwischen SSH-on und SSH-off umschaltet:

```bash
ENABLE_SSH=$(get_option enable_ssh)
SSH_PORT=$(get_option ssh_port)

if [[ "$ENABLE_SSH" == "true" ]]; then
  SSH_BLOCK="DISABLE_SSH = false
START_SSH_SERVER = true
SSH_LISTEN_PORT = 3022
SSH_PORT = $SSH_PORT
SSH_DOMAIN = $DOMAIN"
else
  SSH_BLOCK="DISABLE_SSH = true
START_SSH_SERVER = false"
fi
```

… und ersetzt im Heredoc die aktuellen statischen `DISABLE_SSH`/`START_SSH_SERVER` Zeilen durch `$SSH_BLOCK`.

### Container-Aufbau

Keine neuen s6-Services, kein neues apk-Package. SSH läuft im selben Forgejo-Prozess wie der HTTP-Server. Healthcheck bleibt unverändert auf `/api/healthz`.

### Persistenz

- Host-Keys: `/data/forgejo/ssh/` (von Forgejo automatisch verwaltet).
- Authorized-Keys: in der Postgres-DB (kein File auf Disk, kein extra Mount).
- Beides wird von HA-Snapshots inklusive `/data/` gesichert.

## Datenfluss bei `git push`

Aus dem LAN (direkt zu HAOS):
```
client → ssh://git@<haos-ip>:3022/user/repo.git
       → HAOS:3022 → Container:3022 → Forgejo SSH (built-in) → git-shell
```

Aus dem Internet (via Pangolin):
```
client → ssh://git@git.banik-haustechnik-schwabach.de:<pangolin-front-port>/user/repo.git
       → Pangolin TCP-Stream → HAOS:3022 → Container:3022 → Forgejo SSH → git-shell
```

Forgejo schreibt Clone-URLs als `git@$SSH_DOMAIN:$SSH_PORT/user/repo.git`. Wenn `ssh_port = 3022` und `SSH_DOMAIN = git.banik-haustechnik-schwabach.de`: `git@git.banik-haustechnik-schwabach.de:3022/user/repo.git`.

## Tests

### Smoke-Test-Erweiterungen

`tests/smoke.sh` bekommt:

1. **Test-Options-JSON** wird erweitert um `enable_ssh: true` und `ssh_port: 3022`.
2. **Container-Startup** mit zusätzlichem Port-Mapping `-p 13022:3022`.
3. **Assertions:**
   - `app.ini` enthält `START_SSH_SERVER = true` (wenn enable_ssh=true)
   - `app.ini` enthält `SSH_LISTEN_PORT = 3022` (fix, container-intern)
   - `app.ini` enthält `SSH_PORT = 3022` (Default-Werbe-Port aus Test-options)
   - `app.ini` enthält `SSH_DOMAIN = localhost` (vom Test-root_url `http://localhost:13000/`)
   - TCP-Connect auf `localhost:13022` antwortet mit SSH-Banner (`SSH-2.0-…`)
   - Disable-Path-Test: Override-Datei oder zweite Test-Phase mit `enable_ssh=false`, restart, asserted `DISABLE_SSH = true` und Port-Connect auf 13022 schlägt fehl (innerhalb von 5s timeout)

### Manueller End-to-End-Test (User auf HAOS)

1. Add-on aktualisieren auf v0.4.0
2. Pangolin-Route für TCP-Stream auf Port 3022 anlegen
3. HA-Network-Sektion: SSH-Port 3022 auf 3022 belassen (oder ändern)
4. Add-on Configuration: `enable_ssh = true`, `ssh_port = <pangolin-front-port>`
5. Restart
6. In Forgejo Web-UI: SSH-Public-Key hochladen
7. Lokal: `git clone ssh://git@<pangolin-domain>:<pangolin-front-port>/jbanik/<repo>.git`
8. Commit + Push verifizieren

## Migration / Breaking Change Handling

**HTTP-Host-Port-Default ändert sich von 3000 auf 3080.**

Auswirkungen:
- Bestehende Pangolin-HTTP-Routes auf `<haos>:3000` brechen, sobald HA das neue Default-Mapping anwendet.
- Nutzer, die in HA Network UI bewusst einen Port gesetzt haben, sind nicht betroffen — HA respektiert User-Overrides.
- Frische Installationen oder Default-Mapping-Resets bekommen 3080.

Mitigation:
- CHANGELOG kennzeichnet die Änderung als ⚠️ **BREAKING**.
- DOCS.md neuer Abschnitt „Migrating from v0.3.x" mit Anleitung:
  1. Pangolin-Route umstellen auf `<haos>:3080`, oder
  2. In HA Network UI Host-Port manuell auf 3000 zurücksetzen
- Add-on-Update-Notice (im Release auf GitHub) wiederholt die Warnung.

## Akzeptanzkriterien

- Add-on installiert sich aus dem Repo in HAOS amd64 ohne manuelle Schritte; Default-State `enable_ssh=false` ändert nichts am bisherigen Verhalten außer den Port-Defaults.
- Bei `enable_ssh=true` + Restart: TCP-Port (Host-side, gemäß HA Network UI) antwortet mit SSH-Banner.
- Hochgeladener SSH-Key in Forgejo Web-UI ermöglicht `git clone/push` über SSH.
- Pangolin-TCP-Stream-Resource für Port 3022 erreicht den Container; `git push` von extern funktioniert.
- Smoke-Test grün mit allen neuen SSH-Assertions plus den bisherigen 22+ Assertions.
- HA-Snapshot enthält Host-Keys (`/data/forgejo/ssh/`); Restore stellt sie wieder her, keine „host key changed" Warnungen bei Clients.
- Bei `enable_ssh=false` (Default): SSH-Port reagiert nicht (kein Banner), `app.ini` zeigt `DISABLE_SSH = true`.

## Offene Punkte (bewusst nicht entschieden)

- **Rate Limiting / Fail2Ban:** Forgejo's eingebauter SSH-Server hat keine Brute-Force-Protection auf SSH-Auth-Ebene. Public-Key-only Auth (Forgejo erzwingt das) macht Brute-Force aber praktisch unmöglich. Akzeptabler Trade-off.
- **Custom SSH-Banner:** Forgejo zeigt Standard-Banner. Anpassbar via app.ini.override falls gewünscht.
- **Outbound SSH (z.B. Forgejo pulled von externem Git):** `openssh-client` ist bereits im Dockerfile. Funktioniert weiterhin unabhängig vom enable_ssh Flag.
