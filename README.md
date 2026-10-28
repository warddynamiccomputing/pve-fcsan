# pve-fcsan (`pvesan`)

**vCenter-style Fibre Channel SAN management for Proxmox VE 8 and 9.**

`pvesan` gives a Proxmox VE cluster the SAN workflow VMware admins know from
vCenter: see your HBAs, LUNs and paths, rescan, set multipath aliases and path
policies, and create, grow, rename, mount/unmount, reclaim and delete shared
datastores, cluster-wide, from the GUI, a CLI or the REST API.

With an array driver it goes one step further, like the Pure Storage or
INFINIDAT vSphere plugins: **one form creates the volume on the array, maps it
to the cluster, rescans every node and builds the datastore.**

> **Status: beta.** Everything below is implemented and covered by 322
> automated tests, and the plugin runs on a 6-node Proxmox VE 9.2 lab with
> QLogic and Emulex HBAs. **No array driver has yet been exercised against a
> real array.** Try each new array type with a small test datastore first, and
> please report what you find (see [Contributing](CONTRIBUTING.md)).

## Features

| Area | What you can do |
| --- | --- |
| Adapters | FC (and iSCSI) HBAs with WWPN, link state, speed, fabric, targets |
| Rescan | One node or the whole cluster; optional LIP; picks up new LUNs and grown LUNs |
| Devices | LUNs with paths, usage, cluster-wide alias and path policy (ALUA, round robin, MRU, fixed), detach/attach |
| Datastores | Create on one or more LUNs, grow into an expanded LUN or add an extent, rename (label or storage ID), unmount/mount per node, reclaim free space (UNMAP), delete and detach |
| Arrays | Add an array with a pinned TLS certificate, register the cluster's hosts, **provision a datastore end to end**, grow on the array, delete including the array volume |

A datastore is a shared thick-LVM volume group on multipathed LUNs, registered
as storage type `fcsan` (a subclass of Proxmox's own LVM plugin), so live
migration, HA and Proxmox VE 9 volume-chain snapshots work as on shared LVM.

## Supported arrays (provisioning)

| Array | `--type` | API |
| --- | --- | --- |
| IBM FlashSystem / Spectrum Virtualize | `ibm-sv` | REST, port 7443 |
| Pure Storage FlashArray | `pure` | REST 2.x (API token) |
| INFINIDAT InfiniBox | `infinidat` | REST |
| Dell PowerStore | `dell-powerstore` | REST |
| Dell PowerMax / VMAX | `dell-powermax` | Unisphere REST |
| NetApp ONTAP (AFF / ASA / FAS) | `netapp-ontap` | ONTAP REST |
| NetApp E-Series | `netapp-eseries` | SANtricity Web Services |
| Hitachi VSP | `hitachi-vsp` | Configuration Manager REST |

Every driver's requests were checked against the vendor's own SDK or tooling
(PyPowerStore, PyU4V, InfiniSDK, Pure's generated SDK, NetApp's Ansible
collections, OpenStack Cinder's Hitachi driver). Without a driver, any FC or
iSCSI array works for everything except provisioning.

## Requirements

- Proxmox VE 8.x or 9.x on every node, all on the same pve-fcsan version
- `multipath-tools` and `lvm2` (pulled in by the package)
- Every node zoned to the array and in the array's host group / host cluster
  (pvesan can create the host objects for you)

## Install

Add the apt repository and install on **every** cluster node, one at a time,
then check the integration:

```bash
curl -fsSL https://warddynamiccomputing.github.io/pve-fcsan/pve-fcsan.gpg -o /usr/share/keyrings/pve-fcsan.gpg
cat > /etc/apt/sources.list.d/pve-fcsan.sources <<'EOF'
Types: deb
URIs: https://warddynamiccomputing.github.io/pve-fcsan
Suites: stable
Components: main
Signed-By: /usr/share/keyrings/pve-fcsan.gpg
EOF
apt update
apt install pve-fcsan
/usr/share/pve-fcsan/pvesan-integrate status
pvesan adapters
```

Then reload the web GUI (Ctrl+F5) and open **Node → Disks → SAN / Fibre Channel**.
New versions arrive with `apt update && apt upgrade`, like Proxmox VE's own
updates.

The repository is signed with the key
`FBCA 7A62 0928 1FAA 796F  AFD0 ACCA EEE8 1834 4A99`; compare it with
`gpg --show-keys /usr/share/keyrings/pve-fcsan.gpg`.

Without the repository: download the `.deb` from a
[GitHub release](../../releases) and run `apt install ./pve-fcsan_*_all.deb`,
or build it on any Debian 12/13 machine or Proxmox node:

```bash
apt install build-essential debhelper
make test
make deb
```

## Quick start

```bash
pvesan rescan-all                                   # find LUNs on every node
pvesan devices                                      # list them
pvesan datastore create ds01 --devices <wwid>       # shared datastore on a LUN

# with an array driver
pvesan array probe 10.0.0.50 --type ibm-sv          # read the certificate fingerprint
pvesan array add fs01 --type ibm-sv --address 10.0.0.50 --username pvesan --fingerprint 'sha256$...'
pvesan array register-cluster fs01
pvesan provision fs01 gold01 --pool Pool0 --size 2048
```

## Documentation

- [Runbook](docs/pvesan-Runbook.md) ([PDF](docs/pvesan-Runbook.pdf)): install, every procedure, troubleshooting, CLI/API reference
- [How It Works](docs/pvesan-How-It-Works.md) ([PDF](docs/pvesan-How-It-Works.pdf)): architecture, data model, operation internals, locking, drivers, development process

## How it hooks into Proxmox VE

The storage plugin uses Proxmox's supported custom-plugin directory. The REST
API and GUI panel need **one marked line each** in two pve-manager files
(`PVE/API2/Nodes.pm`, `index.html.tpl`), because Proxmox VE has no plugin hook
for those. The API line loads pve-fcsan inside an `eval`, so if pve-fcsan ever
fails to load, only its own API and panel are missing (with a warning in the
pveproxy and pvedaemon journals) and the rest of the Proxmox VE API keeps
working. The patched file is checked with `perl -c` and reverted if it doesn't
compile, and a dpkg trigger re-applies it after every pve-manager upgrade.
Removing the package removes both lines. This is not supported by Proxmox
Server Solutions; check `pvesan-integrate status` after upgrades.

## Layout

| Path | What |
| --- | --- |
| `src/PVE/Storage/Custom/FCSANPlugin.pm` | storage type `fcsan` |
| `src/PVE/API2/SAN.pm` | REST API `/nodes/{node}/san` |
| `src/PVE/CLI/pvesan.pm`, `bin/pvesan` | CLI |
| `src/PVE/SAN/*.pm` | discovery, multipath, LVM, cluster config, node ops, orchestration, provisioning |
| `src/PVE/SAN/Array/*.pm` | array drivers (shared base + one per platform) |
| `www/pvesan.js` | GUI extension |
| `bin/pvesan-integrate` | API/GUI registration in pve-manager |
| `systemd/pvesan-sync.service` | applies cluster SAN config at boot |
| `t/` | tests: fake sysfs tree, fake arrays, compile check |
| `tools/build-apt-repo.sh` | builds the signed apt repository (run by CI) |

## License

[GNU Affero General Public License v3.0 or later](LICENSE), the same license
as Proxmox VE.
