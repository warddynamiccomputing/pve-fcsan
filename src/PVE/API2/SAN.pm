package PVE::API2::SAN;

# REST API: /nodes/{node}/san
#
# Read calls and the node-local steps (rescan, sync, refresh, detach-local,
# vg-deactivate) run synchronously on the addressed node. Cluster-wide
# actions fork a worker on the addressed node, which then drives the
# node-local steps on every node.

use strict;
use warnings;

use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;
use PVE::RESTHandler;

use PVE::SAN::Array;
use PVE::SAN::Datastore;
use PVE::SAN::Provision;
use PVE::SAN::Snapshot;
use PVE::SAN::DR;
use PVE::SAN::Inventory;
use PVE::SAN::ISCSI;
use PVE::SAN::Monitor;
use PVE::SAN::Multipath;
use PVE::SAN::Ops;
use PVE::SAN::Util qw(parse_wwid_list normalize_wwid);

use base qw(PVE::RESTHandler);

my $PERM_AUDIT = ['perm', '/nodes/{node}', ['Sys.Audit']];
my $PERM_NODE = ['perm', '/nodes/{node}', ['Sys.Modify']];
my $PERM_CLUSTER = ['and',
    ['perm', '/', ['Sys.Modify']],
    ['perm', '/storage', ['Datastore.Allocate']],
];

my $node_opt = get_standard_option('pve-node');
my $wwid_opt = {
    description => "SCSI WWID of the LUN (multipath WWID, e.g. 3600a0980...; 'naa.' form accepted).",
    type => 'string',
    pattern => '[0-9A-Za-z][0-9A-Za-z_.:-]{7,127}',
};
my $storage_opt = get_standard_option('pve-storage-id');
my $wwid_list_opt = {
    description => "Comma separated list of LUN WWIDs.",
    type => 'string',
    maxLength => 4096,
};
my $nodes_opt = {
    description => "Comma separated list of cluster nodes.",
    type => 'string',
    format => 'pve-node-list',
    optional => 1,
};

my $wwid_param = sub {
    my ($param) = @_;
    return normalize_wwid($param->{wwid}) // die "invalid WWID '$param->{wwid}'\n";
};

my $worker = sub {
    my ($type, $id, $code) = @_;
    my $rpcenv = PVE::RPCEnvironment::get();
    return $rpcenv->fork_worker($type, $id, $rpcenv->get_user(), $code);
};

my $register = sub {
    my ($def) = @_;
    $def->{protected} //= 1; # multipathd, LVM and sysfs writes need root
    $def->{proxyto} //= 'node';
    __PACKAGE__->register_method($def);
};

$register->({
    name => 'index',
    path => '',
    method => 'GET',
    description => "SAN management index.",
    protected => 0,
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'array', items => { type => 'object', properties => { name => { type => 'string' } } } },
    code => sub {
        return [ map { { name => $_ } } qw(adapters array-probe arrays cleanup-paths datastores devices dr-import dr-run iscsi iscsi-login iscsi-restore paths policies reclaim-run remote-ports rescan rescan-all snapshot-run sync) ];
    },
});

$register->({
    name => 'adapters',
    path => 'adapters',
    method => 'GET',
    description => "List FC (and iSCSI) host adapters.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                name => { type => 'string' },
                transport => { type => 'string' },
                driver => { type => 'string', optional => 1 },
                model => { type => 'string', optional => 1 },
                wwpn => { type => 'string', optional => 1, description => 'Port WWN (FC) or initiator IQN (iSCSI).' },
                wwnn => { type => 'string', optional => 1 },
                state => { type => 'string', optional => 1 },
                speed => { type => 'string', optional => 1 },
                fabric => { type => 'string', optional => 1 },
                firmware => { type => 'string', optional => 1 },
                targets => { type => 'integer', optional => 1 },
                devices => { type => 'integer', optional => 1 },
                paths => { type => 'integer', optional => 1 },
                link_failures => { type => 'integer', optional => 1 },
            },
        },
    },
    code => sub { return PVE::SAN::Inventory::adapters(); },
});

$register->({
    name => 'remote_ports',
    path => 'remote-ports',
    method => 'GET',
    description => "List FC remote ports (array target ports) seen by each adapter.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                adapter => { type => 'string' },
                adapter_wwpn => { type => 'string', optional => 1 },
                name => { type => 'string' },
                wwpn => { type => 'string', optional => 1 },
                wwnn => { type => 'string', optional => 1 },
                state => { type => 'string', optional => 1 },
                roles => { type => 'string', optional => 1 },
            },
        },
    },
    code => sub { return PVE::SAN::Inventory::remote_ports(); },
});

$register->({
    name => 'devices',
    path => 'devices',
    method => 'GET',
    description => "List SAN LUNs (storage devices) with path summary and usage.",
    permissions => { check => $PERM_AUDIT },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            all => { type => 'boolean', optional => 1, default => 0,
                description => "Include local disks and array pseudo LUNs." },
            unused => { type => 'boolean', optional => 1, default => 0,
                description => "Only LUNs a datastore can be created on." },
        },
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                wwid => { type => 'string' },
                name => { type => 'string' },
                alias => { type => 'string', optional => 1 },
                vendor => { type => 'string', optional => 1 },
                model => { type => 'string', optional => 1 },
                size => { type => 'integer', renderer => 'bytes' },
                transport => { type => 'string' },
                lun => { type => 'integer' },
                status => { type => 'string' },
                paths_active => { type => 'integer' },
                paths_total => { type => 'integer' },
                policy => { type => 'string' },
                no_path_retry => { type => 'string', optional => 1 },
                usage => { type => 'string' },
                claimed => { type => 'boolean' },
                detached => { type => 'boolean' },
                resize_pending => { type => 'boolean' },
                discard => { type => 'boolean', optional => 1 },
            },
        },
    },
    code => sub {
        my ($param) = @_;
        my $res = PVE::SAN::Inventory::devices(all => $param->{all}, unused => $param->{unused});
        delete $_->{holders} for @$res;
        return $res;
    },
});

$register->({
    name => 'paths',
    path => 'paths',
    method => 'GET',
    description => "List all SCSI paths of SAN LUNs.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                dev => { type => 'string' },
                device => { type => 'string' },
                wwid => { type => 'string' },
                hctl => { type => 'string' },
                lun => { type => 'integer' },
                target_wwpn => { type => 'string', optional => 1 },
                state => { type => 'string', optional => 1 },
                dm_state => { type => 'string', optional => 1 },
                chk_state => { type => 'string', optional => 1 },
                priority => { type => 'integer', optional => 1 },
            },
        },
    },
    code => sub { return PVE::SAN::Inventory::paths(); },
});

$register->({
    name => 'policies',
    path => 'policies',
    method => 'GET',
    description => "List the available path selection policies.",
    protected => 0,
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => {
        type => 'array',
        items => { type => 'object', properties => { policy => { type => 'string' }, description => { type => 'string' } } },
    },
    code => sub {
        my $p = $PVE::SAN::Multipath::POLICIES;
        return [ map { { policy => $_, description => $p->{$_}->{description} } } sort keys %$p ];
    },
});

$register->({
    name => 'rescan',
    path => 'rescan',
    method => 'POST',
    description => "Rescan SAN adapters on this node for new LUNs, paths and LUN size changes.",
    permissions => { check => $PERM_NODE },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            lip => { type => 'boolean', optional => 1, default => 0,
                description => "Issue a FC LIP (fabric re-login) first. Briefly interrupts I/O per port." },
            resize => { type => 'boolean', optional => 1, default => 1,
                description => "Re-read the capacity of existing LUNs." },
        },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Ops::rescan(lip => $param->{lip}, resize => $param->{resize});
    },
});

$register->({
    name => 'rescan_all',
    path => 'rescan-all',
    method => 'POST',
    description => "Rescan SAN adapters on all online cluster nodes.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            lip => { type => 'boolean', optional => 1, default => 0, description => "Issue a FC LIP first." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesanrescan', undef, sub { PVE::SAN::Datastore::rescan_all(lip => $param->{lip}) });
    },
});

$register->({
    name => 'sync',
    path => 'sync',
    method => 'POST',
    description => "Apply the cluster-wide SAN configuration (aliases, policies, claimed and detached LUNs) on this node.",
    permissions => { check => $PERM_NODE },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object', properties => {} },
    code => sub { return PVE::SAN::Ops::sync(); },
});

my $portal_opt = {
    description => "iSCSI target portal: IP address or DNS name, optionally with ':port' (default 3260).",
    type => 'string',
    pattern => '[\[\]0-9A-Za-z.:-]{1,261}',
};
my $target_opt = {
    description => "Target IQN (default: every target the portal offers).",
    type => 'string',
    pattern => '(?:iqn|eui)\.[0-9A-Za-z.:-]{1,219}',
    optional => 1,
};

$register->({
    name => 'iscsi',
    path => 'iscsi',
    method => 'GET',
    description => "This node's iSCSI initiator name, sessions and the target portals pvesan logs in to.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => {
        type => 'object',
        properties => {
            initiator => { type => 'string', optional => 1, description => 'Initiator IQN (/etc/iscsi/initiatorname.iscsi).' },
            installed => { type => 'boolean' },
            sessions => { type => 'array', items => { type => 'object', properties => {} } },
            portals => { type => 'array', items => { type => 'object', properties => {} } },
        },
    },
    code => sub { return PVE::SAN::ISCSI::status(); },
});

$register->({
    name => 'iscsi_login',
    path => 'iscsi-login',
    method => 'POST',
    description => "Discover the targets on an iSCSI portal and log in to them on this node (idempotent, node.startup=automatic). The portal is recorded so every node logs in to it at boot.",
    permissions => { check => $PERM_NODE },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            portal => $portal_opt,
            target => $target_opt,
            array => { type => 'string', pattern => '[a-z][a-z0-9_-]{0,31}', optional => 1,
                description => "Array the portal belongs to (recorded with it)." },
        },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::ISCSI::login(portal => $param->{portal}, target => $param->{target}, array => $param->{array});
    },
});

$register->({
    name => 'iscsi_restore',
    path => 'iscsi-restore',
    method => 'POST',
    description => "Log in to every recorded iSCSI portal this node has no session to (run at boot by pvesan-sync.service).",
    permissions => { check => $PERM_NODE },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object', properties => {} },
    code => sub { return PVE::SAN::ISCSI::restore(); },
});

$register->({
    name => 'device_cleanup',
    path => 'cleanup-paths', # not under devices/: RESTHandler can't mix fixed and {wwid} children
    method => 'POST',
    description => "Remove dead SCSI paths (e.g. after a LUN was unmapped on the array) on this node.",
    permissions => { check => $PERM_NODE },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object', properties => {} },
    code => sub { return PVE::SAN::Ops::cleanup_dead_paths(); },
});

$register->({
    name => 'device_refresh',
    path => 'devices/{wwid}/refresh',
    method => 'POST',
    description => "Re-read the capacity of one LUN on this node and resize its multipath map.",
    permissions => { check => $PERM_NODE },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, wwid => $wwid_opt } },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Ops::refresh_device($wwid_param->($param));
    },
});

$register->({
    name => 'device_detach_local',
    path => 'devices/{wwid}/detach-local',
    method => 'POST',
    description => "Internal step: remove one LUN's map and paths from this node only. Use 'detach' instead.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, wwid => $wwid_opt } },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Ops::detach_device($wwid_param->($param));
    },
});

$register->({
    name => 'vg_deactivate',
    path => 'vg-deactivate',
    method => 'POST',
    description => "Internal step: deactivate all volumes of a volume group on this node.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            vgname => { type => 'string', pattern => '[a-zA-Z0-9\.\+\_][a-zA-Z0-9\.\+\_\-]*' },
        },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Ops::deactivate_vg($param->{vgname});
    },
});

$register->({
    name => 'device_claim',
    path => 'devices/{wwid}/claim',
    method => 'POST',
    description => "Add a LUN: enable multipathing for it on every node (optionally with an alias).",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            wwid => $wwid_opt,
            alias => { type => 'string', optional => 1, pattern => '[A-Za-z][A-Za-z0-9_.+-]{0,63}' },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $wwid = $wwid_param->($param);
        return $worker->('pvesanclaim', $wwid, sub {
            PVE::SAN::Datastore::device_claim(wwid => $wwid, alias => $param->{alias});
        });
    },
});

$register->({
    name => 'device_set',
    path => 'devices/{wwid}',
    method => 'PUT',
    description => "Set alias, path selection policy and no_path_retry of a LUN cluster-wide.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            wwid => $wwid_opt,
            alias => { type => 'string', optional => 1, pattern => '[A-Za-z][A-Za-z0-9_.+-]{0,63}' },
            policy => { type => 'string', optional => 1, enum => PVE::SAN::Multipath::policy_names() },
            'no-path-retry' => { type => 'string', optional => 1, pattern => '(?:\d{1,4}|queue|fail)',
                description => "How long multipath queues I/O when every path is gone: a number of path checks (x 5 s), 'queue' (forever) or 'fail'. Default: the array's entry in multipath-tools' built-in table." },
            delete => { type => 'string', optional => 1, format => 'pve-configid-list',
                description => "Settings to reset (alias, policy, no-path-retry)." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $wwid = $wwid_param->($param);
        return $worker->('pvesandev', $wwid, sub {
            PVE::SAN::Datastore::device_set(wwid => $wwid, (map { $_ => $param->{$_} } qw(alias policy delete)),
                no_path_retry => $param->{'no-path-retry'});
        });
    },
});

$register->({
    name => 'device_detach',
    path => 'devices/{wwid}/detach',
    method => 'POST',
    description => "Detach an unused LUN from all nodes so it can be unmapped on the array safely.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, wwid => $wwid_opt } },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $wwid = $wwid_param->($param);
        return $worker->('pvesandetach', $wwid, sub { PVE::SAN::Datastore::device_detach(wwid => $wwid) });
    },
});

$register->({
    name => 'device_attach',
    path => 'devices/{wwid}/attach',
    method => 'POST',
    description => "Attach a previously detached LUN again on all nodes.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, wwid => $wwid_opt } },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $wwid = $wwid_param->($param);
        return $worker->('pvesanattach', $wwid, sub { PVE::SAN::Datastore::device_attach(wwid => $wwid) });
    },
});

$register->({
    name => 'datastores',
    path => 'datastores',
    method => 'GET',
    description => "List SAN datastores (fcsan storages and LVM storages on multipath LUNs).",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                storage => { type => 'string' },
                type => { type => 'string' },
                label => { type => 'string', optional => 1 },
                vgname => { type => 'string' },
                size => { type => 'integer', optional => 1, renderer => 'bytes' },
                used => { type => 'integer', optional => 1, renderer => 'bytes' },
                free => { type => 'integer', optional => 1, renderer => 'bytes' },
                enabled => { type => 'boolean' },
                active => { type => 'boolean' },
                shared => { type => 'boolean' },
                nodes => { type => 'string', optional => 1 },
                devices => { type => 'string' },
                wwids => { type => 'string' },
                lvs => { type => 'integer', optional => 1 },
                discard => { type => 'boolean' },
                array => { type => 'string', optional => 1 },
                volumes => { type => 'string', optional => 1 },
                copy_of => { type => 'string', optional => 1, description => "Snapshot copy: the datastore it was taken of." },
                snapshot => { type => 'string', optional => 1, description => "Snapshot copy: the snapshot it shows." },
                replication => { type => 'string', optional => 1, description => "Partner array the datastore replicates to." },
                dr => { type => 'string', optional => 1, description => "Brought up from a replica: 'test' or 'failover'." },
            },
        },
    },
    code => sub { return PVE::SAN::Inventory::datastores(); },
});

$register->({
    name => 'datastore_create',
    path => 'datastores',
    method => 'POST',
    description => "Create a shared datastore (LVM volume group + 'fcsan' storage) on one or more LUNs.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => $storage_opt,
            devices => $wwid_list_opt,
            label => { type => 'string', optional => 1, maxLength => 128, description => "Display name." },
            vgname => { type => 'string', optional => 1, pattern => '[a-zA-Z0-9\.\+\_][a-zA-Z0-9\.\+\_\-]*',
                description => "Volume group name (default: san_<storage>)." },
            content => { type => 'string', optional => 1, format => 'pve-storage-content-list',
                description => "Allowed content (default: images,rootdir)." },
            nodes => $nodes_opt,
            saferemove => { type => 'boolean', optional => 1, description => "Zero volumes when they are removed." },
            force => { type => 'boolean', optional => 1, default => 0,
                description => "Wipe existing partition tables or filesystem signatures on the LUNs." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $wwids = parse_wwid_list($param->{devices});
        return $worker->('pvesancreate', $param->{storage}, sub {
            PVE::SAN::Datastore::create(
                %$param,
                devices => $wwids,
                content => ref($param->{content}) ? join(',', @{$param->{content}}) : $param->{content},
            );
        });
    },
});

$register->({
    name => 'datastore_extend',
    path => 'datastores/{storage}/extend',
    method => 'POST',
    description => "Increase datastore capacity: grow into expanded LUNs, or add LUNs as extents.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => $storage_opt,
            'add-devices' => { %$wwid_list_opt, optional => 1, description => "LUNs to add as new extents." },
            devices => { %$wwid_list_opt, optional => 1, description => "Only grow these backing LUNs (default: all)." },
            force => { type => 'boolean', optional => 1, default => 0,
                description => "Wipe signatures on added LUNs." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my %p = (storage => $param->{storage}, force => $param->{force});
        $p{add_devices} = parse_wwid_list($param->{'add-devices'}) if $param->{'add-devices'};
        $p{devices} = parse_wwid_list($param->{devices}) if $param->{devices};
        return $worker->('pvesanextend', $param->{storage}, sub { PVE::SAN::Datastore::extend(%p) });
    },
});

$register->({
    name => 'datastore_rename',
    path => 'datastores/{storage}/rename',
    method => 'POST',
    description => "Rename a datastore: change its display label (online), or its storage ID (guests must be stopped).",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => $storage_opt,
            label => { type => 'string', optional => 1, maxLength => 128 },
            'new-id' => { %{get_standard_option('pve-storage-id')}, optional => 1,
                description => "New storage ID. Guest configs are rewritten." },
            'rename-vg' => { type => 'boolean', optional => 1, default => 0,
                description => "Also rename the volume group to san_<new-id>." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        die "nothing to do - set 'label' and/or 'new-id'\n"
            if !defined($param->{label}) && !defined($param->{'new-id'});
        return $worker->('pvesanrename', $param->{storage}, sub {
            PVE::SAN::Datastore::rename_datastore(
                storage => $param->{storage},
                label => $param->{label},
                new_id => $param->{'new-id'},
                rename_vg => $param->{'rename-vg'},
            );
        });
    },
});

$register->({
    name => 'datastore_unmount',
    path => 'datastores/{storage}/unmount',
    method => 'POST',
    description => "Unmount a datastore from some nodes (removes them from 'nodes') or from all (disables it).",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => { node => $node_opt, storage => $storage_opt, nodes => $nodes_opt },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesanumount', $param->{storage}, sub {
            PVE::SAN::Datastore::unmount(storage => $param->{storage}, nodes => $param->{nodes});
        });
    },
});

$register->({
    name => 'datastore_mount',
    path => 'datastores/{storage}/mount',
    method => 'POST',
    description => "Mount a datastore again (enable it, or add nodes back).",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => { node => $node_opt, storage => $storage_opt, nodes => $nodes_opt },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesanmount', $param->{storage}, sub {
            PVE::SAN::Datastore::mount(storage => $param->{storage}, nodes => $param->{nodes});
        });
    },
});

$register->({
    name => 'datastore_reclaim',
    path => 'datastores/{storage}/reclaim',
    method => 'POST',
    description => "Reclaim free space on thin-provisioned LUNs (SCSI UNMAP of unallocated extents).",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => $storage_opt,
            reserve => { type => 'number', optional => 1, minimum => 0, default => 0,
                description => "GiB of free space left untouched (stays allocatable during the run)." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesanreclaim', $param->{storage}, sub {
            PVE::SAN::Datastore::reclaim(storage => $param->{storage}, reserve => $param->{reserve});
        });
    },
});

$register->({
    name => 'datastore_delete',
    path => 'datastores/{storage}',
    method => 'DELETE',
    description => "Delete a datastore: remove the storage, its volume group and the LVM labels.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => $storage_opt,
            'destroy-data' => { type => 'boolean', optional => 1, default => 0,
                description => "Delete remaining (unreferenced) volumes too." },
            detach => { type => 'boolean', optional => 1, default => 0,
                description => "Detach the LUNs afterwards so they can be unmapped on the array." },
            'delete-volume' => { type => 'boolean', optional => 1, default => 0,
                description => "For array-linked datastores: also unmap and delete the volume(s) on the array." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesandestroy', $param->{storage}, sub {
            if ($param->{'delete-volume'}) {
                PVE::SAN::Provision::destroy(
                    storage => $param->{storage},
                    destroy_data => $param->{'destroy-data'},
                );
            } else {
                PVE::SAN::Datastore::destroy(
                    storage => $param->{storage},
                    destroy_data => $param->{'destroy-data'},
                    detach => $param->{detach},
                );
            }
        });
    },
});

# --- monitoring and health ---

$register->({
    name => 'datastore_array_view',
    path => 'datastores/{storage}/array-view',
    method => 'GET',
    description => "The array's view of an array-linked datastore: pool capacity, volume provisioned and written space, data reduction, array health. Cached in the cluster filesystem and refreshed every 5 minutes.",
    permissions => { check => $PERM_AUDIT },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => $storage_opt,
            refresh => { type => 'boolean', optional => 1, default => 0, description => "Read the array now instead of the cache." },
        },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Monitor::array_view(storage => $param->{storage}, refresh => $param->{refresh});
    },
});

$register->({
    name => 'datastore_guests',
    path => 'datastores/{storage}/guests',
    method => 'GET',
    description => "Guests with disks on a datastore (the vSphere 'Related objects' view).",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, storage => $storage_opt } },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                vmid => { type => 'integer' },
                type => { type => 'string' },
                node => { type => 'string', optional => 1 },
                name => { type => 'string', optional => 1 },
                status => { type => 'string', optional => 1 },
                disks => { type => 'string' },
            },
        },
    },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Monitor::datastore_guests(storage => $param->{storage});
    },
});

$register->({
    name => 'guest_storage',
    path => 'guests/{vmid}',
    method => 'GET',
    description => "Where a guest's disks live: datastore, volume group, LUNs and array volumes.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, vmid => get_standard_option('pve-vmid') } },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                disk => { type => 'string' },
                volume => { type => 'string' },
                size => { type => 'string', optional => 1 },
                type => { type => 'string', optional => 1 },
                vgname => { type => 'string', optional => 1 },
                luns => { type => 'string' },
                wwids => { type => 'string' },
                array => { type => 'string', optional => 1 },
                array_volumes => { type => 'string' },
            },
        },
    },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Monitor::guest_storage(vmid => $param->{vmid});
    },
});

$register->({
    name => 'iostats',
    path => 'iostats',
    method => 'GET',
    description => "I/O rates per multipath LUN on this node, measured over a short interval (block statistics of the device-mapper map).",
    permissions => { check => $PERM_AUDIT },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            interval => { type => 'integer', minimum => 1, maximum => 10, optional => 1, default => 2,
                description => "Measuring interval in seconds." },
        },
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                name => { type => 'string' },
                wwid => { type => 'string' },
                datastore => { type => 'string', optional => 1 },
                r_iops => { type => 'number' },
                w_iops => { type => 'number' },
                r_bps => { type => 'integer', renderer => 'bytes' },
                w_bps => { type => 'integer', renderer => 'bytes' },
                r_lat_ms => { type => 'number' },
                w_lat_ms => { type => 'number' },
                util => { type => 'number' },
                in_flight => { type => 'integer' },
            },
        },
    },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Monitor::iostats(interval => $param->{interval});
    },
});

$register->({
    name => 'path_health',
    path => 'path-health',
    method => 'GET',
    description => "Path check of this node: every LUN of an enabled datastore must be visible with all the paths it had before.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object', properties => {} },
    code => sub {
        my $h = PVE::SAN::Monitor::path_health();
        return { node => $h->{node}, problems => [ map { $h->{problems}->{$_} } sort keys %{$h->{problems}} ],
            expected => $h->{expected} };
    },
});

$register->({
    name => 'path_health_reset',
    path => 'path-health-reset',
    method => 'POST',
    description => "Forget the path counts this node has learned (after an intended zoning or path change).",
    permissions => { check => $PERM_NODE },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object', properties => {} },
    code => sub { return PVE::SAN::Monitor::reset_expected(); },
});

$register->({
    name => 'monitor_run',
    path => 'monitor-run',
    method => 'POST',
    description => "Check paths on this node and, on one node, read the arrays and send alerts (called by pvesan-monitor.timer).",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object', properties => {} },
    code => sub { return PVE::SAN::Monitor::run(); },
});

$register->({
    name => 'monitor_get',
    path => 'monitor-settings',
    method => 'GET',
    description => "Cluster-wide monitoring settings.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object', properties => {} },
    code => sub { return { 'pool-threshold' => PVE::SAN::Monitor::pool_threshold() }; },
});

$register->({
    name => 'monitor_set',
    path => 'monitor-settings',
    method => 'PUT',
    description => "Set cluster-wide monitoring settings.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            'pool-threshold' => { type => 'integer', minimum => 1, maximum => 100, optional => 1,
                description => "Alert when an array pool is fuller than this (percent, default 85)." },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;
        PVE::SAN::Config::update(sub {
            my ($cfg) = @_;
            $cfg->{monitor}->{pool_threshold} = $param->{'pool-threshold'} if defined($param->{'pool-threshold'});
        });
        return undef;
    },
});

# --- storage arrays ---

my $array_opt = {
    description => "Array ID.",
    type => 'string',
    pattern => '[a-z][a-z0-9_-]{0,31}',
};

my $array_conn_props = {
    address => { type => 'string', format => 'address', description => "Management IP or DNS name." },
    port => { type => 'integer', minimum => 1, maximum => 65535, optional => 1,
        description => "Management API port (default: the array type's API port, e.g. 7443 for IBM, 5665 for Fujitsu ETERNUS, 443 for most others)." },
    username => { type => 'string', maxLength => 64, optional => 1,
        description => "API user (IBM, InfiniBox). Not used for Pure, where the API token identifies the user." },
    password => { type => 'string', maxLength => 512,
        description => "API password, or the API token for Pure. Stored in /etc/pve/priv." },
    fingerprint => { type => 'string', pattern => 'sha256\$[0-9a-fA-F]{64}',
        description => "Pinned SHA-256 TLS certificate fingerprint (from array-probe)." },
    hostcluster => { type => 'string', optional => 1, pattern => '[A-Za-z0-9_][A-Za-z0-9_.-]{0,64}',
        description => "Host cluster (host group on Pure) for this Proxmox cluster (default: the cluster name)." },
    description => { type => 'string', optional => 1, maxLength => 256 },
    'system-id' => { type => 'string', optional => 1, pattern => '[A-Za-z0-9_.-]{1,64}',
        description => "Array system ID: PowerMax Symmetrix ID (required), E-Series storage system ID (default 1), Hitachi storage device ID (default: the only one)." },
    svm => { type => 'string', optional => 1, pattern => '[A-Za-z0-9_.-]{1,64}',
        description => "NetApp ONTAP: SVM that owns the LUNs and the igroup (required)." },
    portgroup => { type => 'string', optional => 1, pattern => '[A-Za-z0-9_-]{1,64}',
        description => "Dell PowerMax: existing port group of the array FC ports zoned to the cluster (required)." },
    srp => { type => 'string', optional => 1, pattern => '[A-Za-z0-9_-]{1,64}',
        description => "Dell PowerMax: storage resource pool for the cluster's storage group (default SRP_1)." },
    slo => { type => 'string', optional => 1, pattern => '[A-Za-z0-9_-]{1,32}',
        description => "Dell PowerMax: service level for the cluster's storage group (default: none / Optimized)." },
    'target-ports' => { type => 'string', optional => 1, pattern => '[A-Za-z0-9-]+(?:,[A-Za-z0-9-]+)*',
        description => "Hitachi VSP: array FC ports zoned to the cluster, e.g. CL1-A,CL2-A (required)." },
    'auto-register' => { type => 'boolean', optional => 1,
        description => "Register new cluster nodes' ports on this array automatically (default 1)." },
    protocol => { type => 'string', enum => ['fc', 'iscsi', 'both'], optional => 1,
        description => "Node ports registered on the array: FC WWPNs (fc, default), the iSCSI initiator name (iscsi) or both. iSCSI registration logs every node in to the array's target portals." },
};

$register->({
    name => 'array_probe',
    path => 'array-probe',
    method => 'POST',
    description => "Read an array's TLS certificate fingerprint so it can be confirmed and pinned.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            address => $array_conn_props->{address},
            port => $array_conn_props->{port},
            type => { type => 'string', enum => PVE::SAN::Array::types(), optional => 1, default => 'ibm-sv',
                description => "Array type (picks the default port)." },
        },
    },
    returns => { type => 'object', properties => {
        fingerprint => { type => 'string' }, subject => { type => 'string' }, issuer => { type => 'string' },
    } },
    code => sub {
        my ($param) = @_;
        my $port = $param->{port} // PVE::SAN::Array::default_port($param->{type} // 'ibm-sv');
        return PVE::SAN::Array::probe_certificate($param->{address}, $port);
    },
});

$register->({
    name => 'arrays',
    path => 'arrays',
    method => 'GET',
    description => "List configured storage arrays.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                array => { type => 'string' },
                type => { type => 'string' },
                address => { type => 'string' },
                username => { type => 'string' },
                hostcluster => { type => 'string' },
                system => { type => 'string', optional => 1 },
                datastores => { type => 'string', optional => 1 },
            },
        },
    },
    code => sub { return PVE::SAN::Array::list(); },
});

$register->({
    name => 'array_add',
    path => 'arrays',
    method => 'POST',
    description => "Add a storage array. The connection and credentials are tested before saving.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            array => $array_opt,
            type => { type => 'string', enum => PVE::SAN::Array::types(), default => 'ibm-sv', optional => 1 },
            %$array_conn_props,
        },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Provision::array_add(%$param, type => $param->{type} // 'ibm-sv');
    },
});

$register->({
    name => 'array_update',
    path => 'arrays/{array}',
    method => 'PUT',
    description => "Change an array's settings or credentials.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            array => $array_opt,
            (map { $_ => { %{$array_conn_props->{$_}}, optional => 1 } } keys %$array_conn_props),
            delete => { type => 'string', optional => 1, pattern => '[a-z][a-z0-9-]*(?:,[a-z][a-z0-9-]*)*',
                description => "Settings to remove (hostcluster, description, vendor settings)." },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;
        PVE::SAN::Provision::array_update(%$param);
        return undef;
    },
});

$register->({
    name => 'array_remove',
    path => 'arrays/{array}',
    method => 'DELETE',
    description => "Remove an array from pvesan (nothing on the array is changed).",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, array => $array_opt } },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;
        PVE::SAN::Provision::array_remove(array => $param->{array});
        return undef;
    },
});

$register->({
    name => 'array_status',
    path => 'arrays/{array}/status',
    method => 'GET',
    description => "Array system info and how each node is registered (hosts, ports, host cluster).",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, array => $array_opt } },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Provision::array_status(array => $param->{array});
    },
});

$register->({
    name => 'array_pools',
    path => 'arrays/{array}/pools',
    method => 'GET',
    description => "List the array's storage pools.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, array => $array_opt } },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                name => { type => 'string' },
                status => { type => 'string', optional => 1 },
                capacity => { type => 'integer', optional => 1, renderer => 'bytes' },
                free => { type => 'integer', optional => 1, renderer => 'bytes' },
            },
        },
    },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Array::driver($param->{array})->pools();
    },
});

$register->({
    name => 'array_register',
    path => 'arrays/{array}/register-cluster',
    method => 'POST',
    description => "Create or update host objects for every node's FC ports and/or iSCSI initiator name (array setting 'protocol') and put them in the cluster's host cluster. For iSCSI, every node then logs in to the array's target portals.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, array => $array_opt } },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesanregister', $param->{array}, sub {
            PVE::SAN::Provision::register_cluster(array => $param->{array});
        });
    },
});

$register->({
    name => 'array_iscsi_login',
    path => 'arrays/{array}/iscsi-login',
    method => 'POST',
    description => "Log every online node in to the array's iSCSI target portals (from the array, or the given portals) and record them for boot.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            array => $array_opt,
            portals => { type => 'string', optional => 1, pattern => '[\[\]0-9A-Za-z.:-]+(?:[,; ]+[\[\]0-9A-Za-z.:-]+)*',
                description => "Portals to use instead of the ones the array reports (comma separated, address[:port])." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesaniscsi', $param->{array}, sub {
            PVE::SAN::Provision::iscsi_login(array => $param->{array}, portals => $param->{portals});
        });
    },
});

$register->({
    name => 'array_provision',
    path => 'arrays/{array}/provision',
    method => 'POST',
    description => "Create a volume on the array, map it to the cluster, rescan all nodes and create a datastore on it.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            array => $array_opt,
            storage => $storage_opt,
            pool => { type => 'string', maxLength => 65, description => "Array pool ('default' on Pure FlashArray)." },
            size => { type => 'integer', minimum => 1, description => "Size in GiB." },
            thin => { type => 'boolean', optional => 1, default => 1,
                description => "Thin-provisioned volume (Pure volumes are always thin)." },
            volume => { type => 'string', optional => 1, pattern => '[A-Za-z0-9_][A-Za-z0-9_.-]{0,64}',
                description => "Volume name on the array (default: the storage ID, adapted to the array's naming rules)." },
            label => { type => 'string', optional => 1, maxLength => 128 },
            content => { type => 'string', optional => 1, format => 'pve-storage-content-list' },
            policy => { type => 'string', optional => 1, enum => PVE::SAN::Multipath::policy_names(),
                description => "Path policy for the new LUN (default: the vendor recommendation - alua for IBM, array-default for Pure and InfiniBox)." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesanprovision', $param->{storage}, sub {
            PVE::SAN::Provision::provision(%$param, thin => $param->{thin} // 1);
        });
    },
});

$register->({
    name => 'array_link',
    path => 'arrays/{array}/link',
    method => 'POST',
    description => "Link an existing datastore to the array volumes that back it.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => { node => $node_opt, array => $array_opt, storage => $storage_opt },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Provision::link_datastore(array => $param->{array}, storage => $param->{storage});
    },
});

$register->({
    name => 'array_zoning',
    path => 'arrays/{array}/zoning',
    method => 'GET',
    description => "Zoning hints: which of the array's FC target ports each node's adapters are logged in to.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, array => $array_opt } },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Monitor::zoning(array => $param->{array});
    },
});

$register->({
    name => 'array_hosts',
    path => 'arrays/{array}/hosts',
    method => 'GET',
    description => "Hosts in the cluster's host cluster on the array; 'stale' marks hosts of nodes no longer in the cluster.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, array => $array_opt } },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                host => { type => 'string' },
                hostcluster => { type => 'string', optional => 1 },
                wwpns => { type => 'string' },
                stale => { type => 'boolean' },
            },
        },
    },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Monitor::array_hosts(array => $param->{array});
    },
});

$register->({
    name => 'array_remove_host',
    path => 'arrays/{array}/remove-host',
    method => 'POST',
    description => "Remove the host of a node that has left the cluster from the host cluster and delete it on the array.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            array => $array_opt,
            host => { type => 'string', maxLength => 128, description => "Array host name (see 'hosts')." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesanremovehost', $param->{array}, sub {
            PVE::SAN::Monitor::remove_stale_host(array => $param->{array}, host => $param->{host});
        });
    },
});

$register->({
    name => 'datastore_array_grow',
    path => 'datastores/{storage}/array-grow',
    method => 'POST',
    description => "Grow an array-linked datastore: expand the array volume, then the datastore.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => $storage_opt,
            size => { type => 'integer', minimum => 1, description => "New total volume size in GiB." },
            volume => { type => 'string', optional => 1, description => "Volume (if the datastore has several)." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesanarraygrow', $param->{storage}, sub {
            PVE::SAN::Provision::grow(storage => $param->{storage}, size => $param->{size}, volume => $param->{volume});
        });
    },
});

# --- array snapshots of datastores ---

my $snapname_opt = {
    description => "Snapshot name (letters, digits and '-', starting with a letter).",
    type => 'string',
    pattern => '[A-Za-z][A-Za-z0-9-]{0,39}',
};

$register->({
    name => 'snapshots',
    path => 'datastores/{storage}/snapshots',
    method => 'GET',
    description => "List the array snapshots of an array-linked datastore (one entry per snapshot set).",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, storage => $storage_opt } },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                name => { type => 'string' },
                created => { type => 'integer', optional => 1, renderer => 'timestamp' },
                size => { type => 'integer', optional => 1, renderer => 'bytes' },
                volumes => { type => 'integer' },
                complete => { type => 'boolean' },
                auto => { type => 'boolean', description => "Taken by the snapshot schedule." },
                copy => { type => 'string', optional => 1, description => "Datastore this snapshot is mounted as." },
            },
        },
    },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Snapshot::list(storage => $param->{storage});
    },
});

$register->({
    name => 'snapshot_create',
    path => 'datastores/{storage}/snapshots',
    method => 'POST',
    description => "Take an array snapshot of every volume of the datastore at one point in time (crash-consistent).",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => { node => $node_opt, storage => $storage_opt, name => { %$snapname_opt, optional => 1,
            description => "Snapshot name (default: pvesan-<date>-<time>)." } },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesansnapshot', $param->{storage}, sub {
            PVE::SAN::Snapshot::create(storage => $param->{storage}, name => $param->{name});
        });
    },
});

$register->({
    name => 'snapshot_delete',
    path => 'datastores/{storage}/snapshots/{name}',
    method => 'DELETE',
    description => "Delete an array snapshot of the datastore.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => { node => $node_opt, storage => $storage_opt, name => $snapname_opt },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesansnapdel', $param->{storage}, sub {
            PVE::SAN::Snapshot::remove(storage => $param->{storage}, name => $param->{name});
        });
    },
});

$register->({
    name => 'snapshot_mount',
    path => 'datastores/{storage}/snapshots/{name}/mount',
    method => 'POST',
    description => "Mount a snapshot as a separate, read-only copy datastore: clone it on the array, map the clone and import its volume group under a new name.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => $storage_opt,
            name => $snapname_opt,
            copy => { %{get_standard_option('pve-storage-id')}, optional => 1,
                description => "Storage ID of the copy (default: <storage>-snap-<date>-<time>)." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesansnapmount', $param->{storage}, sub {
            PVE::SAN::Snapshot::mount_copy(storage => $param->{storage}, name => $param->{name}, copy => $param->{copy});
        });
    },
});

$register->({
    name => 'snapshot_rollback',
    path => 'datastores/{storage}/snapshots/{name}/rollback',
    method => 'POST',
    description => "Restore the whole datastore in place from an array snapshot. Every guest on it must be stopped; the volume group is deactivated on all nodes first. Everything written since the snapshot is lost.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => $storage_opt,
            name => $snapname_opt,
            confirm => { type => 'string', description => "The datastore's storage ID, as confirmation." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesanrollback', $param->{storage}, sub {
            PVE::SAN::Snapshot::rollback(storage => $param->{storage}, name => $param->{name}, confirm => $param->{confirm});
        });
    },
});

$register->({
    name => 'copy_remove',
    path => 'datastores/{storage}/remove-copy',
    method => 'POST',
    description => "Remove a mounted snapshot copy: its storage, volume group and clone volume(s) on the array.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, storage => $storage_opt } },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesancopyremove', $param->{storage}, sub {
            PVE::SAN::Snapshot::remove_copy(storage => $param->{storage});
        });
    },
});

$register->({
    name => 'copy_restore_vm',
    path => 'datastores/{storage}/restore-vm',
    method => 'POST',
    description => "Restore a VM's disks from a mounted snapshot copy: over the live disks (VM stopped), or into a new VM ID.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => { %$storage_opt, description => "The snapshot copy datastore." },
            vmid => get_standard_option('pve-vmid'),
            'target-vmid' => { %{get_standard_option('pve-vmid')}, optional => 1,
                description => "Restore into this new VM ID instead of over the live disks." },
            'target-storage' => { %{get_standard_option('pve-storage-id')}, optional => 1,
                description => "Storage for the new VM's disks (default: the original datastore)." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        die "'target-storage' needs 'target-vmid'\n" if $param->{'target-storage'} && !$param->{'target-vmid'};
        return $worker->('pvesanrestorevm', $param->{vmid}, sub {
            PVE::SAN::Snapshot::restore_vm(
                storage => $param->{storage},
                vmid => $param->{vmid},
                target_vmid => $param->{'target-vmid'},
                target_storage => $param->{'target-storage'},
            );
        });
    },
});

my $schedule_props = {
    'snapshot-interval' => { type => 'integer', minimum => 0, maximum => 8760, optional => 1,
        description => "Take an array snapshot every N hours (0 = no schedule)." },
    'snapshot-keep' => { type => 'integer', minimum => 1, maximum => 1000, optional => 1,
        description => "Scheduled snapshots to keep (default 7); manual snapshots are never removed." },
    'auto-reclaim' => { type => 'boolean', optional => 1,
        description => "Reclaim free space (UNMAP) once a week." },
};

$register->({
    name => 'schedule_get',
    path => 'datastores/{storage}/schedule',
    method => 'GET',
    description => "Snapshot schedule and weekly reclaim setting of a datastore, with the last run.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, storage => $storage_opt } },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Snapshot::get_schedule(storage => $param->{storage});
    },
});

$register->({
    name => 'schedule_set',
    path => 'datastores/{storage}/schedule',
    method => 'PUT',
    description => "Set the snapshot schedule and the weekly reclaim of a datastore.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => $storage_opt,
            %$schedule_props,
            delete => { type => 'string', optional => 1, pattern => '(?:snapshot-interval|auto-reclaim)(?:,(?:snapshot-interval|auto-reclaim))*',
                description => "Settings to remove." },
        },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::Snapshot::set_schedule(
            storage => $param->{storage},
            interval => $param->{'snapshot-interval'},
            keep => $param->{'snapshot-keep'},
            auto_reclaim => $param->{'auto-reclaim'},
            delete => $param->{delete},
        );
    },
});

# --- replication and disaster recovery (experimental) ---

my $replica_opt = {
    description => "Replica on the DR array, as 'pvesan dr replicas' lists it (e.g. SOURCE:pvesan-gold).",
    type => 'string',
    pattern => '[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}',
};
my $vmid_offset_opt = {
    type => 'integer', minimum => 0, maximum => 900_000_000, optional => 1,
    description => "Add this to every guest's VM ID (when the IDs are taken at this site).",
};
my $start_opt = { type => 'boolean', optional => 1, description => "Start the guests in recovery plan order." };

$register->({
    name => 'replication_partners',
    path => 'arrays/{array}/replication-partners',
    method => 'GET',
    description => "Arrays this array has a replication connection to.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, array => $array_opt } },
    returns => { type => 'array', items => { type => 'object', properties => {
        name => { type => 'string' }, status => { type => 'string', optional => 1 }, type => { type => 'string', optional => 1 } } } },
    code => sub { return PVE::SAN::DR::partners(array => $_[0]->{array}); },
});

$register->({
    name => 'replication_get',
    path => 'datastores/{storage}/replication',
    method => 'GET',
    description => "Replication state of a datastore: partner, newest complete replica and its age, transfer in progress.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, storage => $storage_opt } },
    returns => { type => 'object', properties => {} },
    code => sub { return PVE::SAN::DR::status(storage => $_[0]->{storage}); },
});

$register->({
    name => 'replication_enable',
    path => 'datastores/{storage}/replication',
    method => 'POST',
    description => "Replicate the datastore's array volumes to a partner array as one consistent group, and keep its guest configs on the datastore.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => $storage_opt,
            partner => { type => 'string', pattern => '[A-Za-z0-9][A-Za-z0-9_.-]{0,62}',
                description => "Partner array, by the name this array knows it as (see replication-partners)." },
            interval => { type => 'integer', minimum => 5, maximum => 1440, optional => 1,
                description => "Replicate every N minutes (default 60)." },
            retain => { type => 'integer', minimum => 1, maximum => 8760, optional => 1,
                description => "Keep replicas on the partner for N hours (default 24)." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesanrepl', $param->{storage}, sub {
            PVE::SAN::DR::enable(storage => $param->{storage}, partner => $param->{partner},
                interval => $param->{interval}, retain => $param->{retain});
        });
    },
});

$register->({
    name => 'replication_disable',
    path => 'datastores/{storage}/replication',
    method => 'DELETE',
    description => "Stop replicating the datastore. Replicas already on the partner stay there.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, storage => $storage_opt } },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesanrepldel', $param->{storage}, sub { PVE::SAN::DR::disable(storage => $param->{storage}); });
    },
});

$register->({
    name => 'replicate_now',
    path => 'datastores/{storage}/replicate',
    method => 'POST',
    description => "Refresh the guest configs on the datastore and send a replica now.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => $storage_opt,
            name => { %$snapname_opt, optional => 1, description => "Replica name (default: dr-<date>-<time>)." },
            wait => { type => 'boolean', optional => 1, description => "Wait until the partner has received it." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesanreplnow', $param->{storage}, sub {
            PVE::SAN::DR::replicate(storage => $param->{storage}, name => $param->{name}, wait => $param->{wait});
        });
    },
});

$register->({
    name => 'dr_meta_write',
    path => 'datastores/{storage}/dr-meta',
    method => 'POST',
    description => "Write the configs of the datastore's guests and its recovery plan onto the datastore now.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, storage => $storage_opt } },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesandrmeta', $param->{storage}, sub { PVE::SAN::DR::write_meta(storage => $param->{storage}); });
    },
});

$register->({
    name => 'recovery_plan_get',
    path => 'datastores/{storage}/recovery-plan',
    method => 'GET',
    description => "Recovery plan of a datastore: the order its guests start in at the DR site.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, storage => $storage_opt } },
    returns => { type => 'array', items => { type => 'object', properties => {
        order => { type => 'integer' }, vmid => { type => 'integer' }, delay => { type => 'integer' }, type => { type => 'string' } } } },
    code => sub { return PVE::SAN::DR::get_plan(storage => $_[0]->{storage}); },
});

$register->({
    name => 'recovery_plan_set',
    path => 'datastores/{storage}/recovery-plan',
    method => 'PUT',
    description => "Set the recovery plan of a datastore.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => $storage_opt,
            order => { type => 'string', pattern => '(?:\d+(?::\d+)?(?:,\d+(?::\d+)?)*)?', maxLength => 4096,
                description => "Guests in start order, each optionally with the seconds to wait before the next one: '101:60,102,103'. Empty removes the plan." },
        },
    },
    returns => { type => 'array', items => { type => 'object', properties => {} } },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::DR::set_plan(storage => $param->{storage}, order => $param->{order});
    },
});

$register->({
    name => 'prepare_failover',
    path => 'datastores/{storage}/prepare-failover',
    method => 'POST',
    description => "Planned failover, primary site: stop the datastore's guests, write their configs, unmount the datastore on every node and send a final replica.",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => $storage_opt,
            confirm => { type => 'string', description => "The datastore's storage ID, as confirmation." },
            shutdown => { type => 'boolean', optional => 1, description => "Shut running guests down (reverse plan order)." },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesandrprep', $param->{storage}, sub {
            PVE::SAN::DR::prepare_failover(storage => $param->{storage}, confirm => $param->{confirm},
                shutdown => $param->{shutdown});
        });
    },
});

$register->({
    name => 'replicas',
    path => 'arrays/{array}/replicas',
    method => 'GET',
    description => "Datastores replicated to this (DR) array, with their newest complete replica.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, array => $array_opt } },
    returns => { type => 'array', items => { type => 'object', properties => {
        replica => { type => 'string' },
        source => { type => 'string', optional => 1 },
        storage => { type => 'string', description => "Storage ID a failover would use." },
        replicas => { type => 'integer' },
        latest => { type => 'string', optional => 1 },
        'latest-time' => { type => 'integer', optional => 1, renderer => 'timestamp' },
        age => { type => 'integer', optional => 1, renderer => 'duration' },
        volumes => { type => 'integer', optional => 1 },
    } } },
    code => sub { return PVE::SAN::DR::replica_list(array => $_[0]->{array}); },
});

$register->({
    name => 'replica_snapshots',
    path => 'arrays/{array}/replicas/{replica}/snapshots',
    method => 'GET',
    description => "Complete replica snapshots of one replica, oldest first.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, array => $array_opt, replica => $replica_opt } },
    returns => { type => 'array', items => { type => 'object', properties => {
        name => { type => 'string' },
        created => { type => 'integer', optional => 1, renderer => 'timestamp' },
        completed => { type => 'integer', optional => 1, renderer => 'timestamp' },
        volumes => { type => 'integer' },
    } } },
    code => sub {
        my ($param) = @_;
        return PVE::SAN::DR::replica_snapshot_list(array => $param->{array}, replica => $param->{replica});
    },
});

my $bring_up_props = {
    node => $node_opt,
    array => $array_opt,
    replica => $replica_opt,
    snapshot => { type => 'string', optional => 1, pattern => '[A-Za-z0-9][A-Za-z0-9-]{0,63}',
        description => "Replica snapshot to use (default: the newest complete one)." },
    storage => { %{get_standard_option('pve-storage-id')}, optional => 1,
        description => "Storage ID to bring the datastore up as (default: the original ID; '<ID>-drtest' for a test)." },
    'vmid-offset' => $vmid_offset_opt,
    start => $start_opt,
};

$register->({
    name => 'dr_test',
    path => 'arrays/{array}/replicas/{replica}/test',
    method => 'POST',
    description => "Test failover: bring a copy of a replica up under a new name with its guests isolated (new MACs, links down). Production and replication are not touched; remove it with dr-cleanup.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => $bring_up_props },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesandrtest', $param->{replica}, sub {
            PVE::SAN::DR::from_replica(mode => 'test', array => $param->{array}, replica => $param->{replica},
                snapshot => $param->{snapshot}, storage => $param->{storage},
                vmid_offset => $param->{'vmid-offset'}, start => $param->{start});
        });
    },
});

$register->({
    name => 'dr_failover',
    path => 'arrays/{array}/replicas/{replica}/failover',
    method => 'POST',
    description => "Failover: bring a replica up at this site as the datastore, with its guests' identities kept. Make sure the primary site no longer runs them.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => {
        %$bring_up_props,
        confirm => { type => 'string', description => "The replica's name, as confirmation." },
    } },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        die "confirm with the replica's name ('$param->{replica}') to fail over\n" if ($param->{confirm} // '') ne $param->{replica};
        return $worker->('pvesandrfailover', $param->{replica}, sub {
            PVE::SAN::DR::from_replica(mode => 'failover', array => $param->{array}, replica => $param->{replica},
                snapshot => $param->{snapshot}, storage => $param->{storage},
                vmid_offset => $param->{'vmid-offset'}, start => $param->{start});
        });
    },
});

$register->({
    name => 'dr_import',
    path => 'dr-import',
    method => 'POST',
    description => "Bring up a replicated datastore from LUNs already presented to this cluster (promoted on the array by hand; works with any array).",
    permissions => { check => $PERM_CLUSTER },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            storage => $storage_opt,
            wwids => $wwid_list_opt,
            test => { type => 'boolean', optional => 1, description => "Bring it up as an isolated test copy." },
            'vmid-offset' => $vmid_offset_opt,
            start => $start_opt,
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $wwids = parse_wwid_list($param->{wwids});
        return $worker->('pvesandrimport', $param->{storage}, sub {
            PVE::SAN::DR::import_luns(storage => $param->{storage}, wwids => $wwids,
                mode => $param->{test} ? 'test' : 'failover', vmid_offset => $param->{'vmid-offset'}, start => $param->{start});
        });
    },
});

$register->({
    name => 'dr_run_plan',
    path => 'datastores/{storage}/run-plan',
    method => 'POST',
    description => "Start the guests of a datastore brought up from a replica, in recovery plan order.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, storage => $storage_opt } },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesandrplan', $param->{storage}, sub { PVE::SAN::DR::run_plan(storage => $param->{storage}); });
    },
});

$register->({
    name => 'dr_cleanup',
    path => 'datastores/{storage}/dr-cleanup',
    method => 'POST',
    description => "Remove a test failover: stop and remove its guests, the datastore and the copied array volumes.",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, storage => $storage_opt } },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        return $worker->('pvesandrclean', $param->{storage}, sub { PVE::SAN::DR::cleanup(storage => $param->{storage}); });
    },
});

# Entry points for the systemd timers; they run on every node and the
# cluster-wide claim picks one node per job.
$register->({
    name => 'dr_run',
    path => 'dr-run',
    method => 'POST',
    description => "Refresh due DR metadata of replicated datastores (called by pvesan-dr.timer).",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object', properties => {} },
    code => sub { return PVE::SAN::DR::run_meta_sync(); },
});

$register->({
    name => 'snapshot_run',
    path => 'snapshot-run',
    method => 'POST',
    description => "Run due scheduled snapshots (called by pvesan-snapshot.timer).",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object', properties => {} },
    code => sub { return PVE::SAN::Snapshot::run_snapshot_schedules(); },
});

$register->({
    name => 'reclaim_run',
    path => 'reclaim-run',
    method => 'POST',
    description => "Run due weekly space reclaims (called by pvesan-reclaim.timer).",
    permissions => { check => $PERM_CLUSTER },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object', properties => {} },
    code => sub { return PVE::SAN::Snapshot::run_reclaim(); },
});

1;
