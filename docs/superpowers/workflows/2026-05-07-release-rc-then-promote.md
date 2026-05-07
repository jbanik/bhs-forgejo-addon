# Release-Workflow: RC-then-promote

**Datum:** 2026-05-07
**Status:** etabliertes Muster (erstmals genutzt für v0.4.0)
**Anlass:** Feature-Releases ohne lokalen End-to-End-Test, Test direkt auf realer HAOS-Instanz

## Wann welches Muster

| Pattern | Wann |
|---|---|
| **Direkt-Release** (`vX.Y.Z` direkt) | Bug-Fixes, Doku-Änderungen, Release-Kosmetik — alles wo Smoke-Test reicht |
| **RC-then-promote** (`vX.Y.Z-rc1` → testen → `vX.Y.Z`) | Neue Features, Breaking Changes, alles was nur auf echter HAOS sinnvoll testbar ist (SSH, Snapshot/Restore, Pangolin-Routes) |

## Mechanik (warum das funktioniert)

- HA-Add-on-Store liest `version:` aus `forgejo/config.yaml` auf `main` → das bestimmt was als Update angezeigt wird
- GHCR-Image-Tag muss exakt zu dieser `version:` passen — sonst zieht HA ein Image, das nicht existiert
- `.github/workflows/build.yml` triggert auf **alle** Tags `v*`, also auch `v0.4.0-rc1`, `v0.4.0-beta1`, `v0.5.0-pre.3`
- `home-assistant/builder` liest `version:` aus `config.yaml` und tagt das Image entsprechend → Tag-Push, Workflow, GHCR sind synchronisiert

Konsequenz: jeder Tag-Push erzeugt sofort ein installierbares Image, sofern `config.yaml` auf `main` denselben Versionsstring trägt.

## RC-then-promote: Schritt-für-Schritt

Ausgangslage: Feature ist auf `feature/<name>` fertig, Smoke grün, lokal verifiziert was lokal verifizierbar ist. `forgejo/config.yaml` hat `version: "X.Y.Z"`.

### 1. RC vorbereiten (auf Feature-Branch)

```bash
# Edit forgejo/config.yaml: version: "X.Y.Z" → "X.Y.Z-rc1"
# Edit forgejo/CHANGELOG.md: ## X.Y.Z - <date>  →  ## X.Y.Z-rc1 - <date>

git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik add forgejo/config.yaml forgejo/CHANGELOG.md
git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik commit -m "release: vX.Y.Z-rc1 (pre-release for HA test)"
git push origin feature/<name>
```

### 2. Merge nach main + Tag

```bash
git checkout main
git pull --ff-only origin main
git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik merge --no-ff feature/<name> -m "Merge feature/<name>: vX.Y.Z-rc1 (<short summary>)"
git push origin main

git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik tag -a vX.Y.Z-rc1 -m "Forgejo add-on vX.Y.Z-rc1 (<short summary> — pre-release)"
git push origin vX.Y.Z-rc1
```

→ CI baut amd64/aarch64/armv7 (~5–10 min) → GHCR hat Images → HA zeigt Update.

### 3. Auf realer HAOS testen

1. Add-on in HA aktualisieren auf `X.Y.Z-rc1`
2. Network-Sektion prüfen (bei Port-Default-Änderungen!)
3. Feature-spezifischer Test (SSH-Push, Backup-Restore, was auch immer)
4. Logs sichten: `docker logs addon_<slug>` oder im HA-UI

### 4a. Promote zu stable (Test grün)

Direkt auf `main` (kein Feature-Branch nötig — die Änderung ist nur Versions-String):

```bash
# Edit forgejo/config.yaml: "X.Y.Z-rc1" → "X.Y.Z"
# Edit forgejo/CHANGELOG.md: ## X.Y.Z-rc1 - <date>  →  ## X.Y.Z - <date>

git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik add forgejo/config.yaml forgejo/CHANGELOG.md
git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik commit -m "release: vX.Y.Z (promote rc1)"
git push origin main

git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik tag -a vX.Y.Z -m "Forgejo add-on vX.Y.Z (<short summary>)"
git push origin vX.Y.Z
```

→ CI baut die finalen Images → HA zeigt Update von rc1 auf stable.

### 4b. Fix nötig (Test rot)

Auf `feature/<name>` zurück, fixen, neuer RC-Tag:

```bash
git checkout feature/<name>
# fixes...
git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik commit -m "fix: <was>"

# Bump rc1 → rc2 in config.yaml + CHANGELOG
git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik commit -m "release: vX.Y.Z-rc2 (<reason for rc2>)"
git push origin feature/<name>

# Merge nach main + tag wie in Schritt 2, aber mit rc2
```

## Direkt-Release: Schritt-für-Schritt

Für simple Sachen ohne RC-Dance.

```bash
git checkout main
git pull --ff-only origin main
git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik merge --no-ff feature/<name> -m "Merge feature/<name>: vX.Y.Z"

# Falls noch nicht versioniert: bump auf main
# Edit forgejo/config.yaml + CHANGELOG entsprechend
# git commit -m "release: vX.Y.Z"

git push origin main
git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik tag -a vX.Y.Z -m "Forgejo add-on vX.Y.Z"
git push origin vX.Y.Z
```

## Stolperfallen

- **Niemals `git push --force` auf `main` oder Tags**, die schon irgendwo deployed wurden — HA zieht den Image-Hash anhand des Versions-Tags, neu-getaggte Images mit gleicher Versions-Nummer können kaputten Cache-State erzeugen
- **Versions-String IMMER mit `version:` in `config.yaml` und Tag-Name in Sync halten**. `version: "0.4.0"` + Tag `v0.4.0`. Inkonsistenz → HA findet kein Image → Update bricht
- **Bei Breaking Port-Defaults**: HA Network-Sektion-Default ändert sich nur für User die nie manuell eingegriffen haben. Manuelle Werte werden respektiert. Trotzdem in CHANGELOG `### ⚠️ Breaking` flaggen und in DOCS Migration-Section dokumentieren
- **Lokale Identity inline halten** (`git -c user.email=... -c user.name=...`), nie `git config --global` schreiben
- **Annotated Tags (`-a -m "..."`)**, keine Lightweight Tags — GitHub Releases funktionieren nur mit annotierten Tags richtig

## Versions-Suffix-Konventionen

| Suffix | Wann |
|---|---|
| `-rc<N>` | Release Candidate, "wird so released wenn nichts bricht" |
| `-beta<N>` | feature-complete aber nicht final getestet, breitere Vorab-Verteilung |
| `-pre.<N>` | Auch valid; `-rc<N>` ist hier Standard |
| `0.X.99` (informell) | Vermeiden — semver-correct ist `-rc`/`-beta` |

`v*` matcht alle vier — die Wahl ist rein semantisch.
