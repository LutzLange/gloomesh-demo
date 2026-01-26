# CLAUDE.md - Coding Guidelines

## Project: Cluster Manager

### Code Style

- **Formatter**: Use `black` with default settings
- **Linting**: Use `ruff`
- **Type hints**: Required for function signatures
- **Line length**: 88 (black default)

### Documentation

- Docstrings only where function purpose is non-obvious
- Keep docstrings to 1-2 lines max
- No redundant comments - code should be self-explanatory
- README: Brief setup + usage instructions only

### Error Handling

- All AWS/GCP API calls must be wrapped in try/except
- Return meaningful error messages to frontend
- Never expose raw stack traces in UI
- Log full errors server-side

### Logging

- Use Python `logging` module
- Default: INFO level (operations, errors)
- `--debug` flag enables DEBUG level (API responses, detailed flow)
- Format: `%(asctime)s - %(levelname)s - %(message)s`

### Architecture

- Single `app.py` - no over-engineering
- Config in YAML, loaded once at startup (with reload endpoint if needed)
- State persistence: Update `config.yaml` with saved node counts
- Frontend: Vanilla JS, no frameworks

### API Design

- REST endpoints for actions
- JSON responses with consistent structure:
  ```json
  {"success": true, "data": {...}}
  {"success": false, "error": "message"}
  ```

### Testing Approach

- Manual testing against real clusters
- No unit test framework needed for this tool
- Test each cloud provider independently

### Safety

- Delete operations: Always require confirmation parameter
- Scale operations: Save state before modifying
- Never auto-delete without explicit user action

### Dependencies

Keep minimal:
- flask
- boto3
- google-cloud-container
- pyyaml

### Git

- `.gitignore`: Include `config.yaml` (contains project IDs), `__pycache__/`, `.venv/`
- Provide `config.yaml.example` with placeholder values
