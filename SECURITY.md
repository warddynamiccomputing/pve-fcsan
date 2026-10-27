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
- Arrays are trusted only by a SHA-256 certificate fingerprint that the admin
  confirms when adding the array (trust on first use); any other certificate
  is refused.
- All cluster-wide actions need `Sys.Modify` on `/` and `Datastore.Allocate`
  on `/storage`.

## Supported versions

Only the latest release receives fixes.
