# Contributing

Start with [README.md](README.md), [usage](docs/USAGE.md) and the
[security boundaries](SECURITY.md). This is a small experimental toolkit, not a
general-purpose desktop sandbox. The project is under the [MIT License](LICENSE);
contributions are accepted under the same terms.

## Keep changes focused

Explain the behavior being changed and the evidence for it. Separate a product
defect from a test-harness fault, an unavailable observation and a policy-denied
connection. Do not redesign login or broaden privileges to make a test green.
Keep tested commit identities and the earlier failing observation available.

`make check` runs shell syntax checks. It is **not** the acceptance suite.
Integration checks require an isolated environment; do not test by modifying an
unapproved real workstation, tailnet policy, existing node identity or login
configuration. A source-only/doc change does not call for another browser sign-in.

Keep harnesses, raw outputs and machine inventories outside the product tree.
Record a concise sanitized result in the PR: exact source/package, commands or
harness revision, expected/observed behavior and which boundaries were real
versus controlled. Preserve failed runs alongside corrected reruns. Never label
a stand-in resolver as real-tailnet evidence.

## Keep the repository small

Commit source, templates, packaging and maintained user documentation. Do not
commit build trees, generated packages, extracted review bundles, VM images,
credentials, agent transcripts or scratch notes. `.gitignore` helps prevent
accidents; it neither removes already-tracked files nor replaces a privacy scan.
Retain one verified private copy of cited evidence before deleting duplicates.

Documentation should describe the commands and constraints actually present in
the corresponding source. Preserve the distinction between installation,
enrollment, authentication, review acceptance, publication and live deployment.
Review [SECURITY.md](SECURITY.md) before posting a security-sensitive issue.
