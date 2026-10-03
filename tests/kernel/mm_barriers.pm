# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP
# Summary: Create the barriers of a multimachine topology.
# Maintainer: Kernel QE <kernel-qa@suse.de>

use Mojo::Base 'opensusebasetest';
use testapi;
use lockapi;
use scheduler 'get_test_suite_data';
use Kernel::multimachine_topology qw(get_local_node get_job_nodes);

sub run {
    my $barriers = get_test_suite_data()->{multimachine_barriers};
    die 'multimachine_barriers missing from test_data' unless ref $barriers eq 'ARRAY' && @$barriers;
    my $nodes = get_job_nodes();
    my $creator = $nodes->[0]{id};
    if (get_local_node()->{id} ne $creator) {
        record_info('Barriers', "Created by $creator");
        return;
    }
    my $tasks = scalar @$nodes;
    barrier_create($_, $tasks) for @$barriers;
    record_info('Barriers', "Created for $tasks jobs:\n" . join("\n", @$barriers));
}

sub test_flags {
    return {fatal => 1};
}

1;

=head1 Description

Create the barriers of a multimachine test from C<test_data>, for any
number of nodes. Schedule this module first in every job of the setup,
before the installation, so that the barriers exist before any job waits
on them.

The first node of C<multimachine_topology> that runs a job creates the
barriers, for as many tasks as there are nodes that run a job (see
C<get_job_nodes> in C<Kernel::multimachine_topology>). External nodes do
not take part. The other jobs do nothing.

=head1 Configuration

The schedule provides the barrier names in C<test_data>, next to the
topology:

  test_data:
    multimachine_barriers:
      - PEER_READY
      - TRAFFIC_DONE
    multimachine_topology:
      ...

=head2 ROLE

The role of the local node in C<multimachine_topology>.

=cut
