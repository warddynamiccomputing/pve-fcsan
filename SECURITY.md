# Security policy

pve-fcsan runs as root on Proxmox VE nodes and stores storage-array
credentials, so security reports are welcome.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private vulnerability
reporting instead: the **Security** tab of this repository → **Report a
vulnerability**. Include the version, what an attacker could do, and steps to
reproduce.

## How credentials are handled

- Array passwords and API tokens are stored in `/etc/pve/priv/pvesan/`, which
  only root can read and which is replicated by the Proxmox cluster
  filesystem.
- Arrays and FC switches are trusted only by a SHA-256 certificate
  fingerprint that the admin confirms when adding them (trust on first use);
  any other certificate is refused, including one signed by a trusted CA
  (fixed in 1.7.1: before, a CA-signed certificate was accepted too).
  Connections are HTTPS only and do not follow redirects.
- The GUI HTML-encodes everything arrays, switches and devices report
  (volume names, SCSI inquiry strings, fabric symbolic names).
- Guest configs brought up from a DR replica are checked; hookscripts are not
  taken over.
- All cluster-wide actions need `Sys.Modify` on `/` and `Datastore.Allocate`
  on `/storage`.

## Verifying a download

Each release has a `SHA256SUMS` file and a build-provenance attestation
signed by GitHub Actions, which ties the `.deb` to the commit and workflow
run that built it:

```bash
sha256sum -c SHA256SUMS --ignore-missing
gh attestation verify pve-fcsan_X.Y.Z_all.deb --repo warddynamiccomputing/pve-fcsan
```

The apt repository is signed; apt checks every package against it.

## How releases are built

- CI runs with a read-only token. Only the job that publishes a tagged
  release can write to it, and it runs no code from pull requests.
- Every GitHub Action is pinned to a full commit SHA; Dependabot proposes
  updates, and `make lint` fails on an unpinned one.
- `make lint` also runs shellcheck and perlcritic.

## Supported versions

Only the latest release receives fixes.
