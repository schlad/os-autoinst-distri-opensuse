# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP
# Summary: cgroup v2 helpers for kernel tests.
# Maintainer: Kernel QE <kernel-qa@suse.de>

package Kernel::cgroups;

use base Exporter;
use Exporter;

use strict;
use warnings;
use testapi;

our @EXPORT_OK = qw(
  cgroup_has_controller
  cgroup_create
  cgroup_remove
  cgroup_run
  cgroup_read_keyed
  misc_capacity
  misc_set_max
);

use constant CGROUP_ROOT => '/sys/fs/cgroup';

=head1 SYNOPSIS

cgroup v2 helpers for kernel tests.

Run a command in a child cgroup with a limit of the C<misc> controller,
then read the counters of the cgroup:

 my $cg = cgroup_create('openqa_misc', 'misc');
 misc_set_max($cg, sev => 0);
 my $ret = cgroup_run($cg, './sev_smoke_test', log => '/tmp/sev.log');
 my $events = cgroup_read_keyed($cg, 'misc.events');
 cgroup_remove($cg);

All helpers use the cgroup v2 hierarchy at C</sys/fs/cgroup>. Child
cgroups are created directly below the root cgroup.

=cut

sub _parse_keyed {
    my ($text) = @_;
    my %values;
    for my $line (split /\n/, $text // '') {
        next unless $line =~ /^\s*(\S+)\s+(\S+)\s*$/;
        $values{$1} = $2;
    }
    return \%values;
}

=head2 cgroup_has_controller

 die 'no misc controller' unless cgroup_has_controller('misc');

Returns 1 if C</sys/fs/cgroup> is a cgroup v2 hierarchy and the root
cgroup has the given controller in C<cgroup.controllers>, else 0.

=cut

sub cgroup_has_controller {
    my ($controller) = @_;
    my $root = CGROUP_ROOT;
    return 0 if script_run("test \"\$(stat -fc %T $root)\" = cgroup2fs") != 0;
    my @controllers = split ' ', script_output("cat $root/cgroup.controllers");
    return (grep { $_ eq $controller } @controllers) ? 1 : 0;
}

=head2 cgroup_create

 my $path = cgroup_create($name, @controllers);

Enables the given controllers in C<cgroup.subtree_control> of the root
cgroup, then creates the child cgroup C<$name> below the root cgroup.
Returns the path of the child cgroup. Dies if the child cgroup exists.

=cut

sub cgroup_create {
    my ($name, @controllers) = @_;
    my $root = CGROUP_ROOT;
    my $path = "$root/$name";
    assert_script_run("echo '+$_' > $root/cgroup.subtree_control") for @controllers;
    assert_script_run("mkdir $path");
    return $path;
}

=head2 cgroup_remove

 cgroup_remove($path);

Removes a child cgroup made with C<cgroup_create()>. The cgroup must
not have processes. Does nothing if the cgroup does not exist.

=cut

sub cgroup_remove {
    my ($path) = @_;
    assert_script_run("if test -d $path; then rmdir $path; fi");
}

=head2 cgroup_run

 my $ret = cgroup_run($path, $cmd, log => $file, timeout => 300);

Runs C<$cmd> in the cgroup C<$path> and returns its exit code. The shell
moves itself into the cgroup before it starts C<$cmd>, so all processes
of C<$cmd> are in the cgroup from the start. The output of C<$cmd> goes
to C<log> (default C</dev/null>). C<$cmd> must not contain single quotes.

=cut

sub cgroup_run {
    my ($path, $cmd, %args) = @_;
    my $log = $args{log} // '/dev/null';
    die "Single quotes are not supported in: $cmd" if $cmd =~ /'/;
    return script_run("sh -c 'echo \$\$ > $path/cgroup.procs && exec $cmd' > $log 2>&1",
        timeout => $args{timeout} // 300);
}

=head2 cgroup_read_keyed

 my $values = cgroup_read_keyed($path, 'misc.events');

Reads a flat keyed file of a cgroup, for example C<misc.current>,
C<misc.max>, C<misc.peak> or C<misc.events>. Returns a hash reference of
each key to its value. Values are strings, for example C<max> is a valid
value of C<misc.max>.

=cut

sub cgroup_read_keyed {
    my ($path, $file) = @_;
    return _parse_keyed(script_output("cat $path/$file"));
}

=head2 misc_capacity

 my $capacity = misc_capacity();

Returns a hash reference of each resource of the C<misc> controller to
its capacity on the host, for example C<< {sev => 410, sev_es => 99} >>.
The kernel lists only resources with a capacity higher than 0.

=cut

sub misc_capacity {
    return cgroup_read_keyed(CGROUP_ROOT, 'misc.capacity');
}

=head2 misc_set_max

 misc_set_max($path, sev => 0, sev_es => 'max');

Sets the limit of each given resource in C<misc.max> of the cgroup
C<$path>. A limit is a number or C<max>.

=cut

sub misc_set_max {
    my ($path, %limits) = @_;
    assert_script_run("echo '$_ $limits{$_}' > $path/misc.max") for sort keys %limits;
}

1;
