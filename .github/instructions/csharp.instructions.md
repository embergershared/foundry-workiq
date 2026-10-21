---
applyTo: "**/*.cs,**/*.csproj,**/*.sln,**/*.slnx"
---

# C# and .NET instructions

- For new projects use the latest stable LTS .NET SDK and supported C# version;
  preserve existing `global.json`, target frameworks, nullable settings, and
  `.editorconfig`.
- Enable nullable reference types, validate entry points, prefer non-nullable
  models, and pass `CancellationToken` through async I/O boundaries.
- Use built-in dependency injection, options validation, structured logging,
  managed identity, and current Azure SDK clients. Never log secrets or tokens.
- Keep dependencies inward: Presentation → Application → Domain;
  Infrastructure implements inner-layer ports and is wired at composition root.
- Centralize exception handling and return RFC 9457 Problem Details without
  stack traces or sensitive data.
- Test normal, boundary, cancellation, authorization, and failure paths with the
  repository's established tools.
