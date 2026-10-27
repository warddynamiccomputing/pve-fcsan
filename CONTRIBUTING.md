# Contributing

Thanks for helping. The most valuable contribution right now is a **report
from a real array**: which array, which code level, and whether provisioning,
growing and deleting a test datastore worked.

## Reporting an array result or a bug

Open an issue with the "Array report / bug" template and include:

- Proxmox VE version (`pveversion`) and pve-fcsan version (`dpkg -l pve-fcsan`)
- Array model and code level, HBA model
- The task log of the failing step (Datacenter → Tasks, or the CLI output);
  the array's own error code (for example `CMMVC…`, `KART…`) is usually in it
- **Remove** WWPNs, serials, IP addresses and host names you don't want public

## Development

```bash
make test        # unit tests; PVE modules are stubbed when not installed
make deb         # Debian package (needs debhelper)
```

- The tests run anywhere with Perl 5.36+. On a Proxmox node they compile
  against the real PVE libraries.
- Array drivers live in `src/PVE/SAN/Array/`. Each extends
  `PVE::SAN::Array::Base` and implements the primitives listed at the top of
  `Base.pm`. Register a new driver in `$DRIVERS` in `src/PVE/SAN/Array.pm`, add
  its type to `www/pvesan.js`, and add a test with a fake array (see
  `t/lib/FakeArray.pm` and the existing `t/6*.t`).
- Please check REST calls against the vendor's own SDK or reference and cite
  it in the driver's header comment.
- Keep `debian/changelog` and `CHANGELOG.md` in step.

## Pull requests

One topic per pull request, tests included, `make test` green.
