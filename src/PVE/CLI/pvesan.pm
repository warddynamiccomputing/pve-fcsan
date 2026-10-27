package PVE::CLI::pvesan;

# 'pvesan' command line tool. Every command maps onto an API method, so the
# CLI, GUI and REST API behave identically.

use strict;
use warnings;

use PVE::CLIFormatter;
use PVE::CLIHandler;
use PVE::INotify;
use PVE::RPCEnvironment;
use PVE::RESTHandler;
use PVE::Tools;

use PVE::API2::SAN;

use base qw(PVE::CLIHandler);

my $nodename = PVE::INotify::nodename();

sub setup_environment {
    PVE::RPCEnvironment->setup_default_cli_env();
}

my $table = sub {
    my (@cols) = @_;
    return sub {
        my ($data, $schema, $options) = @_;
        PVE::CLIFormatter::print_api_result($data, $schema, \@cols, $options);
    };
};

my $print_obj = sub {
    my ($data, $schema, $options) = @_;
    PVE::CLIFormatter::print_api_result($data, $schema, undef, $options);
};

# Cluster actions run as tasks; in the CLI they run in the foreground, but a
# failed task would still exit 0. Exit non-zero so scripts can rely on it.
my $task = sub {
    my ($upid) = @_;
    my $status = PVE::Tools::upid_read_status($upid);
    exit(1) if $status ne 'OK';
};

my $print_array_status = sub {
    my ($data, $schema, $options) = @_;
    if (($options->{'output-format'} // 'text') ne 'text') {
        PVE::CLIFormatter::print_api_result($data, $schema, undef, $options);
        return;
    }
    printf("array %s: %s %s, code level %s\nhost cluster '%s': %s\n\n",
        $data->{array}, $data->{product} // '', $data->{system} // '', $data->{code_level} // '?',
        $data->{hostcluster}, $data->{hostcluster_exists} ? 'present' : 'missing (run register-cluster)');
    printf("%-16s %-10s %-20s %-16s %s\n", 'NODE', 'REGISTERED', 'ARRAY HOST', 'HOST CLUSTER', 'UNREGISTERED PORTS');
    for my $n (@{$data->{nodes}}) {
        printf("%-16s %-10s %-20s %-16s %s\n", $n->{node}, $n->{registered} ? 'yes' : 'NO',
            $n->{host} || '-', $n->{hostcluster} // '-', $n->{missing} || '-');
    }
};

my $fmt = $PVE::RESTHandler::standard_output_options;
my $api = 'PVE::API2::SAN';
my $node = { node => $nodename };

our $cmddef = {
    adapters => [ $api, 'adapters', [], $node,
        $table->(qw(name transport driver model wwpn state speed fabric targets devices paths)), $fmt ],
    'remote-ports' => [ $api, 'remote_ports', [], $node,
        $table->(qw(adapter name wwpn wwnn state roles)), $fmt ],
    devices => [ $api, 'devices', [], $node,
        $table->(qw(name wwid vendor model size status paths_active paths_total policy usage)), $fmt ],
    paths => [ $api, 'paths', [], $node,
        $table->(qw(device dev hctl target_wwpn state dm_state chk_state priority)), $fmt ],
    policies => [ $api, 'policies', [], $node, $table->(qw(policy description)), $fmt ],

    rescan => [ $api, 'rescan', [], $node, $print_obj, $fmt ],
    'rescan-all' => [ $api, 'rescan_all', [], $node, $task ],
    sync => [ $api, 'sync', [], $node, $print_obj, $fmt ],

    device => {
        add => [ $api, 'device_claim', ['wwid'], $node, $task ],
        set => [ $api, 'device_set', ['wwid'], $node, $task ],
        detach => [ $api, 'device_detach', ['wwid'], $node, $task ],
        attach => [ $api, 'device_attach', ['wwid'], $node, $task ],
        refresh => [ $api, 'device_refresh', ['wwid'], $node, $print_obj, $fmt ],
        cleanup => [ $api, 'device_cleanup', [], $node, $print_obj, $fmt ],
    },

    datastore => {
        list => [ $api, 'datastores', [], $node,
            $table->(qw(storage label type vgname size used free enabled active devices)), $fmt ],
        create => [ $api, 'datastore_create', ['storage'], $node, $task ],
        extend => [ $api, 'datastore_extend', ['storage'], $node, $task ],
        rename => [ $api, 'datastore_rename', ['storage'], $node, $task ],
        unmount => [ $api, 'datastore_unmount', ['storage'], $node, $task ],
        mount => [ $api, 'datastore_mount', ['storage'], $node, $task ],
        reclaim => [ $api, 'datastore_reclaim', ['storage'], $node, $task ],
        delete => [ $api, 'datastore_delete', ['storage'], $node, $task ],
        'array-grow' => [ $api, 'datastore_array_grow', ['storage'], $node, $task ],
    },

    array => {
        list => [ $api, 'arrays', [], $node,
            $table->(qw(array type address username hostcluster system datastores)), $fmt ],
        probe => [ $api, 'array_probe', ['address'], $node, $print_obj, $fmt ],
        add => [ $api, 'array_add', ['array'], $node, $print_obj, $fmt ],
        set => [ $api, 'array_update', ['array'], $node ],
        remove => [ $api, 'array_remove', ['array'], $node ],
        status => [ $api, 'array_status', ['array'], $node, $print_array_status, $fmt ],
        pools => [ $api, 'array_pools', ['array'], $node, $table->(qw(name status capacity free)), $fmt ],
        'register-cluster' => [ $api, 'array_register', ['array'], $node, $task ],
        link => [ $api, 'array_link', ['array', 'storage'], $node, $print_obj, $fmt ],
    },

    provision => [ $api, 'array_provision', ['array', 'storage'], $node, $task ],
};

# 'pvesan array add/set --password' prompts instead of taking it on the command line
sub param_mapping {
    my ($name) = @_;
    my $pw = PVE::CLIHandler::get_standard_mapping('pve-password');
    my $mapping = { array_add => [$pw], array_update => [$pw] };
    return $mapping->{$name};
}

1;
