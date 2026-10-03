# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP
# Summary: Set up the network interfaces of the local node of a multimachine topology.
# Maintainer: Kernel QE <kernel-qa@suse.de>

use Mojo::Base 'opensusebasetest';
use testapi;
use serial_terminal 'select_serial_terminal';
use utils 'script_retry';
use Kernel::net_tests qw(add_ipv4_addr add_ipv6_addr get_net_prefix_len);
use Kernel::multimachine_topology qw(get_local_node get_network_by_id require_field);

sub has_addr {
    my ($dev, $family, $ip) = @_;
    return script_run("ip -$family -o addr show dev $dev | grep -qF ' $ip/'") == 0;
}

sub setup_interface {
    my ($node, $interface) = @_;
    my $dev = require_field($interface->{id}, "multimachine_topology interface id missing for node '$node->{id}'");
    my $network = get_network_by_id($interface->{network});
    assert_script_run("ip link set $dev up");
    for my $family (4, 6) {
        my $ip = $interface->{"ipv$family"} or next;
        # A static address is set by the test; any other address comes from
        # the lab network, for example from DHCP, and may take a moment.
        if ($interface->{static} && !has_addr($dev, $family, $ip)) {
            my $cidr = require_field($network->{"ipv${family}_cidr"}, "ipv${family}_cidr missing for network '$network->{id}'");
            my $plen = get_net_prefix_len(net => $cidr) // die "No prefix length in $cidr";
            $family == 4 ? add_ipv4_addr(ip => $ip, dev => $dev, plen => $plen) : add_ipv6_addr(ip => $ip, dev => $dev, plen => $plen);
        }
        script_retry("ip -$family -o addr show dev $dev | grep -qF ' $ip/'", retry => 12, delay => 5,
            fail_message => "$dev of $node->{id} does not have the address $ip");
    }
    return "$dev ($interface->{network}): " . join(' ', grep { defined } @{$interface}{qw(ipv4 ipv6)});
}

sub run {
    select_serial_terminal;
    my $node = get_local_node();
    my @lines = map { setup_interface($node, $_) } @{$node->{interfaces}};
    record_info('Network', "$node->{id} ($node->{role})\n" . join("\n", @lines));
    record_info('ip addr', script_output('ip addr'));
}

sub test_flags {
    return {fatal => 1};
}

1;

=head1 Description

Set up the network interfaces of the local node of a multimachine topology
(see C<Kernel::multimachine_topology>). For each interface of the node,
bring it up, add its addresses if the topology marks it as static, and
check that it has the addresses of the topology.

Schedule it in every job after the installation, before the tests that
use the network.

=head1 Configuration

The interfaces come from C<multimachine_topology> in the schedule
C<test_data>. For each interface of a node:

=over

=item * C<id>: the interface name on the node, for example C<eth2>.

=item * C<network>: the network id; static addresses take the prefix
length from its C<ipv4_cidr> or C<ipv6_cidr>.

=item * C<ipv4>, C<ipv6>: the addresses of the interface; both are
optional.

=item * C<static>: if set, the test adds the addresses. Otherwise the
addresses come from the lab network, for example from DHCP, and the test
only waits for them.

=back

=head2 ROLE

The role of the local node in C<multimachine_topology>.

=cut
