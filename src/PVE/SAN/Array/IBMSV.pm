package PVE::SAN::Array::IBMSV;

# Driver for IBM Spectrum Virtualize / Storage Virtualize arrays
# (FlashSystem 5x00/7x00/9x00, SVC, Storwize) through the REST API on
# port 7443 (code level 8.1.3+).
#
# The REST API wraps the CLI: POST /rest/v1/<command>[/<object>] with the
# command's options as a JSON body. Authentication is a token from
# POST /rest/v1/auth.

use strict;
use warnings;

use JSON::PP;

use base qw(PVE::SAN::Array::Base);

sub description { return 'IBM FlashSystem / Spectrum Virtualize'; }

# multipath-tools queues I/O on these LUNs forever when all paths are gone
sub default_no_path_retry { return 12; }
sub default_port { return 7443; }
sub default_policy { return 'alua'; }

# Background copy rate for copies and restores (FlashCopy -copyrate 1..150).
# 50, Cinder's default, is only 2 MiB/s: a 1 TiB copy would take 6 days.
# 100 is 64 MiB/s; every 10 above doubles it, up to 2 GiB/s at 150.
our $DEFAULT_COPY_RATE = 100;

sub options { return { copy_rate => 0 }; }

sub check_options {
    my ($class, $cfg) = @_;
    $class->SUPER::check_options($cfg);
    my $r = $cfg->{copy_rate};
    die "array setting 'copy-rate' must be a whole number from 1 to 150\n"
        if defined($r) && length($r) && ($r !~ /^\d+$/ || $r < 1 || $r > 150);
}

sub copy_rate {
    my ($self) = @_;
    my $r = $self->{copy_rate};
    return defined($r) && length($r) ? $r + 0 : $DEFAULT_COPY_RATE;
}

sub base_url {
    my ($self) = @_;
    return "https://" . $self->host_port . "/rest/v1";
}

my $json = PVE::SAN::Array::Base::json();
*short = \&PVE::SAN::Array::Base::short;

sub escape_path { return PVE::SAN::Array::Base::escape($_[0]); }

# One POST. Returns (status code, body). Tests inject 'transport' taking
# ($path, $headers, $body).
sub http {
    my ($self, $path, $headers, $body) = @_;
    return $self->{transport}->($path, $headers, $body) if $self->{transport};
    my ($code, $content) = $self->request('POST', "/rest/v1$path", $headers, $body);
    return ($code, $content);
}

sub login {
    my ($self) = @_;

    my ($code, $content) = $self->http('/auth', {
        'X-Auth-Username' => $self->{username},
        'X-Auth-Password' => $self->{password},
    }, undef);
    die "array login to $self->{address} failed (HTTP $code): " . short($content) . "\n" if $code != 200;

    my $data = PVE::SAN::Array::Base::decode($content) // {};
    $self->{token} = $data->{token} // die "array login: no token in response\n";
}

# Run one CLI command. $object is the positional argument (id or name).
sub cmd {
    my ($self, $command, $object, $params) = @_;

    $self->login() if !$self->{token};

    my $path = "/$command" . (defined($object) ? '/' . escape_path($object) : '');
    my ($code, $content);
    for my $attempt (1, 2) {
        ($code, $content) = $self->http($path, { 'X-Auth-Token' => $self->{token} }, $params // {});
        last if $code != 401 && $code != 403;
        last if $attempt == 2;
        $self->login(); # token expired
    }
    die "array command '$command" . (defined($object) ? " $object" : '') . "' failed (HTTP $code): "
        . short($content) . "\n" if $code < 200 || $code >= 300;

    return undef if $content !~ /\S/;
    return PVE::SAN::Array::Base::decode($content) // die "array command '$command': invalid JSON reply\n";
}

sub list {
    my ($self, $command, $params) = @_;
    my $r = $self->cmd($command, undef, $params);
    return ref($r) eq 'ARRAY' ? $r : ($r ? [$r] : []);
}

sub num {
    my ($v) = @_;
    return defined($v) && $v =~ /^\d+$/ ? $v + 0 : undef;
}

# --- read side ---

sub system_info {
    my ($self) = @_;
    my $s = $self->cmd('lssystem');
    return { name => $s->{name}, product => $s->{product_name}, code_level => $s->{code_level}, id => $s->{id} };
}

sub pools {
    my ($self) = @_;
    return [ map {
        { id => $_->{id}, name => $_->{name}, status => $_->{status},
          capacity => num($_->{capacity}), free => num($_->{free_capacity}) }
    } grep { ($_->{type} // 'parent') ne 'child_thin' } @{$self->list('lsmdiskgrp', { bytes => JSON::PP::true })} ];
}

# Detailed lshost replies list ports differently across code levels
# (repeated "WWPN" keys folded into an array, or a "nodes" list of port
# objects). Collect every 16-hex-digit value under a key named WWPN.
sub extract_wwpns {
    my ($data) = @_;
    my %found;
    walk_wwpns($data, \%found);
    return [ sort keys %found ];
}

# iSCSI host ports: "iscsi_name" keys, folded or nested the same way.
sub extract_iqns {
    my ($data) = @_;
    my %found;
    my $walk;
    $walk = sub {
        my ($x) = @_;
        if (ref($x) eq 'HASH') {
            for my $k (keys %$x) {
                my $v = $x->{$k};
                if (lc($k) eq 'iscsi_name') {
                    for my $n (ref($v) eq 'ARRAY' ? @$v : ($v)) {
                        my $q = ref($n) ? undef : PVE::SAN::Array::Base::norm_iqn($n);
                        $found{$q} = 1 if defined($q);
                    }
                } elsif (ref($v)) {
                    $walk->($v);
                }
            }
        } elsif (ref($x) eq 'ARRAY') {
            $walk->($_) for @$x;
        }
    };
    $walk->($data);
    undef $walk;
    return [ sort keys %found ];
}

sub walk_wwpns {
    my ($x, $found) = @_;
    if (ref($x) eq 'HASH') {
        for my $k (keys %$x) {
            my $v = $x->{$k};
            if (lc($k) eq 'wwpn') {
                for my $w (ref($v) eq 'ARRAY' ? @$v : ($v)) {
                    $found->{uc($w)} = 1 if defined($w) && !ref($w) && $w =~ /^[0-9A-Fa-f]{16}$/;
                }
            } elsif (ref($v)) {
                walk_wwpns($v, $found);
            }
        }
    } elsif (ref($x) eq 'ARRAY') {
        walk_wwpns($_, $found) for @$x;
    }
}

sub hosts {
    my ($self) = @_;
    my @res;
    for my $h (@{$self->list('lshost')}) {
        my $detail = $self->cmd('lshost', $h->{id});
        push @res, {
            id => $h->{id},
            name => $h->{name},
            status => $h->{status},
            hostcluster => (defined($h->{host_cluster_name}) && length($h->{host_cluster_name}))
                ? $h->{host_cluster_name} : undef,
            wwpns => extract_wwpns($detail),
            iqns => extract_iqns($detail),
        };
    }
    return \@res;
}

sub host_clusters {
    my ($self) = @_;
    return [ map { { id => $_->{id}, name => $_->{name}, status => $_->{status} } } @{$self->list('lshostcluster')} ];
}

sub volume_from {
    my ($v) = @_;
    my $uid = $v->{vdisk_UID} // '';
    return {
        id => $v->{id},
        name => $v->{name},
        pool => $v->{mdisk_grp_name},
        capacity => num($v->{capacity}),
        uid => $uid,
        wwid => length($uid) ? '3' . lc($uid) : undef, # multipath WWID = NAA designator with type prefix 3
    };
}

sub volume {
    my ($self, $vol) = @_;
    return volume_from($self->cmd('lsvdisk', $vol, { bytes => JSON::PP::true }));
}

sub find_volume_by_wwid {
    my ($self, $wwid) = @_;
    return undef if $wwid !~ /^3([0-9a-f]{32})$/;
    my $uid = uc($1);
    my ($v) = @{$self->list('lsvdisk', { bytes => JSON::PP::true, filtervalue => "vdisk_UID=$uid" })};
    return $v ? volume_from($v) : undef;
}

# --- host registration primitives (see Base::ensure_hostcluster) ---

sub create_hostcluster {
    my ($self, $name) = @_;
    $self->cmd('mkhostcluster', undef, { name => $name });
}

# One kind of port per mkhost / addhostport call: -fcwwpn takes a
# colon-separated list, -iscsiname a comma-separated one (IQNs contain
# colons). force: ports need not be logged in yet (zoning may come later).
sub port_params {
    my ($wwpns, $iqns) = @_;
    my @p;
    push @p, { fcwwpn => join(':', @$wwpns), force => JSON::PP::true } if @$wwpns;
    push @p, { iscsiname => join(',', @$iqns), force => JSON::PP::true } if @{$iqns // []};
    return @p;
}

sub create_host {
    my ($self, $name, $wwpns, $iqns) = @_;
    my ($first, @more) = port_params($wwpns, $iqns);
    $self->cmd('mkhost', undef, { name => $name, %$first });
    $self->cmd('addhostport', $name, $_) for @more;
    return { name => $name, hostcluster => undef, wwpns => [@$wwpns], iqns => [@{$iqns // []}] };
}

sub add_host_ports {
    my ($self, $host, $wwpns, $iqns) = @_;
    $self->cmd('addhostport', $host->{name}, $_) for port_params($wwpns, $iqns);
}

sub add_to_hostcluster {
    my ($self, $hcname, $host) = @_;
    $self->cmd('addhostclustermember', $hcname, { host => $host->{name} });
}

# --- iSCSI targets ---
#
# As OpenStack Cinder's Storwize driver finds them (storwize_svc_common.py
# get_node_info, add_iscsi_ip_addrs): each online node's target name is
# lsnode "iscsi_name"; its portals are lsip -filtervalue portset_name=portset0
# (code level 8.4.2+) or, before, lsportip rows with host=yes and state
# configured/online.

sub supports_iscsi { return 1; }

sub target_portals {
    my ($self) = @_;
    my %iqn = map { $_->{id} => PVE::SAN::Array::Base::norm_iqn($_->{iscsi_name}) }
        grep { ($_->{status} // 'online') eq 'online' } @{$self->list('lsnode')};

    my @ips = map { { node => $_->{node_id}, ip => $_->{IP_address} } }
        @{(eval { $self->list('lsip', { filtervalue => 'portset_name=portset0' }) }) // []};
    if (!@ips) {
        @ips = map { ({ node => $_->{node_id}, ip => $_->{IP_address} }, { node => $_->{node_id}, ip => $_->{IP_address_6} }) }
            grep { ($_->{host} // '') eq 'yes' && ($_->{state} // '') =~ /^(?:configured|online)$/ }
            @{$self->list('lsportip')};
    }
    return [ map { { address => $_->{ip}, port => 3260, iqn => $iqn{$_->{node}} } }
        grep { defined($_->{ip}) && length($_->{ip}) && defined($_->{node}) && $iqn{$_->{node}} } @ips ];
}

# --- volumes ---

# size_gib: whole GiB (Spectrum Virtualize "gb" is binary)
sub create_volume {
    my ($self, %p) = @_;

    die "invalid volume name '$p{name}'\n" if !$self->valid_name($p{name});
    die "size must be a whole number of GiB\n" if $p{size_gib} !~ /^\d+$/ || $p{size_gib} < 1;

    my $r = $self->cmd('mkvolume', undef, {
        name => $p{name},
        pool => $p{pool},
        size => "$p{size_gib}",
        unit => 'gb',
        ($p{thin} ? (thin => JSON::PP::true) : ()),
    });
    my $id = (ref($r) eq 'HASH' ? $r->{id} : undef) // $p{name};
    return $self->volume($id);
}

sub map_to_hostcluster {
    my ($self, $vol, $hcname) = @_;
    $self->cmd('mkvolumehostclustermap', $vol, { hostcluster => $hcname });
}

sub unmap_from_hostcluster {
    my ($self, $vol, $hcname) = @_;
    $self->cmd('rmvolumehostclustermap', $vol, { hostcluster => $hcname });
}

sub delete_volume {
    my ($self, $vol) = @_;
    $self->cmd('rmvolume', $vol);
}

sub expand_volume {
    my ($self, $vol, $add_bytes) = @_;
    die "expansion must be a positive multiple of 512 bytes\n" if $add_bytes <= 0 || $add_bytes % 512;
    $self->cmd('expandvdisksize', $vol, { size => "$add_bytes", unit => 'b' });
}

# --- snapshots (FlashCopy) ---
#
# Checked against the Storwize/SVC driver in OpenStack Cinder
# (cinder/volume/drivers/ibm/storwize_svc/storwize_svc_common.py: mkfcmap,
# prestartfcmap/startfcmap with -restore, mk/prestart/start/stop/rmfcconsistgrp,
# stopfcmap -force, rmfcmap -force, lsfcmap, run_flashcopy, revert_to_snapshot).
#
# A snapshot is a thin target volume "pvs_<source id>_<name>" with a
# FlashCopy mapping at copy rate 0 (no background copy). Several volumes
# go through one FlashCopy consistency group "pvs_<name>_<first id>", which
# starts all mappings at one point in time. A copy is a new thin volume fed
# from the snapshot by a mapping that copies in the background and deletes
# itself when done; a restore is a mapping from the snapshot back onto the
# volume, started with -restore.

sub supports_snapshots { return 1; }
sub supports_group_snapshots { return 1; }

sub snap_volume_name { return "pvs_$_[0]_$_[1]"; }

# lsfcmap start_time: YYMMDDHHMMSS in the array's local time
sub fc_time {
    my ($t) = @_;
    my ($y, $m, $d, $H, $M, $S) = ($t // '') =~ /^(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)$/ or return undef;
    require Time::Local;
    return Time::Local::timelocal($S, $M, $H, $d, $m - 1, 2000 + $y);
}

sub fcmaps {
    my ($self) = @_;
    return $self->list('lsfcmap');
}

sub snapshots {
    my ($self, $vols) = @_;
    my %src = map { $_ => 1 } @$vols;
    my %size;
    my @res;
    for my $m (@{$self->fcmaps()}) {
        my $sid = $m->{source_vdisk_id} // next;
        next if !$src{$sid} || ($m->{copy_rate} // '') ne '0';
        my ($name) = ($m->{target_vdisk_name} // '') =~ /^pvs_\Q$sid\E_(.+)$/ or next;
        $size{$sid} //= eval { $self->volume($sid)->{capacity} };
        push @res, {
            id => $m->{target_vdisk_id},
            name => $name,
            volume => $sid,
            created => fc_time($m->{start_time}),
            size => $size{$sid},
            group => (defined($m->{group_name}) && length($m->{group_name})) ? $m->{group_name} : undef,
            fcmap => $m->{id},
            target => $m->{target_vdisk_name},
        };
    }
    return [ sort { ($a->{created} // 0) <=> ($b->{created} // 0) } @res ];
}

sub fc_status {
    my ($self, $kind, $id) = @_;
    my ($r) = $kind eq 'map'
        ? @{$self->list('lsfcmap', { filtervalue => "id=$id" })}
        : ($self->cmd('lsfcconsistgrp', $id));
    return ($r // {})->{status} // '';
}

# prestart, wait until 'prepared', start (Cinder's _prepare_fc_map / run_flashcopy)
sub run_fc {
    my ($self, $kind, $id, $restore) = @_;
    my ($pre, $start) = $kind eq 'map' ? ('prestartfcmap', 'startfcmap') : ('prestartfcconsistgrp', 'startfcconsistgrp');
    my $opt = $restore ? { restore => JSON::PP::true } : {};
    $self->cmd($pre, $id, $opt);
    for (1 .. 120) {
        my $st = $self->fc_status($kind, $id);
        last if $st eq 'prepared';
        $self->cmd($pre, $id, $opt) if $st eq 'stopped';
        die "FlashCopy $kind $id: unexpected status '$st'\n" if $st ne 'preparing' && $st ne 'stopped';
        sleep(2);
    }
    die "FlashCopy $kind $id did not get prepared in 4 minutes\n" if $self->fc_status($kind, $id) ne 'prepared';
    $self->cmd($start, $id, $opt);
}

sub thin_like {
    my ($self, $src, $name) = @_;
    my $v = ref($src) ? $src : $self->volume($src);
    my $r = $self->cmd('mkvolume', undef, {
        name => $name, pool => $v->{pool}, size => "$v->{capacity}", unit => 'b', thin => JSON::PP::true,
    });
    return $self->volume((ref($r) eq 'HASH' ? $r->{id} : undef) // $name);
}

sub mkfcmap {
    my ($self, $source, $target, %o) = @_;
    my $r = $self->cmd('mkfcmap', undef, {
        source => "$source", target => "$target",
        copyrate => defined($o{copyrate}) ? "$o{copyrate}" : '0',
        ($o{autodelete} ? (autodelete => JSON::PP::true) : ()),
        ($o{consistgrp} ? (consistgrp => $o{consistgrp}) : ()),
    });
    my $id;
    if (ref($r) eq 'HASH') {
        $id = $r->{id};
        ($id) = ($r->{message} // '') =~ /id \[(\d+)\]/ if !defined($id); # "FlashCopy Mapping, id [3], successfully created"
    }
    die "mkfcmap $source -> $target: no mapping id in the reply\n" if !defined($id) || !length($id);
    return $id;
}

sub snapshot_create {
    my ($self, $vols, $name) = @_;
    $self->check_snapshot_args($vols, $name);
    my $cg = @$vols > 1 ? substr("pvs_${name}_$vols->[0]", 0, 63) : undef;
    my (@targets, @maps, $cg_made);
    my $ok = eval {
        if ($cg) {
            $self->cmd('mkfcconsistgrp', undef, { name => $cg });
            $cg_made = 1;
        }
        for my $vol (@$vols) {
            my $t = $self->thin_like($vol, snap_volume_name($vol, $name));
            push @targets, $t;
            push @maps, $self->mkfcmap($vol, $t->{id}, copyrate => 0, consistgrp => $cg);
        }
        $cg ? $self->run_fc('group', $cg) : $self->run_fc('map', $maps[0]);
        1;
    };
    if (!$ok) {
        my $err = $@;
        eval { $self->cmd('rmfcmap', $_, { force => JSON::PP::true }) } for @maps;
        eval { $self->cmd('rmvolume', $_->{id}) } for @targets;
        eval { $self->cmd('rmfcconsistgrp', $cg, { force => JSON::PP::true }) } if $cg_made;
        die $err;
    }
    return [ grep { $_->{name} eq $name } @{$self->snapshots($vols)} ];
}

# A group goes as a whole: every mapping in it, their target volumes, then
# the consistency group.
sub snapshot_delete {
    my ($self, $snap) = @_;
    my @members = $snap->{group}
        ? (grep { ($_->{group_name} // '') eq $snap->{group} } @{$self->fcmaps()})
        : ({ id => $snap->{fcmap}, target_vdisk_id => $snap->{id} });
    for my $m (@members) {
        eval { $self->cmd('stopfcmap', $m->{id}, { force => JSON::PP::true }) };
        $self->cmd('rmfcmap', $m->{id}, { force => JSON::PP::true });
        $self->cmd('rmvolume', $m->{target_vdisk_id});
    }
    $self->cmd('rmfcconsistgrp', $snap->{group}, { force => JSON::PP::true }) if $snap->{group};
}

sub snapshot_clone {
    my ($self, $snap, $name) = @_;
    die "invalid volume name '$name'\n" if !$self->valid_name($name);
    my $c = $self->thin_like($snap->{id}, $name);
    my $map;
    eval {
        $map = $self->mkfcmap($snap->{id}, $c->{id}, copyrate => $self->copy_rate, autodelete => 1);
        $self->run_fc('map', $map);
    };
    if (my $err = $@) {
        eval { $self->cmd('rmfcmap', $map, { force => JSON::PP::true }) } if defined($map);
        eval { $self->cmd('rmvolume', $c->{id}) };
        die $err;
    }
    return $c;
}

sub snapshot_restore {
    my ($self, $vol, $snap) = @_;
    my $v = $self->volume($vol);
    my $s = $self->volume($snap->{id});
    die "volume $vol and snapshot $snap->{name} differ in size - restore refused\n"
        if ($v->{capacity} // 0) != ($s->{capacity} // -1);
    my $map = $self->mkfcmap($snap->{id}, $vol, copyrate => $self->copy_rate, autodelete => 1);
    $self->run_fc('map', $map, 1);
}

1;
