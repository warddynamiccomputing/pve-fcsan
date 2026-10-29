// pve-fcsan GUI extension: Node > Disks > SAN / Fibre Channel
//
// Loaded after pvemanagerlib.js (see pvesan-integrate). Uses only public
// widget-toolkit classes so it survives pve-manager updates.

Proxmox.Utils.override_task_descriptions({
    pvesanrescan: ['SAN', gettext('Rescan all nodes')],
    pvesanclaim: ['SAN Device', gettext('Add')],
    pvesandev: ['SAN Device', gettext('Edit')],
    pvesandetach: ['SAN Device', gettext('Detach')],
    pvesanattach: ['SAN Device', gettext('Attach')],
    pvesancreate: ['SAN Datastore', gettext('Create')],
    pvesanextend: ['SAN Datastore', gettext('Increase capacity')],
    pvesanrename: ['SAN Datastore', gettext('Rename')],
    pvesanumount: ['SAN Datastore', gettext('Unmount')],
    pvesanmount: ['SAN Datastore', gettext('Mount')],
    pvesanreclaim: ['SAN Datastore', gettext('Reclaim space')],
    pvesandestroy: ['SAN Datastore', gettext('Delete')],
    pvesanremovehost: ['SAN Array', gettext('Remove host of a removed node')],
    pvesanregister: ['SAN Array', gettext('Register cluster')],
    pvesanprovision: ['SAN Array', gettext('Provision datastore')],
    pvesanarraygrow: ['SAN Array', gettext('Grow datastore')],
    pvesansnapshot: ['SAN Datastore', gettext('Take array snapshot')],
    pvesansnapdel: ['SAN Datastore', gettext('Delete array snapshot')],
    pvesansnapmount: ['SAN Datastore', gettext('Mount snapshot as copy')],
    pvesanrollback: ['SAN Datastore', gettext('Roll back to snapshot')],
    pvesancopyremove: ['SAN Datastore', gettext('Remove snapshot copy')],
    pvesanrestorevm: ['VM', gettext('Restore from array snapshot')],
});

Ext.define('PVE.san.Utils', {
    singleton: true,

    arrayTypes: {
	'ibm-sv': {
	    name: 'IBM FlashSystem / Spectrum Virtualize',
	    port: 7443,
	    username: true,
	    secretLabel: gettext('Password'),
	    roleHint: gettext('Use a dedicated array user with the Administrator role (creates hosts, volumes and mappings).'),
	    certHint: gettext('IBM: Settings > Security > Secure Communications.'),
	},
	'pure': {
	    name: 'Pure Storage FlashArray',
	    port: 443,
	    username: false,
	    secretLabel: gettext('API token'),
	    roleHint: gettext('Create an API token for a user with the Storage Admin role (Settings > Users and Policies > API Tokens). Volumes on FlashArray are always thin; deleted volumes stay recoverable until eradicated.'),
	    certHint: gettext('Pure: Settings > System > SSL Certificate.'),
	},
	'infinidat': {
	    name: 'INFINIDAT InfiniBox',
	    port: 443,
	    username: true,
	    secretLabel: gettext('Password'),
	    roleHint: gettext('Use a dedicated InfiniBox user with the Pool Admin (owning the pools you provision from) or Admin role.'),
	    certHint: gettext('InfiniBox: Settings > Security > SSL certificate.'),
	},
	'dell-powerstore': {
	    name: 'Dell PowerStore',
	    port: 443,
	    username: true,
	    secretLabel: gettext('Password'),
	    roleHint: gettext('Use a PowerStore user with the Storage Administrator role. Volumes are always thin.'),
	    certHint: gettext('PowerStore Manager: Settings > Security > Certificates.'),
	},
	'dell-powermax': {
	    name: 'Dell PowerMax / VMAX (Unisphere)',
	    port: 8443,
	    username: true,
	    secretLabel: gettext('Password'),
	    roleHint: gettext('Address = Unisphere for PowerMax. User needs the StorageAdmin role on the array. Create a port group of the array FC ports zoned to the cluster first; pvesan creates the host group, storage group <cluster>_SG and masking view <cluster>_MV.'),
	    certHint: gettext('Unisphere: Settings > Certificate Management.'),
	    fields: { 'system-id': true, 'portgroup': true, 'srp': false, 'slo': false },
	},
	'netapp-ontap': {
	    name: 'NetApp ONTAP (AFF / ASA / FAS)',
	    port: 443,
	    username: true,
	    secretLabel: gettext('Password'),
	    roleHint: gettext('Use a cluster or SVM admin account with the REST API (http) application. Each datastore gets its own FlexVol with one LUN; pools are aggregates; the cluster is one FCP igroup.'),
	    certHint: gettext('ONTAP: "security certificate show" on the cluster management LIF.'),
	    fields: { 'svm': true },
	},
	'netapp-eseries': {
	    name: 'NetApp E-Series (SANtricity)',
	    port: 8443,
	    username: true,
	    secretLabel: gettext('Password'),
	    roleHint: gettext('Use a SANtricity user with the storage admin role (embedded Web Services). Thick volumes only.'),
	    certHint: gettext('SANtricity System Manager: Settings > Certificates.'),
	    fields: { 'system-id': false },
	},
	'hitachi-vsp': {
	    name: 'Hitachi VSP (Configuration Manager REST)',
	    port: 443,
	    username: true,
	    secretLabel: gettext('Password'),
	    roleHint: gettext('Use a storage user with the Storage Administrator (Provisioning) role. Hitachi host groups belong to one port: list every array FC port zoned to the cluster; pvesan creates a host group and LU path on each.'),
	    certHint: gettext('Configuration Manager / SVP: server certificate settings.'),
	    fields: { 'target-ports': true, 'system-id': false },
	},
	'fujitsu-eternus': {
	    name: 'Fujitsu ETERNUS DX S5 / AF S3 (RESTful API)',
	    port: 5665,
	    username: true,
	    secretLabel: gettext('Password'),
	    roleHint: gettext('Needs controller firmware V11L40 or later with the RESTful API enabled and port 5665 open in the array firewall settings. Use a user with the Admin or StorageAdmin role. pvesan registers each node HBA port as an FC host and connects every volume to all of them; enable host affinity on the CA ports zoned to the cluster. Pools are thin provisioning pools.'),
	    certHint: gettext('ETERNUS Web GUI: the RESTful API uses the Web GUI SSL certificate.'),
	},
	'hpe-nimble': {
	    name: 'HPE Alletra 5000/6000 (Nimble)',
	    port: 5392,
	    username: true,
	    secretLabel: gettext('Password'),
	    roleHint: gettext('Use a NimOS user with the Power User or Administrator role (REST API on port 5392). The cluster is one FC initiator group holding every node WWPN; thin volumes have reserve 0, thick ones reserve 100%. Datastores on several volumes are snapshotted through a volume collection.'),
	    certHint: gettext('NimOS GUI: the management certificate under Administration > Security.'),
	},
    },

    optionFields: [
	{ name: 'system-id', label: gettext('System ID'), emptyText: 'Symmetrix ID / 1 / storage device ID' },
	{ name: 'svm', label: 'SVM', emptyText: 'svm_san' },
	{ name: 'portgroup', label: gettext('Port group'), emptyText: 'pve_PG' },
	{ name: 'srp', label: 'SRP', emptyText: 'SRP_1' },
	{ name: 'slo', label: gettext('Service level'), emptyText: gettext('none (Optimized)') },
	{ name: 'target-ports', label: gettext('Target ports'), emptyText: 'CL1-A,CL2-A' },
    ],

    policies: [
	['array-default', gettext('Array default')],
	['round-robin', 'Round Robin'],
	['alua', 'ALUA (optimized paths, round robin)'],
	['mru', 'Most Recently Used'],
	['fixed', 'Fixed (fail back)'],
    ],

    // POST/PUT/DELETE that returns a UPID: show the task log, call done() when closed
    runTask: function(cfg) {
	Proxmox.Utils.API2Request({
	    url: cfg.url,
	    method: cfg.method || 'POST',
	    params: cfg.params || {},
	    waitMsgTarget: cfg.waitMsgTarget,
	    success: function(response) {
		let win = Ext.create('Proxmox.window.TaskViewer', { upid: response.result.data });
		if (cfg.done) {
		    win.on('destroy', cfg.done);
		}
		win.show();
	    },
	    failure: response => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
	});
    },

    confirmTyped: function(title, msg, expected, callback) {
	Ext.Msg.prompt(title,
	    msg + '<br><br>' + Ext.String.format(gettext("Type '{0}' to confirm:"), Ext.htmlEncode(expected)),
	    function(btn, text) {
		if (btn !== 'ok') {
		    return;
		}
		if (text === expected) {
		    callback();
		} else {
		    Ext.Msg.alert(gettext('Error'), gettext('Confirmation does not match, nothing was changed.'));
		}
	    });
    },

    renderPaths: function(value, meta, rec) {
	let total = rec.data.paths_total || 0;
	let active = rec.data.paths_active || 0;
	let cls = active === 0 ? 'fa-times critical' : active < total ? 'fa-exclamation-triangle warning' : 'fa-check good';
	return `<i class="fa ${cls}"></i> ${active} / ${total}`;
    },

    renderState: function(value) {
	if (!value) {
	    return '-';
	}
	let bad = /dead|faulty|failed|offline|blocked|linkdown/i.test(value);
	let warn = /degraded|ghost|shaky/i.test(value);
	let cls = bad ? 'fa-times critical' : warn ? 'fa-exclamation-triangle warning' : 'fa-check good';
	return `<i class="fa ${cls}"></i> ${Ext.htmlEncode(value)}`;
    },

    renderUsage: function(value, meta, rec) {
	if (!rec.data.size) {
	    return '-';
	}
	let pct = rec.data.used / rec.data.size;
	return `${Proxmox.Utils.render_size(rec.data.used)} / ${Proxmox.Utils.render_size(rec.data.size)} (${(pct * 100).toFixed(1)}%)`;
    },

    joinValues: function(values) {
	Ext.Object.each(values, function(key, value) {
	    if (Ext.isArray(value)) {
		values[key] = value.join(',');
	    }
	    if (values[key] === '' || values[key] === null || values[key] === undefined) {
		delete values[key];
	    }
	});
	return values;
    },
});

// Checkbox grid of unused LUNs, used by the create and extend dialogs.
Ext.define('PVE.san.DeviceSelector', {
    extend: 'Ext.grid.Panel',
    alias: 'widget.pveSanDeviceSelector',

    height: 220,
    selModel: { selType: 'checkboxmodel', mode: 'SIMPLE' },
    emptyText: gettext('No unused SAN LUNs found. Present the LUN to all nodes and rescan.'),

    columns: [
	{ header: gettext('Name'), dataIndex: 'name', flex: 1 },
	{ header: 'WWID', dataIndex: 'wwid', flex: 2 },
	{ header: gettext('Vendor'), dataIndex: 'vendor', width: 90 },
	{ header: gettext('Model'), dataIndex: 'model', width: 110 },
	{ header: 'LUN', dataIndex: 'lun', width: 50 },
	{ header: gettext('Size'), dataIndex: 'size', width: 90, renderer: Proxmox.Utils.render_size },
	{ header: gettext('Paths'), dataIndex: 'paths_active', width: 80, renderer: PVE.san.Utils.renderPaths },
    ],

    initComponent: function() {
	let me = this;
	me.store = Ext.create('Ext.data.Store', {
	    proxy: { type: 'proxmox', url: `/api2/json/nodes/${me.nodename}/san/devices?unused=1` },
	    sorters: 'name',
	    autoLoad: true,
	});
	me.callParent();
    },

    getWwids: function() {
	return this.getSelection().map(rec => rec.data.wwid).join(',');
    },
});

Ext.define('PVE.san.DatastoreCreate', {
    extend: 'Proxmox.window.Edit',

    subject: gettext('SAN Datastore'),
    isCreate: true,
    method: 'POST',
    showTaskViewer: true,
    width: 760,

    initComponent: function() {
	let me = this;
	me.url = `/nodes/${me.nodename}/san/datastores`;

	let selector = Ext.create('PVE.san.DeviceSelector', { nodename: me.nodename });

	me.items = [{
	    xtype: 'inputpanel',
	    onGetValues: function(values) {
		values.devices = selector.getWwids();
		return PVE.san.Utils.joinValues(values);
	    },
	    column1: [
		{ xtype: 'textfield', name: 'storage', fieldLabel: 'ID', vtype: 'StorageId', allowBlank: false },
		{ xtype: 'textfield', name: 'label', fieldLabel: gettext('Display name'), allowBlank: true },
		{ xtype: 'textfield', name: 'vgname', fieldLabel: gettext('Volume group'), allowBlank: true,
		    emptyText: 'san_<ID>' },
	    ],
	    column2: [
		{ xtype: 'pveContentTypeSelector', cts: ['images', 'rootdir'], name: 'content',
		    fieldLabel: gettext('Content'), multiSelect: true, value: ['images', 'rootdir'], allowBlank: false },
		{ xtype: 'pveNodeSelector', name: 'nodes', fieldLabel: gettext('Nodes'), multiSelect: true,
		    autoSelect: false, emptyText: gettext('All') + ' (' + gettext('No restrictions') + ')' },
		{ xtype: 'proxmoxcheckbox', name: 'force', fieldLabel: gettext('Wipe LUNs'), uncheckedValue: 0,
		    autoEl: { tag: 'div', 'data-qtip': gettext('Remove old partition tables or filesystem signatures') } },
	    ],
	    columnB: [
		{ xtype: 'displayfield', value: gettext('LUNs (must be visible on every node):') },
		selector,
	    ],
	}];
	me.callParent();
    },
});

Ext.define('PVE.san.DatastoreExtend', {
    extend: 'Proxmox.window.Edit',

    subject: gettext('Datastore capacity'),
    method: 'POST',
    showTaskViewer: true,
    width: 760,

    initComponent: function() {
	let me = this;
	me.url = `/nodes/${me.nodename}/san/datastores/${me.storage}/extend`;

	let selector = Ext.create('PVE.san.DeviceSelector', { nodename: me.nodename, disabled: true });

	me.items = [{
	    xtype: 'inputpanel',
	    onGetValues: function(values) {
		let res = {};
		if (values.mode === 'add') {
		    res['add-devices'] = selector.getWwids();
		    res.force = values.force;
		}
		return PVE.san.Utils.joinValues(res);
	    },
	    items: [
		{ xtype: 'displayfield', fieldLabel: gettext('Datastore'), value: Ext.htmlEncode(me.storage) },
		{
		    xtype: 'radiogroup',
		    fieldLabel: gettext('Method'),
		    columns: 1,
		    items: [
			{ boxLabel: gettext('Expand: use space added to the existing LUN(s) on the array'),
			    name: 'mode', inputValue: 'grow', checked: true },
			{ boxLabel: gettext('Add extent: add another LUN to this datastore'),
			    name: 'mode', inputValue: 'add' },
		    ],
		    listeners: {
			change: (field, value) => {
			    selector.setDisabled(value.mode !== 'add');
			    me.down('field[name=force]').setDisabled(value.mode !== 'add');
			},
		    },
		},
		selector,
		{ xtype: 'proxmoxcheckbox', name: 'force', fieldLabel: gettext('Wipe LUNs'), disabled: true },
	    ],
	}];
	me.callParent();
    },
});

// Grow an array-linked datastore: the array volume first, then the datastore.
Ext.define('PVE.san.DatastoreArrayGrow', {
    extend: 'Proxmox.window.Edit',

    subject: gettext('Datastore capacity'),
    method: 'POST',
    showTaskViewer: true,
    width: 480,

    initComponent: function() {
	let me = this;
	let current = Math.ceil((me.record.size || 0) / (1024 * 1024 * 1024));
	me.url = `/nodes/${me.nodename}/san/datastores/${me.record.storage}/array-grow`;
	me.items = [{
	    xtype: 'inputpanel',
	    items: [
		{ xtype: 'displayfield', fieldLabel: gettext('Datastore'), value: Ext.htmlEncode(me.record.storage) },
		{ xtype: 'displayfield', fieldLabel: gettext('Array volume'),
		    value: Ext.htmlEncode(`${me.record.array}: ${me.record.volumes}`) },
		{ xtype: 'proxmoxintegerfield', name: 'size', fieldLabel: gettext('New size') + ' (GiB)',
		    minValue: current + 1, value: current + 100, allowBlank: false },
		{ xtype: 'displayfield', userCls: 'pmx-hint',
		    value: gettext('The volume is expanded on the array, then every node rescans and the datastore grows. No downtime.') },
	    ],
	}];
	me.callParent();
    },
});

Ext.define('PVE.san.DatastoreDelete', {
    extend: 'Ext.window.Window',

    title: gettext('Delete datastore'),
    modal: true,
    width: 480,
    bodyPadding: 12,
    layout: 'anchor',
    defaults: { anchor: '100%' },

    initComponent: function() {
	let me = this;
	let rec = me.record;
	me.items = [
	    { xtype: 'displayfield', value: gettext('Removes the storage, its volume group and all LVM metadata. Guests must not use it any more.') },
	    { xtype: 'proxmoxcheckbox', itemId: 'destroyData', boxLabel: gettext('Also delete remaining unused volumes on it') },
	    {
		xtype: 'proxmoxcheckbox',
		itemId: 'deleteVolume',
		hidden: !rec.array,
		boxLabel: Ext.String.format(gettext('Also unmap and delete the volume on array {0} (data is lost)'), Ext.htmlEncode(rec.array || '')),
	    },
	    { xtype: 'textfield', itemId: 'confirm', fieldLabel: Ext.String.format(gettext("Type '{0}'"), Ext.htmlEncode(rec.storage)) },
	];
	me.buttons = [{
	    text: gettext('Delete'),
	    cls: 'pmx-btn-danger', // not every toolkit version styles this; harmless
	    handler: function() {
		if (me.down('#confirm').getValue() !== rec.storage) {
		    Ext.Msg.alert(gettext('Error'), gettext('Confirmation does not match, nothing was changed.'));
		    return;
		}
		let q = ['detach=1'];
		if (me.down('#destroyData').getValue()) { q.push('destroy-data=1'); }
		if (rec.array && me.down('#deleteVolume').getValue()) { q.push('delete-volume=1'); }
		PVE.san.Utils.runTask({
		    url: `/nodes/${me.nodename}/san/datastores/${rec.storage}?${q.join('&')}`,
		    method: 'DELETE',
		    done: me.done,
		});
		me.close();
	    },
	}];
	me.callParent();
    },
});

Ext.define('PVE.san.DatastoreRename', {
    extend: 'Proxmox.window.Edit',

    subject: gettext('Datastore'),
    method: 'POST',
    showTaskViewer: true,
    width: 520,

    initComponent: function() {
	let me = this;
	me.url = `/nodes/${me.nodename}/san/datastores/${me.storage}/rename`;
	me.items = [{
	    xtype: 'inputpanel',
	    onGetValues: values => PVE.san.Utils.joinValues(values),
	    items: [
		{ xtype: 'textfield', name: 'label', fieldLabel: gettext('Display name'), value: me.label || '',
		    allowBlank: true },
		{ xtype: 'textfield', name: 'new-id', fieldLabel: gettext('New storage ID'), vtype: 'StorageId',
		    allowBlank: true, emptyText: Ext.htmlEncode(me.storage) },
		{ xtype: 'proxmoxcheckbox', name: 'rename-vg', fieldLabel: gettext('Rename VG too') },
		{ xtype: 'displayfield', userCls: 'pmx-hint',
		    value: gettext('Changing the display name is online. Changing the storage ID needs all guests on this datastore stopped; their configs are updated automatically.') },
	    ],
	}];
	me.callParent();
    },
});

Ext.define('PVE.san.NodesWindow', {
    extend: 'Proxmox.window.Edit',

    method: 'POST',
    showTaskViewer: true,
    width: 480,

    initComponent: function() {
	let me = this;
	me.url = `/nodes/${me.nodename}/san/datastores/${me.storage}/${me.action}`;
	me.subject = me.action === 'unmount' ? gettext('Unmount datastore') : gettext('Mount datastore');
	me.items = [{
	    xtype: 'inputpanel',
	    onGetValues: values => PVE.san.Utils.joinValues(values),
	    items: [
		{ xtype: 'displayfield', fieldLabel: gettext('Datastore'), value: Ext.htmlEncode(me.storage) },
		{ xtype: 'pveNodeSelector', name: 'nodes', fieldLabel: gettext('Nodes'), multiSelect: true,
		    autoSelect: false, emptyText: gettext('All') },
		{ xtype: 'displayfield', userCls: 'pmx-hint',
		    value: me.action === 'unmount'
			? gettext('Guests using the datastore must be stopped on the selected nodes. "All" disables the datastore.')
			: gettext('"All" enables the datastore and removes any node restriction.') },
	    ],
	}];
	me.callParent();
    },
});

Ext.define('PVE.san.DeviceEdit', {
    extend: 'Proxmox.window.Edit',

    subject: gettext('SAN Device'),
    method: 'PUT',
    showTaskViewer: true,
    width: 520,

    initComponent: function() {
	let me = this;
	let rec = me.record.data;
	me.url = `/nodes/${me.nodename}/san/devices/${rec.wwid}`;
	me.items = [{
	    xtype: 'inputpanel',
	    onGetValues: function(values) {
		let del = [];
		if (!values.alias) {
		    del.push('alias');
		}
		if (!values['no-path-retry']) {
		    del.push('no-path-retry');
		}
		if (values.policy === 'array-default') {
		    del.push('policy');
		    delete values.policy;
		}
		values = PVE.san.Utils.joinValues(values);
		if (del.length) {
		    values.delete = del.join(',');
		}
		return values;
	    },
	    items: [
		{ xtype: 'displayfield', fieldLabel: 'WWID', value: Ext.htmlEncode(rec.wwid) },
		{ xtype: 'displayfield', fieldLabel: gettext('Device'),
		    value: Ext.htmlEncode(`${rec.vendor || ''} ${rec.model || ''}, LUN ${rec.lun}`) },
		{ xtype: 'textfield', name: 'alias', fieldLabel: gettext('Alias'), value: rec.alias || '',
		    regex: /^[A-Za-z][A-Za-z0-9_.+-]{0,63}$/, allowBlank: true,
		    emptyText: gettext('none (multipath default name)') },
		{ xtype: 'proxmoxKVComboBox', name: 'policy', fieldLabel: gettext('Path policy'),
		    value: rec.policy || 'array-default', comboItems: PVE.san.Utils.policies },
		{ xtype: 'textfield', name: 'no-path-retry', fieldLabel: gettext('No path retry'), value: rec.no_path_retry || '',
		    regex: /^(?:\d{1,4}|queue|fail)$/, allowBlank: true,
		    emptyText: gettext('array default (multipath-tools)') },
		{ xtype: 'displayfield', userCls: 'pmx-hint',
		    value: gettext('No path retry: how many path checks (5 s each) I/O is queued when every path is gone, "queue" to wait forever, "fail" to fail at once.') },
	    ],
	}];
	me.callParent();
    },
});

Ext.define('PVE.san.BaseGrid', {
    extend: 'Ext.grid.Panel',

    stateful: true,

    initComponent: function() {
	let me = this;
	if (!me.nodename) {
	    throw "no node name specified";
	}
	me.store = Ext.create('Ext.data.Store', {
	    proxy: { type: 'proxmox', url: `/api2/json/nodes/${me.nodename}/san/${me.sanPath}` },
	    sorters: me.sanSorters || [],
	});
	me.tbar = (me.tbar || []).concat(['->', {
	    text: gettext('Reload'),
	    iconCls: 'fa fa-refresh',
	    handler: () => me.reload(),
	}]);
	me.callParent();
	Proxmox.Utils.monStoreErrors(me, me.store);
	me.on('activate', () => me.reload());
    },

    reload: function() {
	this.store.load();
    },

    url: function(suffix) {
	return `/nodes/${this.nodename}/san/${suffix}`;
    },
});

Ext.define('PVE.san.AdapterGrid', {
    extend: 'PVE.san.BaseGrid',
    alias: 'widget.pveSanAdapterGrid',

    title: gettext('Adapters'),
    sanPath: 'adapters',
    stateId: 'grid-pvesan-adapters',

    columns: [
	{ header: gettext('Adapter'), dataIndex: 'name', width: 80 },
	{ header: gettext('Type'), dataIndex: 'transport', width: 60, renderer: v => (v || '').toUpperCase() },
	{ header: gettext('Model'), dataIndex: 'model', flex: 1 },
	{ header: gettext('Driver'), dataIndex: 'driver', width: 90 },
	{ header: 'WWPN / IQN', dataIndex: 'wwpn', flex: 1 },
	{ header: 'WWNN', dataIndex: 'wwnn', flex: 1, hidden: true },
	{ header: gettext('State'), dataIndex: 'state', width: 100, renderer: PVE.san.Utils.renderState },
	{ header: gettext('Speed'), dataIndex: 'speed', width: 90 },
	{ header: gettext('Fabric'), dataIndex: 'fabric', flex: 1, hidden: true },
	{ header: gettext('Firmware'), dataIndex: 'firmware', width: 110, hidden: true },
	{ header: gettext('Targets'), dataIndex: 'targets', width: 70 },
	{ header: gettext('Devices'), dataIndex: 'devices', width: 70 },
	{ header: gettext('Paths'), dataIndex: 'paths', width: 70 },
	{ header: gettext('Link failures'), dataIndex: 'link_failures', width: 90, hidden: true },
    ],

    initComponent: function() {
	let me = this;
	let rescan = function(lip) {
	    Proxmox.Utils.API2Request({
		url: me.url('rescan'),
		method: 'POST',
		params: lip ? { lip: 1 } : {},
		waitMsgTarget: me,
		success: function(response) {
		    let r = response.result.data;
		    Ext.Msg.alert(gettext('Rescan'), Ext.String.format(
			gettext('{0} paths. New: {1}. Removed: {2}. Resized: {3}.'),
			r.paths, r.new_paths.join(' ') || '-', r.removed_paths.join(' ') || '-',
			r.resized_maps.join(' ') || '-'));
		    me.reload();
		},
		failure: response => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
	    });
	};
	me.tbar = [
	    { text: gettext('Rescan'), iconCls: 'fa fa-search', handler: () => rescan(false) },
	    {
		text: gettext('Rescan all nodes'),
		iconCls: 'fa fa-sitemap',
		handler: () => PVE.san.Utils.runTask({ url: me.url('rescan-all'), done: () => me.reload() }),
	    },
	    {
		text: gettext('Rescan with LIP'),
		iconCls: 'fa fa-bolt',
		handler: () => Ext.Msg.confirm(gettext('Confirm'),
		    gettext('A LIP makes each FC port log in to the fabric again and briefly interrupts I/O on that port. Continue?'),
		    btn => btn === 'yes' && rescan(true)),
	    },
	];
	me.callParent();
    },
});

Ext.define('PVE.san.DeviceGrid', {
    extend: 'PVE.san.BaseGrid',
    alias: 'widget.pveSanDeviceGrid',

    title: gettext('Devices'),
    sanPath: 'devices',
    stateId: 'grid-pvesan-devices',
    sanSorters: 'name',

    columns: [
	{ header: gettext('Name'), dataIndex: 'name', width: 160 },
	{ header: 'WWID', dataIndex: 'wwid', flex: 1 },
	{ header: gettext('Vendor'), dataIndex: 'vendor', width: 90 },
	{ header: gettext('Model'), dataIndex: 'model', width: 110 },
	{ header: 'LUN', dataIndex: 'lun', width: 50 },
	{ header: gettext('Size'), dataIndex: 'size', width: 90, renderer: Proxmox.Utils.render_size },
	{ header: gettext('Paths'), dataIndex: 'paths_active', width: 80, renderer: PVE.san.Utils.renderPaths },
	{ header: gettext('Policy'), dataIndex: 'policy', width: 110 },
	{ header: gettext('No path retry'), dataIndex: 'no_path_retry', width: 100, hidden: true, renderer: v => v || gettext('default') },
	{ header: gettext('Usage'), dataIndex: 'usage', width: 160 },
	{
	    header: gettext('Flags'),
	    width: 140,
	    renderer: function(v, m, rec) {
		let f = [];
		if (!rec.data.claimed) { f.push(gettext('not multipathed')); }
		if (rec.data.detached) { f.push(gettext('detached')); }
		if (rec.data.resize_pending) { f.push(gettext('resize pending')); }
		return f.join(', ');
	    },
	},
    ],

    initComponent: function() {
	let me = this;
	let sm = Ext.create('Ext.selection.RowModel', {});
	me.selModel = sm;
	let rec = () => sm.getSelection()[0];
	let editDevice = function() {
	    if (!rec()) {
		return;
	    }
	    Ext.create('PVE.san.DeviceEdit', {
		nodename: me.nodename,
		record: rec(),
		autoShow: true,
		listeners: { destroy: () => me.reload() },
	    });
	};

	me.tbar = [
	    {
		xtype: 'proxmoxButton',
		text: gettext('Properties'),
		selModel: sm,
		disabled: true,
		handler: editDevice,
	    },
	    {
		xtype: 'proxmoxButton',
		text: gettext('Add (multipath)'),
		selModel: sm,
		disabled: true,
		enableFn: r => !r.data.claimed && !r.data.detached,
		handler: () => PVE.san.Utils.runTask({
		    url: me.url(`devices/${rec().data.wwid}/claim`), done: () => me.reload(),
		}),
	    },
	    {
		xtype: 'proxmoxButton',
		text: gettext('New datastore'),
		selModel: sm,
		disabled: true,
		enableFn: r => r.data.usage === 'free',
		handler: () => Ext.create('PVE.san.DatastoreCreate', {
		    nodename: me.nodename, autoShow: true, listeners: { destroy: () => me.reload() },
		}),
	    },
	    {
		xtype: 'proxmoxButton',
		text: gettext('Detach'),
		selModel: sm,
		disabled: true,
		enableFn: r => !r.data.detached && !/^(datastore|lvm|in-use)/.test(r.data.usage),
		handler: () => PVE.san.Utils.confirmTyped(gettext('Detach device'),
		    gettext('The LUN is removed from every node and stays hidden after rescans until attached again.'),
		    rec().data.name,
		    () => PVE.san.Utils.runTask({
			url: me.url(`devices/${rec().data.wwid}/detach`), done: () => me.reload(),
		    })),
	    },
	    {
		xtype: 'proxmoxButton',
		text: gettext('Attach'),
		selModel: sm,
		disabled: true,
		enableFn: r => !!r.data.detached,
		handler: () => PVE.san.Utils.runTask({
		    url: me.url(`devices/${rec().data.wwid}/attach`), done: () => me.reload(),
		}),
	    },
	    {
		text: gettext('Clean up dead paths'),
		handler: () => Ext.Msg.confirm(gettext('Confirm'),
		    gettext('Remove SCSI paths that are offline or failed on this node?'),
		    btn => btn === 'yes' && Proxmox.Utils.API2Request({
			url: me.url('cleanup-paths'),
			method: 'POST',
			waitMsgTarget: me,
			success: function(response) {
			    let r = response.result.data;
			    Ext.Msg.alert(gettext('Clean up'), Ext.String.format(gettext('Removed: {0}. Skipped: {1}.'),
				r.removed_paths.join(' ') || '-', Ext.htmlEncode(r.skipped.join('; ')) || '-'));
			    me.reload();
			},
			failure: response => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
		    })),
	    },
	    {
		xtype: 'proxmoxcheckbox',
		boxLabel: gettext('Show local disks'),
		listeners: {
		    change: function(cb, value) {
			me.store.getProxy().setUrl(`/api2/json/nodes/${me.nodename}/san/devices${value ? '?all=1' : ''}`);
			me.reload();
		    },
		},
	    },
	];
	me.callParent();
	me.on('itemdblclick', editDevice);
    },
});

Ext.define('PVE.san.PathGrid', {
    extend: 'PVE.san.BaseGrid',
    alias: 'widget.pveSanPathGrid',

    title: gettext('Paths'),
    sanPath: 'paths',
    stateId: 'grid-pvesan-paths',
    sanSorters: ['device', 'hctl'],

    features: [{ ftype: 'grouping', groupHeaderTpl: '{name} ({rows.length} paths)' }],

    columns: [
	{ header: gettext('Device'), dataIndex: 'device', width: 160 },
	{ header: gettext('Path'), dataIndex: 'dev', width: 70 },
	{ header: 'H:C:T:L', dataIndex: 'hctl', width: 90 },
	{ header: gettext('Target WWPN'), dataIndex: 'target_wwpn', flex: 1 },
	{ header: gettext('SCSI state'), dataIndex: 'state', width: 110, renderer: PVE.san.Utils.renderState },
	{ header: gettext('Multipath'), dataIndex: 'dm_state', width: 100, renderer: PVE.san.Utils.renderState },
	{ header: gettext('Checker'), dataIndex: 'chk_state', width: 100, renderer: PVE.san.Utils.renderState },
	{ header: gettext('Priority'), dataIndex: 'priority', width: 70 },
    ],

    initComponent: function() {
	let me = this;
	me.callParent();
	me.store.setGroupField('device');
    },
});

Ext.define('PVE.san.DatastoreGrid', {
    extend: 'PVE.san.BaseGrid',
    alias: 'widget.pveSanDatastoreGrid',

    title: gettext('Datastores'),
    sanPath: 'datastores',
    stateId: 'grid-pvesan-datastores',
    sanSorters: 'storage',

    columns: [
	{ header: 'ID', dataIndex: 'storage', width: 120 },
	{ header: gettext('Display name'), dataIndex: 'label', flex: 1 },
	{ header: gettext('Type'), dataIndex: 'type', width: 60 },
	{ header: gettext('Volume group'), dataIndex: 'vgname', width: 120 },
	{ header: gettext('Usage'), dataIndex: 'used', width: 220, renderer: PVE.san.Utils.renderUsage },
	{ header: gettext('LUNs'), dataIndex: 'devices', flex: 1 },
	{
	    header: gettext('Array'),
	    dataIndex: 'array',
	    width: 140,
	    renderer: (v, m, rec) => (rec.data.copy_of
		? Ext.htmlEncode(`${gettext('copy of')} ${rec.data.copy_of} @ ${rec.data.snapshot}`)
		: v ? Ext.htmlEncode(`${v}: ${rec.data.volumes}`) : '-'),
	},
	{
	    header: gettext('Status'),
	    width: 110,
	    renderer: function(v, m, rec) {
		if (!rec.data.enabled) { return PVE.san.Utils.renderState('unmounted'); }
		return rec.data.active ? PVE.san.Utils.renderState('mounted') : PVE.san.Utils.renderState('offline');
	    },
	},
	{ header: gettext('Nodes'), dataIndex: 'nodes', width: 120, renderer: v => v || gettext('All') },
	{ header: 'UNMAP', dataIndex: 'discard', width: 60, renderer: Proxmox.Utils.format_boolean },
    ],

    initComponent: function() {
	let me = this;
	let sm = Ext.create('Ext.selection.RowModel', {});
	me.selModel = sm;
	let rec = () => sm.getSelection()[0].data;
	let open = (cls, extra) => Ext.create(cls, Ext.apply({
	    nodename: me.nodename,
	    storage: rec().storage,
	    autoShow: true,
	    listeners: { destroy: () => me.reload() },
	}, extra));

	me.tbar = [
	    {
		text: gettext('Create'),
		iconCls: 'fa fa-plus-circle',
		handler: () => Ext.create('PVE.san.DatastoreCreate', {
		    nodename: me.nodename, autoShow: true, listeners: { destroy: () => me.reload() },
		}),
	    },
	    {
		text: gettext('Provision from array'),
		iconCls: 'fa fa-magic',
		handler: () => Ext.create('PVE.san.Provision', {
		    nodename: me.nodename, autoShow: true, listeners: { destroy: () => me.reload() },
		}),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Increase capacity'), selModel: sm, disabled: true,
		handler: () => (rec().array
		    ? Ext.create('PVE.san.DatastoreArrayGrow', {
			nodename: me.nodename, record: rec(), autoShow: true, listeners: { destroy: () => me.reload() },
		    })
		    : open('PVE.san.DatastoreExtend')),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Rename'), selModel: sm, disabled: true,
		handler: () => open('PVE.san.DatastoreRename', { label: rec().label }),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Array view'), selModel: sm, disabled: true,
		enableFn: r => !!r.data.array,
		handler: () => Ext.create('PVE.san.ArrayView', { nodename: me.nodename, storage: rec().storage, autoShow: true }),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('VMs'), selModel: sm, disabled: true,
		handler: () => Ext.create('PVE.san.ListWindow', {
		    title: Ext.String.format(gettext('Guests on {0}'), Ext.htmlEncode(rec().storage)),
		    url: `/nodes/${me.nodename}/san/datastores/${rec().storage}/guests`,
		    autoShow: true,
		    emptyText: gettext('No guest has disks on this datastore.'),
		    columns: [
			{ header: 'ID', dataIndex: 'vmid', width: 70 },
			{ header: gettext('Type'), dataIndex: 'type', width: 60 },
			{ header: gettext('Name'), dataIndex: 'name', width: 140 },
			{ header: gettext('Node'), dataIndex: 'node', width: 100 },
			{ header: gettext('Status'), dataIndex: 'status', width: 80 },
			{ header: gettext('Disks'), dataIndex: 'disks', flex: 1 },
		    ],
		}),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Unmount'), selModel: sm, disabled: true,
		enableFn: r => !!r.data.enabled,
		handler: () => open('PVE.san.NodesWindow', { action: 'unmount' }),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Mount'), selModel: sm, disabled: true,
		handler: () => open('PVE.san.NodesWindow', { action: 'mount' }),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Reclaim space'), selModel: sm, disabled: true,
		enableFn: r => !!r.data.discard && !!r.data.active,
		confirmMsg: r => Ext.String.format(
		    gettext('Send UNMAP for all free space on {0}? Free space is temporarily unavailable for new disks while this runs.'),
		    Ext.htmlEncode(r.data.storage)),
		handler: () => PVE.san.Utils.runTask({
		    url: me.url(`datastores/${rec().storage}/reclaim`), done: () => me.reload(),
		}),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Restore VM'), selModel: sm, disabled: true,
		enableFn: r => !!r.data.copy_of,
		handler: () => Ext.create('PVE.san.RestoreVM', {
		    nodename: me.nodename, storage: rec().storage, record: rec(), autoShow: true,
		}),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Remove copy'), selModel: sm, disabled: true,
		enableFn: r => !!r.data.copy_of,
		confirmMsg: r => Ext.String.format(gettext('Remove snapshot copy {0} and its clone volume on the array? The snapshot itself stays.'),
		    Ext.htmlEncode(r.data.storage)),
		handler: () => PVE.san.Utils.runTask({
		    url: me.url(`datastores/${rec().storage}/remove-copy`), done: () => me.reload(),
		}),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Start recovery plan'), selModel: sm, disabled: true,
		enableFn: r => !!r.data.dr,
		confirmMsg: r => Ext.String.format(gettext('Start the guests of {0} in recovery plan order?'), Ext.htmlEncode(r.data.storage)),
		handler: () => PVE.san.Utils.runTask({ url: me.url(`datastores/${rec().storage}/run-plan`), done: () => me.reload() }),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Remove DR test'), selModel: sm, disabled: true,
		enableFn: r => r.data.dr === 'test',
		confirmMsg: r => Ext.String.format(gettext('Stop and remove the test guests of {0}, the datastore and its copied array volumes?'),
		    Ext.htmlEncode(r.data.storage)),
		handler: () => PVE.san.Utils.runTask({ url: me.url(`datastores/${rec().storage}/dr-cleanup`), done: () => me.reload() }),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Delete'), selModel: sm, disabled: true,
		handler: () => Ext.create('PVE.san.DatastoreDelete', {
		    nodename: me.nodename, record: rec(), autoShow: true, done: () => me.reload(),
		}),
	    },
	];
	me.callParent();
    },
});

// --- monitoring and health ---

// Read-only window around a grid fed from one API GET.
Ext.define('PVE.san.ListWindow', {
    extend: 'Ext.window.Window',

    modal: true,
    width: 800,
    height: 420,
    layout: 'fit',

    initComponent: function() {
	let me = this;
	me.grid = Ext.create('Ext.grid.Panel', {
	    store: Ext.create('Ext.data.Store', {
		proxy: { type: 'proxmox', url: `/api2/json${me.url}` },
		autoLoad: !me.manual,
	    }),
	    columns: me.columns,
	    tbar: me.tbar,
	    emptyText: me.emptyText || gettext('No data'),
	});
	me.items = [me.grid];
	delete me.tbar;
	me.callParent();
	Proxmox.Utils.monStoreErrors(me.grid, me.grid.getStore());
    },
});

Ext.define('PVE.san.ArrayView', {
    extend: 'Ext.window.Window',

    modal: true,
    width: 720,
    bodyPadding: 10,
    scrollable: true,
    maxHeight: 600,

    initComponent: function() {
	let me = this;
	me.title = Ext.String.format(gettext('Array view of {0}'), Ext.htmlEncode(me.storage));
	me.html = gettext('Loading...');
	me.tbar = [{
	    text: gettext('Read array now'),
	    iconCls: 'fa fa-refresh',
	    handler: () => me.load(1),
	}];
	me.callParent();
	me.load(0);
    },

    load: function(refresh) {
	let me = this;
	Proxmox.Utils.API2Request({
	    url: `/nodes/${me.nodename}/san/datastores/${me.storage}/array-view`,
	    method: 'GET',
	    params: { refresh },
	    waitMsgTarget: me,
	    success: response => me.update(me.render(response.result.data)),
	    failure: response => me.update(Ext.htmlEncode(response.htmlStatus)),
	});
    },

    render: function(v) {
	let e = Ext.htmlEncode;
	let size = x => (x === null || x === undefined ? '-' : Proxmox.Utils.render_size(x));
	let out = `<p>${gettext('Array')}: <b>${e(v.array)}</b>, ${gettext('read')} ${Proxmox.Utils.render_timestamp(v.time)}` +
	    (v.cached ? ` (${gettext('cached')})` : '') + '</p>';
	if (v.error) {
	    return out + `<p><i class="fa fa-times critical"></i> ${e(v.error)}</p>`;
	}
	out += `<h3>${gettext('Pools')}</h3><table class="x-grid-item" style="width:100%">` +
	    `<tr><th align="left">${gettext('Pool')}</th><th align="left">${gettext('Capacity')}</th>` +
	    `<th align="left">${gettext('Free')}</th><th align="left">${gettext('Used')}</th></tr>`;
	(v.pools || []).forEach(p => {
	    out += `<tr><td>${e(p.name)}</td><td>${size(p.capacity)}</td><td>${size(p.free)}</td>` +
		`<td>${p.used_pct === null || p.used_pct === undefined ? '-' : p.used_pct + ' %'}</td></tr>`;
	});
	out += `</table><h3>${gettext('Volumes')}</h3><table class="x-grid-item" style="width:100%">` +
	    `<tr><th align="left">${gettext('Volume')}</th><th align="left">${gettext('Provisioned')}</th>` +
	    `<th align="left">${gettext('Written')}</th><th align="left">${gettext('Data reduction')}</th></tr>`;
	(v.volumes || []).forEach(x => {
	    let red = x.reduction ? `${Number(x.reduction).toFixed(1)} : 1`
		: x.saved ? `${size(x.saved)} ${gettext('saved')}` : '-';
	    out += `<tr><td>${e(x.name || x.id)}</td><td>${size(x.provisioned)}</td><td>${size(x.written)}</td><td>${red}</td></tr>`;
	});
	out += `</table><h3>${gettext('Array health')}</h3>`;
	if (!v.health) {
	    out += `<p>${gettext('Not reported by this driver.')}</p>`;
	} else {
	    out += `<p>${PVE.san.Utils.renderState(v.health.status === 'ok' ? 'ok' : v.health.status === 'warning' ? 'degraded' : 'failed')}` +
		` ${e(v.health.status)}</p>`;
	    (v.health.alerts || []).forEach(a => { out += `<p>${e(a.severity)}: ${e(a.summary)}</p>`; });
	}
	return out;
    },
});

Ext.define('PVE.san.HealthGrid', {
    extend: 'Ext.grid.Panel',
    alias: 'widget.pveSanHealthGrid',

    title: gettext('Health'),

    columns: [{ header: gettext('Problem on this node'), dataIndex: 'text', flex: 1 }],
    emptyText: gettext('All datastore LUNs have all their paths.'),

    initComponent: function() {
	let me = this;
	me.store = Ext.create('Ext.data.Store', { fields: ['text'] });
	let api = (url, method, cb) => Proxmox.Utils.API2Request({
	    url: `/nodes/${me.nodename}/san/${url}`,
	    method,
	    waitMsgTarget: me,
	    success: cb,
	    failure: response => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
	});
	me.tbar = [
	    {
		text: gettext('Forget path counts'),
		handler: () => Ext.Msg.confirm(gettext('Confirm'),
		    gettext('Forget the number of paths this node has seen per LUN? Do this after an intended zoning change.'),
		    btn => btn === 'yes' && api('path-health-reset', 'POST', () => me.reload())),
	    },
	    {
		text: gettext('Pool alert threshold'),
		handler: () => api('monitor-settings', 'GET', response => Ext.Msg.prompt(gettext('Pool alert threshold'),
		    gettext('Alert when an array pool is fuller than (%):'),
		    (btn, value) => btn === 'ok' && Proxmox.Utils.API2Request({
			url: `/nodes/${me.nodename}/san/monitor-settings`,
			method: 'PUT',
			params: { 'pool-threshold': value },
			failure: r => Ext.Msg.alert(gettext('Error'), r.htmlStatus),
		    }), me, false, response.result.data['pool-threshold'])),
	    },
	    '->',
	    { text: gettext('Reload'), iconCls: 'fa fa-refresh', handler: () => me.reload() },
	];
	me.callParent();
	me.on('activate', () => me.reload());
	me.reload = () => api('path-health', 'GET',
	    response => me.store.loadData((response.result.data.problems || []).map(text => ({ text }))));
    },
});

Ext.define('PVE.san.IOStatsGrid', {
    extend: 'PVE.san.BaseGrid',
    alias: 'widget.pveSanIOStatsGrid',

    title: gettext('Performance'),
    sanPath: 'iostats',
    stateId: 'grid-pvesan-iostats',
    sanSorters: 'name',

    columns: [
	{ header: gettext('LUN'), dataIndex: 'name', width: 160 },
	{ header: gettext('Datastore'), dataIndex: 'datastore', width: 120 },
	{ header: gettext('Read IOPS'), dataIndex: 'r_iops', width: 90 },
	{ header: gettext('Write IOPS'), dataIndex: 'w_iops', width: 90 },
	{ header: gettext('Read'), dataIndex: 'r_bps', width: 100, renderer: v => Proxmox.Utils.render_size(v) + '/s' },
	{ header: gettext('Write'), dataIndex: 'w_bps', width: 100, renderer: v => Proxmox.Utils.render_size(v) + '/s' },
	{ header: gettext('Read latency'), dataIndex: 'r_lat_ms', width: 100, renderer: v => `${v} ms` },
	{ header: gettext('Write latency'), dataIndex: 'w_lat_ms', width: 100, renderer: v => `${v} ms` },
	{ header: gettext('Busy'), dataIndex: 'util', width: 70, renderer: v => `${v} %` },
	{ header: gettext('In flight'), dataIndex: 'in_flight', width: 70 },
    ],

    initComponent: function() {
	let me = this;
	me.callParent();
	// measured over 2 s on this node; refresh while the tab is shown
	me.on('activate', () => { me.timer = setInterval(() => me.reload(), 10000); });
	me.on('deactivate', () => clearInterval(me.timer));
	me.on('destroy', () => clearInterval(me.timer));
    },
});

// --- storage arrays ---

Ext.define('PVE.san.ArrayEdit', {
    extend: 'Proxmox.window.Edit',

    subject: gettext('Storage array'),
    width: 560,

    initComponent: function() {
	let me = this;
	me.isCreate = !me.arrayId;
	me.method = me.isCreate ? 'POST' : 'PUT';
	me.url = `/nodes/${me.nodename}/san/arrays` + (me.isCreate ? '' : `/${me.arrayId}`);
	let rec = me.record || {};

	let probe = function() {
	    let form = me.down('form').getForm();
	    let address = form.findField('address').getValue();
	    let type = me.isCreate ? form.findField('type').getValue() : rec.type;
	    let port = form.findField('port').getValue() || PVE.san.Utils.arrayTypes[type].port;
	    if (!address) {
		Ext.Msg.alert(gettext('Error'), gettext('Enter the management address first.'));
		return;
	    }
	    Proxmox.Utils.API2Request({
		url: `/nodes/${me.nodename}/san/array-probe`,
		method: 'POST',
		params: { address, port, type },
		waitMsgTarget: me,
		success: function(response) {
		    let c = response.result.data;
		    Ext.Msg.confirm(gettext('Confirm array certificate'),
			`${gettext('Subject')}: ${Ext.htmlEncode(c.subject)}<br>${gettext('Issuer')}: ${Ext.htmlEncode(c.issuer)}<br><br>`
			+ `SHA-256: <code>${Ext.htmlEncode(c.fingerprint)}</code><br><br>`
			+ gettext('Compare this with the certificate fingerprint shown in the array\'s management GUI before trusting it.') + '<br>'
			+ Ext.htmlEncode(PVE.san.Utils.arrayTypes[type].certHint) + '<br><br>' + gettext('Trust it?'),
			btn => btn === 'yes' && form.findField('fingerprint').setValue(c.fingerprint));
		},
		failure: response => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
	    });
	};

	me.items = [{
	    xtype: 'inputpanel',
	    onGetValues: function(values) {
		if (!me.isCreate) {
		    delete values.array;
		    delete values.type;
		    if (!values.password) { delete values.password; }
		    if (values.fingerprint === rec.fingerprint) { delete values.fingerprint; }
		}
		return PVE.san.Utils.joinValues(values);
	    },
	    column1: [
		{ xtype: me.isCreate ? 'textfield' : 'displayfield', name: 'array', fieldLabel: 'ID',
		    value: me.arrayId || '', regex: /^[a-z][a-z0-9_-]{0,31}$/, allowBlank: false, emptyText: 'fs9100' },
		{
		    xtype: 'proxmoxKVComboBox',
		    name: 'type',
		    fieldLabel: gettext('Type'),
		    value: rec.type || 'ibm-sv',
		    disabled: !me.isCreate,
		    comboItems: Object.entries(PVE.san.Utils.arrayTypes).map(([k, v]) => [k, v.name]),
		    listeners: { change: (f, v) => me.applyType(v, true) },
		},
		{ xtype: 'textfield', name: 'address', fieldLabel: gettext('Management address'),
		    value: rec.address || '', allowBlank: false },
		{ xtype: 'proxmoxintegerfield', name: 'port', fieldLabel: gettext('API port'),
		    value: rec.port || 7443, minValue: 1, maxValue: 65535 },
	    ],
	    column2: [
		{ xtype: 'textfield', name: 'username', fieldLabel: gettext('API user'),
		    value: rec.username || '', allowBlank: false },
		{ xtype: 'textfield', name: 'password', inputType: 'password', fieldLabel: gettext('Password'),
		    allowBlank: !me.isCreate, emptyText: me.isCreate ? '' : gettext('unchanged') },
		{ xtype: 'textfield', name: 'hostcluster', fieldLabel: gettext('Host cluster'),
		    value: me.isCreate ? '' : rec.hostcluster, allowBlank: true,
		    emptyText: gettext('Proxmox cluster name') },
		{ xtype: 'textfield', name: 'description', fieldLabel: gettext('Description'),
		    value: rec.description || '', allowBlank: true },
	    ],
	    columnB: [
		{
		    xtype: 'fieldcontainer',
		    itemId: 'vendorOptions',
		    layout: { type: 'table', columns: 2 },
		    defaults: { labelWidth: 120, width: 250, margin: '0 10 5 0' },
		    items: PVE.san.Utils.optionFields.map(f => ({
			xtype: 'textfield',
			name: f.name,
			fieldLabel: f.label,
			emptyText: f.emptyText,
			value: rec[f.name] || '',
			hidden: true,
			allowBlank: true,
		    })),
		},
		{
		    xtype: 'fieldcontainer',
		    fieldLabel: gettext('Certificate'),
		    layout: 'hbox',
		    items: [
			{ xtype: 'textfield', name: 'fingerprint', flex: 1, readOnly: true, value: rec.fingerprint || '',
			    allowBlank: false, emptyText: gettext('fetch and confirm the array certificate') },
			{ xtype: 'button', text: gettext('Fetch'), margin: '0 0 0 5', handler: probe },
		    ],
		},
		{ xtype: 'displayfield', itemId: 'roleHint', userCls: 'pmx-hint', value: '' },
	    ],
	}];
	me.callParent();
	me.applyType(rec.type || 'ibm-sv', false);
    },

    // adapt labels, default port and required fields to the array type
    applyType: function(type, setPort) {
	let me = this;
	let t = PVE.san.Utils.arrayTypes[type];
	if (!t || !me.down('form')) {
	    return;
	}
	let form = me.down('form').getForm();
	let user = form.findField('username');
	user.setHidden(!t.username);
	user.allowBlank = !t.username;
	form.findField('password').setFieldLabel(t.secretLabel);
	if (setPort) {
	    form.findField('port').setValue(t.port);
	}
	let fields = t.fields || {};
	PVE.san.Utils.optionFields.forEach(function(f) {
	    let field = form.findField(f.name);
	    let used = Object.prototype.hasOwnProperty.call(fields, f.name);
	    field.setHidden(!used);
	    field.allowBlank = !(used && fields[f.name]);
	    if (!used && me.isCreate) {
		field.setValue('');
	    }
	});
	me.down('#roleHint').setValue(Ext.htmlEncode(t.roleHint) + ' '
	    + gettext('The secret is stored root-only in /etc/pve/priv. The connection is tested before saving.'));
	form.isValid();
    },
});

Ext.define('PVE.san.ArrayStatus', {
    extend: 'Ext.window.Window',

    title: gettext('Array registration'),
    modal: true,
    width: 820,
    height: 420,
    layout: 'fit',

    initComponent: function() {
	let me = this;
	let store = Ext.create('Ext.data.Store', { fields: ['node', 'registered', 'host', 'hostcluster', 'missing', 'wwpns'] });
	let header = Ext.create('Ext.Component', { padding: 8, html: gettext('Loading...') });

	let load = function() {
	    Proxmox.Utils.API2Request({
		url: `/nodes/${me.nodename}/san/arrays/${me.arrayId}/status`,
		method: 'GET',
		waitMsgTarget: me,
		success: function(response) {
		    let d = response.result.data;
		    header.setHtml(Ext.htmlEncode(`${d.product || ''} ${d.system || ''}, code level ${d.code_level || '?'}`)
			+ '<br>' + Ext.String.format(gettext("Host cluster '{0}': {1}"), Ext.htmlEncode(d.hostcluster),
			    d.hostcluster_exists ? gettext('present') : gettext('missing')));
		    store.loadData(d.nodes);
		},
		failure: response => header.setHtml(`<span class="critical">${response.htmlStatus}</span>`),
	    });
	};

	me.items = [{
	    xtype: 'grid',
	    store,
	    dockedItems: [{ xtype: 'container', dock: 'top', items: [header] }],
	    columns: [
		{ header: gettext('Node'), dataIndex: 'node', width: 120 },
		{ header: gettext('Registered'), dataIndex: 'registered', width: 100,
		    renderer: v => PVE.san.Utils.renderState(v ? 'ok' : 'faulty') },
		{ header: gettext('Array host'), dataIndex: 'host', width: 140 },
		{ header: gettext('Host cluster'), dataIndex: 'hostcluster', width: 130 },
		{ header: gettext('Unregistered ports'), dataIndex: 'missing', flex: 1 },
	    ],
	}];
	me.buttons = [
	    { text: gettext('Reload'), handler: load },
	    {
		text: gettext('Register cluster on array'),
		handler: () => PVE.san.Utils.runTask({
		    url: `/nodes/${me.nodename}/san/arrays/${me.arrayId}/register-cluster`,
		    done: load,
		}),
	    },
	];
	me.callParent();
	load();
    },
});

Ext.define('PVE.san.Provision', {
    extend: 'Proxmox.window.Edit',

    subject: gettext('Datastore from array'),
    isCreate: true,
    method: 'POST',
    showTaskViewer: true,
    width: 640,

    initComponent: function() {
	let me = this;
	me.url = `/nodes/${me.nodename}/san/arrays/${me.arrayId || 'none'}/provision`;

	let pools = Ext.create('Ext.data.Store', {
	    fields: ['name', 'free', 'capacity', {
		name: 'text',
		calculate: d => `${d.name} (${Proxmox.Utils.render_size(d.free)} ${gettext('free')})`,
	    }],
	});
	let loadPools = function(arrayId) {
	    me.url = `/nodes/${me.nodename}/san/arrays/${arrayId}/provision`;
	    pools.removeAll();
	    Proxmox.Utils.API2Request({
		url: `/nodes/${me.nodename}/san/arrays/${arrayId}/pools`,
		method: 'GET',
		success: response => pools.loadData(response.result.data),
		failure: response => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
	    });
	};

	me.items = [{
	    xtype: 'inputpanel',
	    onGetValues: function(values) {
		delete values.array;
		if (values.policy === '__default__') {
		    delete values.policy;
		}
		return PVE.san.Utils.joinValues(values);
	    },
	    column1: [
		{
		    xtype: 'combobox',
		    name: 'array',
		    fieldLabel: gettext('Array'),
		    editable: false,
		    allowBlank: false,
		    queryMode: 'local',
		    valueField: 'array',
		    displayField: 'array',
		    value: me.arrayId,
		    store: {
			autoLoad: true,
			proxy: { type: 'proxmox', url: `/api2/json/nodes/${me.nodename}/san/arrays` },
		    },
		    listeners: { change: (f, v) => v && loadPools(v) },
		},
		{ xtype: 'combobox', name: 'pool', fieldLabel: gettext('Pool'), store: pools, queryMode: 'local',
		    valueField: 'name', displayField: 'text', editable: false, allowBlank: false },
		{ xtype: 'proxmoxintegerfield', name: 'size', fieldLabel: gettext('Size') + ' (GiB)',
		    minValue: 1, value: 1024, allowBlank: false },
		{ xtype: 'proxmoxcheckbox', name: 'thin', fieldLabel: gettext('Thin provisioned'),
		    checked: true, uncheckedValue: 0 },
	    ],
	    column2: [
		{ xtype: 'textfield', name: 'storage', fieldLabel: gettext('Datastore ID'), vtype: 'StorageId', allowBlank: false },
		{ xtype: 'textfield', name: 'volume', fieldLabel: gettext('Volume name'), allowBlank: true,
		    regex: /^[A-Za-z_][A-Za-z0-9_.-]{0,62}$/, emptyText: gettext('same as ID') },
		{ xtype: 'textfield', name: 'label', fieldLabel: gettext('Display name'), allowBlank: true },
		{ xtype: 'pveContentTypeSelector', cts: ['images', 'rootdir'], name: 'content',
		    fieldLabel: gettext('Content'), multiSelect: true, value: ['images', 'rootdir'], allowBlank: false },
		{ xtype: 'proxmoxKVComboBox', name: 'policy', fieldLabel: gettext('Path policy'),
		    value: '__default__', deleteEmpty: false,
		    comboItems: [['__default__', gettext('Vendor recommended')]].concat(PVE.san.Utils.policies) },
	    ],
	    columnB: [{
		xtype: 'displayfield',
		userCls: 'pmx-hint',
		value: gettext('One task: create the volume, map it to the cluster\'s host cluster, rescan every node until the LUN appears, set the path policy and create the shared datastore. If a step fails, the new volume is unmapped and deleted again.'),
	    }],
	}];
	me.callParent();
	if (me.arrayId) {
	    loadPools(me.arrayId);
	}
    },
});

Ext.define('PVE.san.ArrayGrid', {
    extend: 'PVE.san.BaseGrid',
    alias: 'widget.pveSanArrayGrid',

    title: gettext('Arrays'),
    sanPath: 'arrays',
    stateId: 'grid-pvesan-arrays',
    sanSorters: 'array',

    columns: [
	{ header: 'ID', dataIndex: 'array', width: 110 },
	{ header: gettext('Type'), dataIndex: 'type', width: 70 },
	{ header: gettext('Address'), dataIndex: 'address', width: 140 },
	{ header: gettext('System'), dataIndex: 'system', flex: 1 },
	{ header: gettext('Host cluster'), dataIndex: 'hostcluster', width: 130 },
	{ header: gettext('Datastores'), dataIndex: 'datastores', flex: 1 },
	{ header: gettext('Description'), dataIndex: 'description', flex: 1, hidden: true },
    ],

    initComponent: function() {
	let me = this;
	let sm = Ext.create('Ext.selection.RowModel', {});
	me.selModel = sm;
	let rec = () => sm.getSelection()[0].data;
	let after = { destroy: () => me.reload() };

	me.tbar = [
	    {
		text: gettext('Add'),
		iconCls: 'fa fa-plus-circle',
		handler: () => Ext.create('PVE.san.ArrayEdit', { nodename: me.nodename, autoShow: true, listeners: after }),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Edit'), selModel: sm, disabled: true,
		handler: () => Ext.create('PVE.san.ArrayEdit', {
		    nodename: me.nodename, arrayId: rec().array, record: rec(), autoShow: true, listeners: after,
		}),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Registration'), selModel: sm, disabled: true,
		handler: () => Ext.create('PVE.san.ArrayStatus', { nodename: me.nodename, arrayId: rec().array, autoShow: true }),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Zoning'), selModel: sm, disabled: true,
		handler: () => Proxmox.Utils.API2Request({
		    url: me.url(`arrays/${rec().array}/zoning`),
		    method: 'GET',
		    waitMsgTarget: me,
		    success: function(response) {
			let d = response.result.data;
			let rows = (d.adapters || []).map(a => Ext.htmlEncode(`${a.node} ${a.adapter} (${a.adapter_wwpn || '?'}): ${a.seen} / ${a.expected}`));
			let hints = (d.hints || []).map(h => `<i class="fa fa-exclamation-triangle warning"></i> ${Ext.htmlEncode(h)}`);
			Ext.Msg.alert(gettext('Zoning'),
			    Ext.String.format(gettext('Array ports ({0}): {1}'), d.source === 'array' ? gettext('from the array') : gettext('from LUN paths'),
				Ext.htmlEncode(d.expected || '-')) +
			    '<br><br>' + rows.join('<br>') + '<br><br>' + (hints.length ? hints.join('<br>') : gettext('Every adapter reaches every array port.')));
		    },
		    failure: response => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
		}),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Hosts'), selModel: sm, disabled: true,
		handler: function() {
		    let arrayId = rec().array;
		    let win = Ext.create('PVE.san.ListWindow', {
			title: Ext.String.format(gettext('Hosts on array {0}'), Ext.htmlEncode(arrayId)),
			url: `/nodes/${me.nodename}/san/arrays/${arrayId}/hosts`,
			columns: [
			    { header: gettext('Host'), dataIndex: 'host', width: 160 },
			    { header: gettext('Host cluster'), dataIndex: 'hostcluster', width: 130 },
			    { header: 'WWPNs', dataIndex: 'wwpns', flex: 1 },
			    { header: gettext('Removed node'), dataIndex: 'stale', width: 110, renderer: Proxmox.Utils.format_boolean },
			],
			tbar: [{
			    text: gettext('Remove host'),
			    handler: function() {
				let sel = win.grid.getSelection()[0];
				if (!sel || !sel.data.stale) {
				    Ext.Msg.alert(gettext('Error'), gettext('Select a host marked as a removed node.'));
				    return;
				}
				PVE.san.Utils.runTask({
				    url: me.url(`arrays/${arrayId}/remove-host`),
				    params: { host: sel.data.host },
				    done: () => win.grid.getStore().load(),
				});
			    },
			}],
		    });
		    win.show();
		},
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Provision datastore'), iconCls: 'fa fa-magic', selModel: sm, disabled: true,
		handler: () => Ext.create('PVE.san.Provision', {
		    nodename: me.nodename, arrayId: rec().array, autoShow: true, listeners: after,
		}),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Link datastore'), selModel: sm, disabled: true,
		handler: () => Ext.Msg.prompt(gettext('Link datastore'),
		    gettext('ID of an existing datastore whose LUNs are volumes on this array:'),
		    function(btn, storage) {
			if (btn !== 'ok' || !storage) { return; }
			Proxmox.Utils.API2Request({
			    url: me.url(`arrays/${rec().array}/link`),
			    method: 'POST',
			    params: { storage },
			    waitMsgTarget: me,
			    success: () => me.reload(),
			    failure: response => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
			});
		    }),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Remove'), selModel: sm, disabled: true,
		enableFn: r => !r.data.datastores,
		confirmMsg: r => Ext.String.format(gettext('Remove array {0} from pvesan? Nothing on the array is changed.'),
		    Ext.htmlEncode(r.data.array)),
		handler: () => Proxmox.Utils.API2Request({
		    url: me.url(`arrays/${rec().array}`),
		    method: 'DELETE',
		    waitMsgTarget: me,
		    success: () => me.reload(),
		    failure: response => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
		}),
	    },
	];
	me.callParent();
    },
});

// --- array snapshots ---

Ext.define('PVE.san.ScheduleEdit', {
    extend: 'Proxmox.window.Edit',

    subject: gettext('Snapshot schedule'),
    width: 460,

    initComponent: function() {
	let me = this;
	me.url = `/nodes/${me.nodename}/san/datastores/${me.storage}/schedule`;
	me.method = 'PUT';
	me.items = [{
	    xtype: 'inputpanel',
	    onGetValues: function(values) {
		let res = {};
		if (values['snapshot-interval']) {
		    res['snapshot-interval'] = values['snapshot-interval'];
		    res['snapshot-keep'] = values['snapshot-keep'] || 7;
		} else {
		    res.delete = 'snapshot-interval';
		}
		res['auto-reclaim'] = values['auto-reclaim'] ? 1 : 0;
		return res;
	    },
	    items: [
		{ xtype: 'displayfield', fieldLabel: gettext('Datastore'), value: Ext.htmlEncode(me.storage) },
		{ xtype: 'proxmoxintegerfield', name: 'snapshot-interval', fieldLabel: gettext('Snapshot every') + ' (h)',
		    minValue: 0, maxValue: 8760, emptyText: gettext('none') },
		{ xtype: 'proxmoxintegerfield', name: 'snapshot-keep', fieldLabel: gettext('Keep'), minValue: 1, maxValue: 1000,
		    emptyText: '7' },
		{ xtype: 'proxmoxcheckbox', name: 'auto-reclaim', fieldLabel: gettext('Weekly reclaim'), uncheckedValue: 0 },
		{ xtype: 'displayfield', userCls: 'pmx-hint',
		    value: gettext('Scheduled snapshots are named auto-<date>-<time>; only those are removed when more than "Keep" exist. Weekly reclaim sends UNMAP for the free space (needs a thin LUN with UNMAP).') },
	    ],
	}];
	me.callParent();
	me.load({
	    success: function(response) {
		let d = response.result.data;
		me.setValues({
		    'snapshot-interval': d['snapshot-interval'] || '',
		    'snapshot-keep': d['snapshot-keep'] || '',
		    'auto-reclaim': d['auto-reclaim'],
		});
	    },
	});
    },
});

Ext.define('PVE.san.RestoreVM', {
    extend: 'Proxmox.window.Edit',

    subject: gettext('Restore VM from snapshot copy'),
    width: 500,
    isCreate: true,
    showTaskViewer: true,

    initComponent: function() {
	let me = this;
	me.url = `/nodes/${me.nodename}/san/datastores/${me.storage}/restore-vm`;
	me.method = 'POST';
	me.items = [{
	    xtype: 'inputpanel',
	    onGetValues: values => PVE.san.Utils.joinValues(values),
	    items: [
		{ xtype: 'displayfield', fieldLabel: gettext('Copy'), value: Ext.htmlEncode(`${me.storage} (${me.record.copy_of} @ ${me.record.snapshot})`) },
		{ xtype: 'pveGuestIDSelector', name: 'vmid', guestType: 'qemu', isCreate: false, fieldLabel: gettext('VM') },
		{ xtype: 'proxmoxintegerfield', name: 'target-vmid', minValue: 100, maxValue: 999999999, allowBlank: true,
		    fieldLabel: gettext('New VM ID'), emptyText: gettext('restore over the live disks') },
		{ xtype: 'displayfield', userCls: 'pmx-hint',
		    value: gettext('Without a new VM ID the VM must be stopped and its disks on the datastore are overwritten with the snapshot. With a new ID the disks are copied to a new VM whose network links start down.') },
	    ],
	}];
	me.callParent();
    },
});

Ext.define('PVE.san.SnapshotGrid', {
    extend: 'Ext.grid.Panel',
    alias: 'widget.pveSanSnapshotGrid',

    title: gettext('Snapshots'),
    stateful: true,
    stateId: 'grid-pvesan-snapshots',

    columns: [
	{ header: gettext('Name'), dataIndex: 'name', flex: 1 },
	{ header: gettext('Created'), dataIndex: 'created', width: 160, renderer: Proxmox.Utils.render_timestamp },
	{ header: gettext('Size'), dataIndex: 'size', width: 100, renderer: Proxmox.Utils.render_size },
	{ header: gettext('Volumes'), dataIndex: 'volumes', width: 80 },
	{ header: gettext('Scheduled'), dataIndex: 'auto', width: 90, renderer: Proxmox.Utils.format_boolean },
	{ header: gettext('Mounted as'), dataIndex: 'copy', width: 200, renderer: v => Ext.htmlEncode(v || '-') },
    ],

    initComponent: function() {
	let me = this;
	let sm = Ext.create('Ext.selection.RowModel', {});
	me.selModel = sm;
	me.store = Ext.create('Ext.data.Store', { sorters: [{ property: 'created', direction: 'DESC' }] });
	let storage = () => me.down('#dsSelect').getValue();
	let rec = () => sm.getSelection()[0].data;
	let base = suffix => `/nodes/${me.nodename}/san/datastores/${storage()}/${suffix}`;
	let reload = () => me.reload();

	me.tbar = [
	    {
		xtype: 'combobox',
		itemId: 'dsSelect',
		fieldLabel: gettext('Datastore'),
		labelWidth: 70,
		width: 280,
		editable: false,
		queryMode: 'local',
		displayField: 'storage',
		valueField: 'storage',
		store: Ext.create('Ext.data.Store', {
		    proxy: { type: 'proxmox', url: `/api2/json/nodes/${me.nodename}/san/datastores` },
		    filters: [r => !!r.data.array && !r.data.copy_of],
		    autoLoad: true,
		}),
		listeners: { change: reload },
	    },
	    {
		text: gettext('Take snapshot'),
		iconCls: 'fa fa-camera',
		handler: () => {
		    if (!storage()) { return; }
		    Ext.Msg.prompt(gettext('Take snapshot'),
			gettext('Name (empty: pvesan-<date>-<time>). The snapshot is crash-consistent; running VMs are not paused.'),
			function(btn, name) {
			    if (btn !== 'ok') { return; }
			    PVE.san.Utils.runTask({ url: base('snapshots'), params: name ? { name } : {}, done: reload });
			});
		},
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Mount as copy'), selModel: sm, disabled: true,
		enableFn: r => !r.data.copy,
		confirmMsg: r => Ext.String.format(
		    gettext('Clone snapshot {0} on the array and mount it read-only as a new datastore?'), Ext.htmlEncode(r.data.name)),
		handler: () => PVE.san.Utils.runTask({ url: base(`snapshots/${rec().name}/mount`), done: reload }),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Delete'), selModel: sm, disabled: true,
		enableFn: r => !r.data.copy,
		confirmMsg: r => Ext.String.format(gettext('Delete array snapshot {0}?'), Ext.htmlEncode(r.data.name)),
		handler: () => PVE.san.Utils.runTask({ url: base(`snapshots/${rec().name}`), method: 'DELETE', done: reload }),
	    },
	    {
		xtype: 'proxmoxButton', text: gettext('Roll back datastore'), selModel: sm, disabled: true,
		enableFn: r => !r.data.copy,
		handler: () => PVE.san.Utils.confirmTyped(gettext('Roll back datastore'),
		    Ext.String.format(gettext('Restore the whole datastore {0} to snapshot {1}? Every guest on it must be stopped. Everything written since the snapshot is lost.'),
			Ext.htmlEncode(storage()), Ext.htmlEncode(rec().name)),
		    storage(),
		    () => PVE.san.Utils.runTask({
			url: base(`snapshots/${rec().name}/rollback`), params: { confirm: storage() }, done: reload,
		    })),
	    },
	    {
		text: gettext('Schedule'),
		iconCls: 'fa fa-clock-o',
		handler: () => storage() && Ext.create('PVE.san.ScheduleEdit', {
		    nodename: me.nodename, storage: storage(), autoShow: true,
		}),
	    },
	    '->',
	    { text: gettext('Reload'), iconCls: 'fa fa-refresh', handler: reload },
	];
	me.callParent();
	me.on('activate', () => {
	    me.down('#dsSelect').getStore().load();
	    reload();
	});
    },

    reload: function() {
	let me = this;
	let storage = me.down('#dsSelect').getValue();
	if (!storage) {
	    me.store.removeAll();
	    return;
	}
	Proxmox.Utils.API2Request({
	    url: `/nodes/${me.nodename}/san/datastores/${storage}/snapshots`,
	    method: 'GET',
	    success: response => me.store.loadData(response.result.data),
	    failure: response => {
		me.store.removeAll();
		Ext.Msg.alert(gettext('Error'), response.htmlStatus);
	    },
	});
    },
});

Ext.define('PVE.san.ReplicationEnable', {
    extend: 'Proxmox.window.Edit',

    subject: gettext('Replication'),
    width: 480,
    isCreate: true,
    showTaskViewer: true,

    initComponent: function() {
	let me = this;
	me.url = `/nodes/${me.nodename}/san/datastores/${me.storage}/replication`;
	me.method = 'POST';
	me.items = [{
	    xtype: 'inputpanel',
	    onGetValues: values => PVE.san.Utils.joinValues(values),
	    items: [
		{ xtype: 'displayfield', fieldLabel: gettext('Datastore'), value: Ext.htmlEncode(me.storage) },
		{
		    xtype: 'combobox',
		    name: 'partner',
		    fieldLabel: gettext('Partner array'),
		    allowBlank: false,
		    editable: false,
		    queryMode: 'local',
		    displayField: 'name',
		    valueField: 'name',
		    store: Ext.create('Ext.data.Store', {
			proxy: { type: 'proxmox', url: `/api2/json/nodes/${me.nodename}/san/arrays/${me.array}/replication-partners` },
			autoLoad: true,
		    }),
		},
		{ xtype: 'proxmoxintegerfield', name: 'interval', fieldLabel: gettext('Every') + ' (min)', minValue: 5,
		    maxValue: 1440, emptyText: '60' },
		{ xtype: 'proxmoxintegerfield', name: 'retain', fieldLabel: gettext('Keep replicas') + ' (h)', minValue: 1,
		    maxValue: 8760, emptyText: '24' },
		{ xtype: 'displayfield', userCls: 'pmx-hint',
		    value: gettext('Experimental. All volumes of the datastore replicate as one consistent group. The configs of its guests are written onto the datastore every 15 minutes, so the DR site can bring them up.') },
	    ],
	}];
	me.callParent();
    },
});

Ext.define('PVE.san.ReplicationPanel', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveSanReplicationPanel',

    title: gettext('Disaster recovery'),
    layout: { type: 'vbox', align: 'stretch' },

    initComponent: function() {
	let me = this;
	let e = Ext.htmlEncode;
	let ds = () => me.down('#dsSelect').getSelection();
	let storage = () => me.down('#dsSelect').getValue();
	let base = suffix => `/nodes/${me.nodename}/san/datastores/${storage()}/${suffix}`;
	let reload = () => me.loadStatus();

	let repSm = Ext.create('Ext.selection.RowModel', {});
	let rep = () => repSm.getSelection()[0].data;
	let arr = () => me.down('#arraySelect').getValue();
	let repBase = suffix => `/nodes/${me.nodename}/san/arrays/${arr()}/replicas/${encodeURIComponent(rep().replica)}/${suffix}`;
	let repStore = Ext.create('Ext.data.Store', { sorters: 'replica' });
	let loadReplicas = () => {
	    if (!arr()) { repStore.removeAll(); return; }
	    Proxmox.Utils.API2Request({
		url: `/nodes/${me.nodename}/san/arrays/${arr()}/replicas`,
		method: 'GET',
		success: response => repStore.loadData(response.result.data),
		failure: response => { repStore.removeAll(); Ext.Msg.alert(gettext('Error'), response.htmlStatus); },
	    });
	};
	let bringUp = mode => {
	    let r = rep();
	    let test = mode === 'test';
	    Ext.Msg.prompt(test ? gettext('Test failover') : gettext('Failover'),
		(test
		    ? Ext.String.format(gettext('Bring up a copy of {0} ({1}) as datastore {2}-drtest with its guests isolated? Production and replication are not touched.'),
			e(r.replica), e(r.latest || '-'), e(r.storage))
		    : Ext.String.format(gettext('Bring up {0} ({1}) at this site as datastore {2}, with the guests\' identities kept? Make sure the primary site no longer runs them.'),
			e(r.replica), e(r.latest || '-'), e(r.storage))) +
		'<br><br>' + gettext('VM ID offset (empty: keep the IDs):'),
		function(btn, offset) {
		    if (btn !== 'ok') { return; }
		    let params = offset ? { 'vmid-offset': offset } : {};
		    let run = () => PVE.san.Utils.runTask({ url: repBase(mode), params, done: loadReplicas });
		    if (test) {
			run();
		    } else {
			PVE.san.Utils.confirmTyped(gettext('Failover'), gettext('This brings production up at this site.'), r.replica,
			    () => { params.confirm = r.replica; run(); });
		    }
		});
	};

	me.items = [
	    {
		xtype: 'panel',
		itemId: 'status',
		title: gettext('Protected datastore (primary site)'),
		bodyPadding: 10,
		scrollable: true,
		flex: 1,
		html: gettext('Select an array datastore.'),
		tbar: [
		    {
			xtype: 'combobox',
			itemId: 'dsSelect',
			fieldLabel: gettext('Datastore'),
			labelWidth: 70,
			width: 280,
			editable: false,
			queryMode: 'local',
			displayField: 'storage',
			valueField: 'storage',
			store: Ext.create('Ext.data.Store', {
			    proxy: { type: 'proxmox', url: `/api2/json/nodes/${me.nodename}/san/datastores` },
			    filters: [r => !!r.data.array && !r.data.copy_of && r.data.dr !== 'test'],
			    autoLoad: true,
			}),
			listeners: { change: reload },
		    },
		    {
			text: gettext('Enable'),
			iconCls: 'fa fa-exchange',
			handler: () => storage() && Ext.create('PVE.san.ReplicationEnable', {
			    nodename: me.nodename, storage: storage(), array: ds().data.array, autoShow: true,
			    listeners: { destroy: reload },
			}),
		    },
		    {
			text: gettext('Replicate now'),
			iconCls: 'fa fa-upload',
			handler: () => storage() && PVE.san.Utils.runTask({ url: base('replicate'), done: reload }),
		    },
		    {
			text: gettext('Recovery plan'),
			iconCls: 'fa fa-list-ol',
			handler: () => storage() && Ext.Msg.prompt(gettext('Recovery plan'),
			    gettext('Guests in start order, each optionally with seconds to wait before the next: 101:60,102,103 (empty: no plan).'),
			    function(btn, order) {
				if (btn !== 'ok') { return; }
				Proxmox.Utils.API2Request({
				    url: base('recovery-plan'), method: 'PUT', params: { order: order || '' },
				    success: reload,
				    failure: response => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
				});
			    }, me, false, me.lastPlan || ''),
		    },
		    {
			text: gettext('Disable'),
			iconCls: 'fa fa-ban',
			handler: () => storage() && Ext.Msg.confirm(gettext('Disable replication'),
			    Ext.String.format(gettext('Stop replicating {0}? Replicas already on the partner stay there.'), e(storage())),
			    btn => btn === 'yes' && PVE.san.Utils.runTask({ url: base('replication'), method: 'DELETE', done: reload })),
		    },
		    '->',
		    { text: gettext('Reload'), iconCls: 'fa fa-refresh', handler: reload },
		],
	    },
	    {
		xtype: 'grid',
		title: gettext('Replicas on this site\'s array (DR site)'),
		flex: 1,
		store: repStore,
		selModel: repSm,
		emptyText: gettext('No replicated pvesan datastores on this array.'),
		columns: [
		    { header: gettext('Replica'), dataIndex: 'replica', flex: 1 },
		    { header: gettext('Source array'), dataIndex: 'source', width: 120 },
		    { header: gettext('Datastore'), dataIndex: 'storage', width: 120 },
		    { header: gettext('Newest'), dataIndex: 'latest', width: 170 },
		    { header: gettext('Taken'), dataIndex: 'latest-time', width: 150, renderer: Proxmox.Utils.render_timestamp },
		    { header: gettext('Replicas'), dataIndex: 'replicas', width: 80 },
		],
		tbar: [
		    {
			xtype: 'combobox',
			itemId: 'arraySelect',
			fieldLabel: gettext('Array'),
			labelWidth: 50,
			width: 240,
			editable: false,
			queryMode: 'local',
			displayField: 'array',
			valueField: 'array',
			store: Ext.create('Ext.data.Store', {
			    proxy: { type: 'proxmox', url: `/api2/json/nodes/${me.nodename}/san/arrays` },
			    autoLoad: true,
			}),
			listeners: { change: loadReplicas },
		    },
		    {
			xtype: 'proxmoxButton', text: gettext('Test failover'), selModel: repSm, disabled: true,
			handler: () => bringUp('test'),
		    },
		    {
			xtype: 'proxmoxButton', text: gettext('Failover'), selModel: repSm, disabled: true,
			handler: () => bringUp('failover'),
		    },
		    '->',
		    { text: gettext('Reload'), iconCls: 'fa fa-refresh', handler: loadReplicas },
		],
	    },
	];
	me.callParent();
	me.on('activate', () => {
	    me.down('#dsSelect').getStore().load();
	    me.down('#arraySelect').getStore().load();
	});
    },

    loadStatus: function() {
	let me = this;
	let panel = me.down('#status');
	let storage = me.down('#dsSelect').getValue();
	if (!storage) {
	    return;
	}
	let e = Ext.htmlEncode;
	let ts = v => (v ? Proxmox.Utils.render_timestamp(v) : '-');
	Proxmox.Utils.API2Request({
	    url: `/nodes/${me.nodename}/san/datastores/${storage}/replication`,
	    method: 'GET',
	    waitMsgTarget: panel,
	    success: function(response) {
		let s = response.result.data;
		me.lastPlan = s.plan || '';
		let out = s.enabled
		    ? `<p>${gettext('Replicating to')} <b>${e(s.partner)}</b> ${gettext('every')} ${(s.interval || 0) / 60} min, ` +
			`${gettext('replicas kept')} ${(s.retain || 0) / 3600} h (${gettext('array group')} ${e(s.group || '-')})</p>`
		    : `<p>${gettext('Not replicated.')}</p>`;
		out += `<p>${gettext('Newest complete replica')}: ${e(s['last-replica'] || '-')}, ${ts(s['last-completed'])}` +
		    (s.lag !== undefined && s.lag !== null ? ` (${gettext('age')} ${Proxmox.Utils.format_duration_human(s.lag)})` : '') + '</p>';
		if (s['in-progress']) {
		    out += `<p>${gettext('In progress')}: ${e(s['in-progress'])} ${s.progress !== undefined && s.progress !== null ? Math.round(s.progress * 100) + ' %' : ''}</p>`;
		}
		out += `<p>${gettext('Guest configs on the datastore')}: ${ts(s['meta-written'])}` +
		    (s['meta-error'] ? ` <i class="fa fa-times critical"></i> ${e(s['meta-error'])}` : '') + '</p>';
		out += `<p>${gettext('Recovery plan')}: ${e(s.plan || gettext('none (guests are not started automatically)'))}</p>`;
		if (s.error) {
		    out += `<p><i class="fa fa-times critical"></i> ${e(s.error)}</p>`;
		}
		panel.update(out);
	    },
	    failure: response => panel.update(Ext.htmlEncode(response.htmlStatus)),
	});
    },
});

Ext.define('PVE.san.Panel', {
    extend: 'Ext.tab.Panel',
    alias: 'widget.pveSanPanel',

    initComponent: function() {
	let me = this;
	let nodename = me.nodename || me.pveSelNode.data.node;
	me.items = [
	    { xtype: 'pveSanDatastoreGrid', nodename },
	    { xtype: 'pveSanSnapshotGrid', nodename },
	    { xtype: 'pveSanReplicationPanel', nodename },
	    { xtype: 'pveSanArrayGrid', nodename },
	    { xtype: 'pveSanDeviceGrid', nodename },
	    { xtype: 'pveSanPathGrid', nodename },
	    { xtype: 'pveSanAdapterGrid', nodename },
	    { xtype: 'pveSanIOStatsGrid', nodename },
	    { xtype: 'pveSanHealthGrid', nodename },
	];
	me.callParent();
    },
});

// Add the panel to the node's Disks group. PVE.node.Config fills me.items
// and then calls PVE.panel.Config.initComponent, which builds the menu, so
// hooking the parent class lets us append before the menu is built.
// This override runs for every config panel in the GUI, so anything that
// goes wrong here only drops the SAN panel and never the panel itself.
Ext.define('PVE.san.NodeConfigHook', {
    override: 'PVE.panel.Config',

    initComponent: function() {
	let me = this;
	try {
	    if (me.$className === 'PVE.node.Config' && Ext.isArray(me.items) &&
		Ext.ClassManager.getByAlias('widget.pveSanPanel')) {
		let caps = Ext.state.Manager.get('GuiCap');
		let hasStorageGroup = me.items.some(item => item.itemId === 'storage');
		if (caps && caps.nodes['Sys.Audit'] && hasStorageGroup) {
		    me.items.push({
			xtype: 'pveSanPanel',
			title: gettext('SAN / Fibre Channel'),
			itemId: 'pvesan',
			iconCls: 'fa fa-sitemap',
			groups: ['storage'],
			nodename: me.pveSelNode.data.node,
		    });
		}
	    }
	} catch (err) {
	    console.error('pve-fcsan: SAN panel not added', err);
	}
	me.callParent(arguments);
    },
});
