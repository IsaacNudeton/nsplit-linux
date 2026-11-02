# Validation and release scope

[Overview](../README.md) · [Usage](USAGE.md) · [Security](../SECURITY.md)

## Reviewed baseline

The scoped correction/acceptance work completed on **0.1.0-12**, commit
`b2cdb21446c3305c69061fcbff1d1ca3b522cfcf`, tree
`35731ba6a7d5e47f546153092a55c0d8b9b5beaa`, in the project's earlier
development repository. That commit is **not part of this repository**, which
begins as a single-commit snapshot of the later 0.1.0-13 source; the identifiers
are provenance references, not something you can check out here. The development
repository's issues and pull request, with their detailed reviews, remain private;
this page summarizes what they established. Acceptance of that candidate is
separate from publishing a release or deploying to a real workstation.

The test environment was a disposable CachyOS guest using the documented
systemd/Plasma-login-manager integration. Documentation-only changes do not
extend the tested runtime scope.

**This snapshot is 0.1.0-13, which adds the MIT license and its packaging
only.** Building both packages and comparing them showed the 25 installed program
files are byte-identical, in content and mode, to the reviewed 0.1.0-12 package;
the only added file is `/usr/share/licenses/nsplit/LICENSE`, and the only
metadata changes are the revision, build date, size and license. That comparison
is of built files. The guest tests ran on the 0.1.0-12 baseline: neither the
-13 package nor this repository's commit was itself installed or run in the guest.

## What the evidence supports

| Area | Accepted observations |
| --- | --- |
| Package binding | Source and 25 installed payload files matched the reviewed candidate, including installation transforms and modes. |
| Startup and access | Upgrade, migration, restart, fresh-start, crash-recovery and sampled boot observations; intended owner access and denial of recorded other-user/GID-0 paths. |
| Privileged operations | Actual owner sudo/helper paths, refusal/environment cases, and distinct unavailable/failed guard observations. |
| DNS repair | Actual guest services/files/helper with declared Tailscale/private-resolver stand-ins: drift repair, unchanged repeat, ownership/path refusal, rollback and catchable-signal recovery. |
| Real DNS | Two authenticated runs on one profile/tailnet: known public and node-own private answers, separate IPv4 port-53 destination counters, positive login and repeat verification without another link. |
| Held client | Corrected same-connection observation: successful no-restart control, then client-originated EOF and failed exchange after a managed restart, with no reconnect or client kill. |

The final held-client observer was reviewed against raw events and independent
local predicate controls. The original journal-substring detector could match
its own command text and is **not** valid evidence for its old closure claims.
Original failed runs remain part of the historical record, not erased by later
passing runs.

## What is not claimed

- A fresh `nsplit add` on the final -12 guest package, a graphical desktop run on
  that package, or an installation on the real workstation was not demonstrated
  by the final acceptance program. Earlier-version and controlled tests retain
  their own scope; a fresh-directory start is not a substitute for every add step.
- Real DNS covered one profile, one tailnet and IPv4, using only the node's own
  private name. Peer-name answers, an IPv6-only tailnet, a real suffix migration,
  sign-out/re-authentication and reboot of the authenticated node were not shown.
- The corrected held-client observer covers managed restart. The older `kill -9`
  held-client closure assertion remains unestablished; separate crash-recovery
  startup/access evidence is not the same assertion.
- Sampling is not continuous proof. The DNS file sampler did not validate every
  byte of every read, and the boot wait marker did not prove the full intended
  observation window. Historical UID/DNS one-offs remain unexplained.
- DNS counter results cover named IPv4 UDP/TCP port-53 destination groups during
  recorded trial windows, not every possible egress path or query payload.
  The optional public-server control could pass on timeout. Acceptance used the
  actual positive product output and exit statuses, not an ambiguous `ready`
  substring that also matches `NOT ready`.

These are disclosed boundaries, not a claim that every excluded scenario fails
or a demand to repeat the completed acceptance program for documentation work.

## Evidence retention

Raw logs, scripts, private inventories and VM assets are retained outside the
product repository. The reviewed package SHA256 is:

```text
79be6e335ed02531801fba031e56ddcd37877f280ae8b02ee4e9c620511d6c28
```

This identifies a specific reviewed package; it does not promise that a rebuild
will be byte-identical. Detailed archive bindings and superseded claims are in
the maintainer's private records, not in this repository. Preserve one verified copy of each cited evidence bundle,
including failed controls. Do not edit a hash-bound report to update its status;
record a dated correction or index entry instead.
