# Changelog

The Debian changelog (`debian/changelog`) is the authoritative history; this is
the readable summary.

## Unreleased
- Array view per datastore: pool capacity and use, volume provisioned and
  written space, data reduction and array alerts (Pure; InfiniBox and
  PowerStore partly), cached in the cluster filesystem.
- I/O rates per LUN (IOPS, throughput, latency, utilisation) from the
  multipath maps' block statistics: Performance tab, `pvesan iostats`.
- Datastore → VMs list and the datastore, LUNs and array volume of each disk
  of a guest (`pvesan datastore guests`, `pvesan guest <vmid>`).
- Path health on every node (missing LUN, dead, fewer paths than seen
  before) and array problems (pool over threshold, array alerts, failed
  array calls), sent once through Proxmox VE notification targets by the
  new `pvesan-monitor.timer`; Health tab.
- `no_path_retry` per LUN; LUNs provisioned on IBM FlashSystem, NetApp ONTAP
  and InfiniBox get 12 checks (about one minute) instead of queueing
  forever. Per-array defaults are documented.
- New nodes are registered on arrays automatically (`auto-register`); hosts
  of removed nodes can be removed (Pure, InfiniBox, PowerStore).
- Zoning hints: which array ports each node's adapters are logged in to.

## 1.4.0
- New array driver: Fujitsu ETERNUS DX S5 / AF S3 (`fujitsu-eternus`), using the
  ETERNUS RESTful API on port 5665 (firmware V11L40 or later).
- README: array drivers are optional.

## 1.3.1
- Fail-safe integration: if pve-fcsan fails to load, only its own API and GUI
  panel are disabled; the rest of the Proxmox VE API and GUI keep working.
  Upgrading replaces the 1.3.0 line automatically.
- `pvesan-integrate status` checks that the API module loads and flags an
  outdated line.

## 1.3.0
- New array drivers: Dell PowerStore, Dell PowerMax / VMAX (Unisphere),
  NetApp ONTAP, NetApp E-Series, Hitachi VSP.
- Vendor settings on arrays: `system-id`, `svm`, `portgroup`, `srp`, `slo`,
  `target-ports`.
- Provisioning reads the WWID after mapping where the array only reports it
  then (Hitachi).

## 1.2.2
- Pure: JSON body on host-group and connection creation; free space from
  `total_used`.

## 1.2.1
- InfiniBox: unmap by LUN number, approve every change request, FC port type
  `fc`, more robust paging.

## 1.2.0
- Array drivers for Pure Storage FlashArray and INFINIDAT InfiniBox; shared
  driver base class.

## 1.1.0
- Array integration (IBM FlashSystem / Spectrum Virtualize): add arrays with a
  pinned certificate, register the cluster, provision / grow / delete
  datastores on the array, link existing datastores.

## 1.0.3
- `pvesan` exits non-zero when a cluster task fails.

## 1.0.2
- Fix cluster-wide operations (the per-node calls lost their arguments).

## 1.0.1
- Fix configuration sync on fresh nodes, API path clash, driver name for
  qla2xxx, link-down fabric name.

## 1.0.0
- Initial release: `fcsan` storage plugin, REST API, `pvesan` CLI, GUI panel,
  cluster-wide multipath alias and policy management.
