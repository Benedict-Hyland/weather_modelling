# Repository Guidelines

## Project Structure & Module Organization
The repository couples Python packaging metadata with scripts that move weather data. Add application code inside `src/weather_modelling/` (create the tree if absent) so it aligns with the `pyproject.toml` configuration, and keep test-only helpers in `tests/`. Docker build inputs sit in `images/` for the downloader and modeller containers, while host automation lives at the top level (`python-prepare.sh`, `startup_script.sh`). Use `tools.md` as the scratchpad for repeatable operational snippets so command changes stay versioned.

## Build, Test, and Development Commands
- `python -m venv .venv && source .venv/bin/activate`: create an isolated development shell.
- `python -m pip install -U pip setuptools wheel && python -m pip install -e .`: install runtime dependencies listed in `pyproject.toml`; add the missing `[build-system]` stanza before committing if editable installs fail.
- `docker build -t downloader -f images/Dockerfile_downloader .` and `docker build -t modeller -f images/Dockerfile_modeller .`: rebuild container images when dependency stacks change.
- `STORAGE_MODE=local ./python-prepare.sh`: dry-run the ingestion flow without touching S3; override env vars inline when testing.

## Coding Style & Naming Conventions
Follow 4-space indentation, type hints on public APIs, and module or class docstrings that explain intent. Format with `black --line-length 88`, lint with `ruff`, and organise imports using the default `isort` profile. Use snake_case for functions and variables, PascalCase for classes, and prefix private helpers with a leading underscore.

## Testing Guidelines
Use `pytest` for unit and integration coverage. Name files `test_<target>.py`, keep shared fixtures in `tests/conftest.py`, and aim for 80% line coverage on new modules. Record regression tests for any fixed bug and run `pytest` before opening a pull request, pasting a short summary of the results in the description.

## Commit & Pull Request Guidelines
Commit messages should mirror the current history: a concise, imperative subject (e.g., `Add GFS downloader health checks`) and optional wrapped body text. Squash fixups locally. Pull requests must outline the change, call out config or infra updates, link to tracking issues, and include screenshots or logs when touching Docker images or long-running scripts.

## Operations & Secrets
`python-prepare.sh` expects AWS credentials, ntfy topics, and NOMADS access; load them via environment variables or your secret manager. Do not commit live identifiers, tokens, or host paths—redact examples instead. When updating `startup_script.sh`, re-check service names and shutdown triggers to avoid unintended reboots.
