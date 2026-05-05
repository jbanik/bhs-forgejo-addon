# Tests

## Integration smoke test

Builds the image and exercises real container behavior.

```bash
make smoke
```

Requires Docker. On Windows, run from WSL or Git Bash.

## Linting

```bash
make lint
```

Requires `hadolint`, `shellcheck`, and `yamllint` to be installed locally.
