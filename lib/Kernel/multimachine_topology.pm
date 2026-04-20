package Kernel::multimachine_topology;

use strict;
use warnings;

use base 'Exporter';
use Carp qw(croak);
use scheduler 'get_test_suite_data';
use testapi 'get_var';

our @EXPORT_OK = qw(
  get_topology
  get_node_by_role
  get_node_by_addresses
  get_local_node
  get_peers
  get_network_by_id
  get_interface
  get_interface_on_network
  require_field
);

=head1 NAME

Kernel::multimachine_topology - shared multimachine topology reader for test_data

=head1 SYNOPSIS

  use Kernel::multimachine_topology qw(
    get_node_by_role
    get_network_by_id
    get_interface
    require_field
  );

  my $left = get_node_by_role('left');
  my $left_if = get_interface($left, 0);
  my $left_net = get_network_by_id($left_if->{network});

=head1 DESCRIPTION

This module provides a small shared API for tests that consume the
C<multimachine_topology> structure from schedule C<test_data>.

The topology data is expected to be provided by YAML included from the
schedule, for example:

  test_data:
    <<: !include test_data/kernel/multimachine/ipsec_3hosts.yaml

The expected topology shape is:

  multimachine_topology:
    name: ...
    networks:
      - id: ...
    nodes:
      - id: ...
        role: ...
        interfaces:
          - network: ...

This module validates the basic structure, builds lookup indexes, and exposes
helpers for resolving nodes, networks, and interfaces. It is intentionally
limited to reading and validating topology data; it does not configure the
system networking itself.

=cut

=head2 require_field

  my $value = require_field($field, 'field missing');

Return the provided value if it is defined and non-empty. Dies otherwise.

=cut

sub require_field {
    my ($value, $message) = @_;

    croak $message unless defined $value && $value ne '';
    return $value;
}

sub _build_topology_index {
    my ($topology) = @_;
    my $nodes = require_field($topology->{nodes}, 'multimachine_topology nodes missing');
    my $networks = require_field($topology->{networks}, 'multimachine_topology networks missing');

    croak 'multimachine_topology nodes must be an array reference'
      unless ref $nodes eq 'ARRAY';
    croak 'multimachine_topology networks must be an array reference'
      unless ref $networks eq 'ARRAY';

    my (%node_by_id, %node_by_role, %network_by_id);

    for my $node (@$nodes) {
        my $node_id = require_field($node->{id}, 'multimachine_topology node id missing');
        croak "Duplicate multimachine_topology node id '$node_id'" if exists $node_by_id{$node_id};
        $node_by_id{$node_id} = $node;

        if (defined $node->{role} && $node->{role} ne '') {
            my $role = $node->{role};
            croak "Duplicate multimachine_topology node role '$role'" if exists $node_by_role{$role};
            $node_by_role{$role} = $node;
        }

        my $interfaces = require_field($node->{interfaces}, "multimachine_topology interfaces missing for node '$node_id'");
        croak "multimachine_topology interfaces for node '$node_id' must be an array reference"
          unless ref $interfaces eq 'ARRAY';
    }

    for my $network (@$networks) {
        my $network_id = require_field($network->{id}, 'multimachine_topology network id missing');
        croak "Duplicate multimachine_topology network id '$network_id'" if exists $network_by_id{$network_id};
        $network_by_id{$network_id} = $network;
    }

    for my $node (@$nodes) {
        my $node_id = $node->{id};
        for my $interface (@{ $node->{interfaces} }) {
            my $network_id = require_field($interface->{network}, "multimachine_topology interface network missing for node '$node_id'");
            croak "multimachine_topology interface for node '$node_id' references unknown network '$network_id'"
              unless exists $network_by_id{$network_id};
        }
    }

    $topology->{_index} = {
        node_by_id => \%node_by_id,
        node_by_role => \%node_by_role,
        network_by_id => \%network_by_id,
    };

    return $topology;
}

=head2 get_topology

  my $topology = get_topology();

Return the C<multimachine_topology> hashref from C<get_test_suite_data()>.
The structure is validated and indexed on first access.

=cut

sub get_topology {
    my $test_data = get_test_suite_data();
    my $topology = require_field($test_data->{multimachine_topology}, 'multimachine_topology missing from test_data');

    return $topology if $topology->{_index};
    return _build_topology_index($topology);
}

=head2 get_node_by_role

  my $node = get_node_by_role('left');

Return the node hashref for the given role. Dies if the role is missing.

=cut

sub get_node_by_role {
    my ($role) = @_;
    my $topology = get_topology();

    require_field($role, 'multimachine_topology role lookup requires a role');

    my $node = $topology->{_index}{node_by_role}{$role}
      or croak "multimachine_topology node with role '$role' not found";

    return $node;
}

=head2 get_node_by_addresses

  my $node = get_node_by_addresses(
    topology   => $topology,
    ipv4_by_if => $ipv4_by_if,
    ipv6_by_if => $ipv6_by_if,
  );

Return the topology node whose interface addresses match any of the
provided local IPv4 or IPv6 addresses.

The C<ipv4_by_if> and C<ipv6_by_if> arguments are hashrefs in the same
shape as returned by C<Kernel::net_tests::get_ipv4_addresses()> and
C<Kernel::net_tests::get_ipv6_addresses()>.

=cut

sub get_node_by_addresses {
    my (%args) = @_;
    my $topology = $args{topology} // get_topology();
    my $ipv4_by_if = $args{ipv4_by_if} // {};
    my $ipv6_by_if = $args{ipv6_by_if} // {};
    my %local_ipv4 = map { $_ => 1 } map { @$_ } values %{$ipv4_by_if};
    my %local_ipv6 = map { $_ => 1 } map { @$_ } values %{$ipv6_by_if};

    croak 'multimachine_topology address lookup requires a topology hash reference'
      unless ref $topology eq 'HASH';
    croak 'multimachine_topology IPv4 address lookup requires a hash reference'
      unless ref $ipv4_by_if eq 'HASH';
    croak 'multimachine_topology IPv6 address lookup requires a hash reference'
      unless ref $ipv6_by_if eq 'HASH';

    for my $node (@{ $topology->{nodes} }) {
        for my $interface (@{ $node->{interfaces} }) {
            return $node if $interface->{ipv4} && $local_ipv4{$interface->{ipv4}};
            return $node if $interface->{ipv6} && $local_ipv6{$interface->{ipv6}};
        }
    }

    croak 'Unable to resolve node from system addresses against multimachine_topology';
}

=head2 get_local_node

  my $node = get_local_node();
  my $node = get_local_node(role_var => 'IPSEC_SETUP');

Resolve the local node using a job variable that contains the current role.
Defaults to C<ROLE>.

=cut

sub get_local_node {
    my (%args) = @_;
    my $role_var = $args{role_var} // 'ROLE';
    my $role = get_var($role_var);

    if (defined $role && $role ne '') {
        return get_node_by_role($role);
    }

    croak "Unable to resolve local node from job variable '$role_var'";
}

=head2 get_peers

  my $peers = get_peers('left');
  my $peers = get_peers($node);

Return an arrayref containing all nodes except the selected one.

=cut

sub get_peers {
    my ($node_or_role) = @_;
    my $topology = get_topology();
    my $node = ref $node_or_role eq 'HASH' ? $node_or_role : get_node_by_role($node_or_role);
    my $node_id = require_field($node->{id}, 'multimachine_topology node id missing while resolving peers');

    return [grep { $_->{id} ne $node_id } @{ $topology->{nodes} }];
}

=head2 get_network_by_id

  my $network = get_network_by_id('left_net');

Return the network hashref for the given network id. Dies if it is missing.

=cut

sub get_network_by_id {
    my ($network_id) = @_;
    my $topology = get_topology();

    require_field($network_id, 'multimachine_topology network lookup requires an id');

    my $network = $topology->{_index}{network_by_id}{$network_id}
      or croak "multimachine_topology network '$network_id' not found";

    return $network;
}

=head2 get_interface

  my $interface = get_interface($node, 0);

Return the interface hashref at the given index for the specified node.

=cut

sub get_interface {
    my ($node, $index) = @_;

    croak 'multimachine_topology interface lookup requires a node hash reference'
      unless ref $node eq 'HASH';
    croak 'multimachine_topology interface lookup requires an index'
      unless defined $index;

    my $interface = $node->{interfaces}[$index]
      or croak "multimachine_topology interface index '$index' not found for node '$node->{id}'";

    return $interface;
}

=head2 get_interface_on_network

  my $interface = get_interface_on_network($node, 'left_net');

Return the interface hashref for the given node on the selected network.

=cut

sub get_interface_on_network {
    my ($node, $network_id) = @_;

    croak 'multimachine_topology interface lookup requires a node hash reference'
      unless ref $node eq 'HASH';
    require_field($network_id, 'multimachine_topology interface lookup requires a network id');

    for my $interface (@{ $node->{interfaces} }) {
        return $interface if $interface->{network} eq $network_id;
    }

    croak "multimachine_topology interface on network '$network_id' not found for node '$node->{id}'";
}

1;
