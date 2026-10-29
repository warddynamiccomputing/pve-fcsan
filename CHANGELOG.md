# Changelog

The Debian changelog (`debian/changelog`) is the authoritative history; this is
the readable summary.

## Unreleased
- Experimental: replication and disaster recovery. Replicate an array
  datastore to a partner array as one consistent group (`pvesan dr enable`,
  Pure FlashArray protection group targets with a replication schedule and
  target retention), send a replica now, and see the newest complete
  replica and its age (`pvesan dr status`, Disaster recovery tab).
- Guest configs travel with the data: the configs of every guest with disks
  on a protected datastore and its recovery plan are written onto the
  datastore (LV `pvesan-dr-meta`, two checksummed slots) every 15 minutes
  by `pvesan-dr.timer` and before every replica.
- Recovery plans: the order guests start in at the DR site, with a delay
  after each (`pvesan dr set-plan`).
- DR site: list replicas (`pvesan dr replicas`), test failover (a copy of a
  replica under `<storage>-drtest`, guests with new MACs and identity and
  their links down; `pvesan dr cleanup` removes it), failover (guests keep
  their identity), an optional VM ID offset, and `pvesan dr import` for
  LUNs promoted on any array by hand.
- Planned failover from the primary site: shut the guests down in reverse
  plan order, write their configs, unmount the datastore and send a final
  replica (`pvesan dr prepare-failover`).
- Pure FlashArray: the replication schedule's own snapshots no longer show
  in the datastore's snapshot list.
- Array snapshots on NetApp ONTAP: snapshots of the LUN's own FlexVol,
  copies as FlexClones, restore of the FlexVol to a snapshot; ONTAP's own
  scheduled snapshots are not listed. Single-LUN datastores only.
- Array snapshots on IBM Spectrum Virtualize (FlashSystem, SVC): FlashCopy
  snapshots (thin targets, no background copy), several volumes at one point
  in time through a FlashCopy consistency group, copies fed from a snapshot
  in the background, restore with a reverse FlashCopy.
- Dell PowerStore: datastores on several volumes are snapshotted at one
  point in time through a write-order consistent volume group, and restored
  as a group.
- New array driver: HPE Alletra 5000 / 6000 and Nimble Storage (`hpe-nimble`),
  using the NimOS REST API on port 5392. The cluster is one FC initiator
  group; volumes are presented through access control records. Array
  snapshots, copies (clones) and restores; datastores on several volumes are
  snapshotted through a volume collection and its snapshot collections.

## 1.5.0
- Array snapshots of datastores (Pure FlashArray, INFINIDAT InfiniBox, Dell
  PowerStore): take, list and delete from the new Snapshots tab, the
  `pvesan snapshot` commands or the API. Datastores on several volumes are
  snapshotted at one point in time (Pure protection group, InfiniBox group
  snapshot).
- Mount a snapshot as a read-only copy datastore (clone, map,
  `vgimportclone` under a new name) and restore one VM from it, over its
  disks or into a new VM ID; remove the copy afterwards.
- Roll a whole datastore back to a snapshot in place, with every guest
  stopped and the volume group deactivated on all nodes.
- Snapshot schedules with retention (`pvesan-snapshot.timer`, one node per
  run through a claim in the cluster lock).
- Weekly automatic space reclaim per datastore (`pvesan-reclaim.timer`) and
  the `fc-discard` storage option to UNMAP a VM disk when it is deleted.
- Other drivers report array snapshots as not supported yet.
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
- Experimental: storage type `fcsanvol`, one array volume per VM disk (Pure
  FlashArray). Disk snapshots, rollback, templates, linked clones and resize
  are array operations; a node scans only the disk's LUN number when it
  activates it; `fc-max-luns` guards LUN limits.

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
