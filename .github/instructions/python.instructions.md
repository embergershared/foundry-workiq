---
applyTo: "**/*.py,pyproject.toml,requirements*.txt"
---

# Python instructions

- Use the latest stable Python supported by dependencies; preserve
  `requires-python`, lock files, formatter, linter, type checker, and test runner.
- Type all public APIs and parameters/returns. Use precise models for structured
  input and validate every external trust boundary.
- Prefer `pathlib`, context managers, specific exceptions, and `async`/`await`
  for I/O concurrency. Avoid mutable defaults, bare `except`, swallowed errors,
  wildcard imports, and blocking calls in async code.
- Use managed identity and current Azure SDK clients. Never hardcode or log
  credentials, tokens, connection strings, or secret values.
- Keep modules focused and test normal, boundary, async cancellation, security,
  and failure behavior with existing project tools.
