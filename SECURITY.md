# Security reports

Please use [GitHub's private vulnerability reporting](https://github.com/hybes/liltfold/security/advisories/new)
for vulnerabilities. Do not publish exploit details, private media, credentials
or personal paths in a public issue.

Include the commit or app version, macOS version, the affected operation, expected
and actual behaviour, and minimal reproduction steps. If a sample is needed,
prefer a synthetic file and explain how it was made.

Security fixes target the current default branch. Older builds are not maintained
separately. Codec dependencies are part of the attack surface; identify the
bundled FFmpeg/WebP versions when reporting a decoder or encoder problem.

Liltfold processes media locally. Originals must never be overwritten by exports,
duplicate detection must not mutate files, and cancelled/failed outputs must not
appear complete. Please report violations of these guarantees privately.
