# Changelog

The Debian changelog (`debian/changelog`) is the authoritative history; this is
the readable summary.

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
