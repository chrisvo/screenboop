# Contributing

screenboop is an independent native macOS application. Contributions are covered by the repository's MIT license.

## Develop

Use macOS 14+ and an Apple toolchain providing Swift 6.0 or later:

```sh
make test
make run
```

`make test` runs deterministic image-geometry, redaction-privacy, editing-state, and overlap-stitching tests. It does not ask for Screen Recording or Accessibility permission. `make build` creates the application without opening it; signing defaults to ad-hoc unless `CODE_SIGN_IDENTITY` selects a certificate.

See [Architecture](docs/architecture.md) for ownership and the top-left physical-pixel coordinate invariant. Follow the existing Swift style; the project has no third-party package or formatter requirement.

## Before a pull request

- Review the complete change and its validation evidence. State which checks actually ran and which OS-dependent behavior remains unverified.
- Add focused regression coverage for consumer-visible behavior and uncertain boundaries, not source-text or wiring assertions.
- For UI changes, include a screenshot of the running application. For capture changes, exercise a controlled test window rather than recording private desktop content.
- Preserve permission checks, cancellation, process cleanup, image-size bounds, and redaction precedence. Never add permission bypasses.
- Keep images and recognized text local. Networked features require an explicit design discussion; do not introduce telemetry or background uploads.

Do not commit builds, personal captures, credentials, investigation tool checkouts, or proprietary application binaries, decoded resources, and artwork. Public screenshots should show screenboop with original example content.

Use concise Conventional Commit subjects and describe observable outcomes, risks, and verification in pull requests. Native picker and scrolling checks depend on macOS privacy grants and are not established by the permission-free test suite alone.
