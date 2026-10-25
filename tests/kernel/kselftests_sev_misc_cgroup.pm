# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP
#
# Summary: Check the cgroup misc controller with the KVM SEV selftest.
#
# Maintainer: Kernel QE <kernel-qa@suse.de>

use Mojo::Base 'opensusebasetest';

use testapi;
use serial_terminal qw(select_serial_terminal);
use Kernel::cgroups qw(cgroup_has_controller cgroup_create cgroup_remove cgroup_run cgroup_read_keyed misc_capacity misc_set_max);

# KVM selftests exit with 254 when a TEST_ASSERT fails
use constant KVM_SELFTEST_ASSERT_FAIL => 254;
use constant EBUSY => 16;

sub check {
    my ($self, $ok, $title, $details) = @_;
    record_info($title, $details, result => $ok ? 'ok' : 'fail');
    $self->result('fail') unless $ok;
}

sub test_resource {
    my ($self, $bin, $res) = @_;

    my $cg = cgroup_create("openqa_misc_$res", 'misc');
    my $has_peak = script_run("test -f $cg/misc.peak") == 0;

    # With a limit of 0, KVM cannot charge an ASID of this type, so
    # KVM_SEV_INIT2 fails with EBUSY and the selftest fails
    misc_set_max($cg, $res => 0);
    my $log = "/tmp/sev_smoke_test-$res-limited.log";
    my $ret = cgroup_run($cg, $bin, log => $log);
    upload_logs($log, failok => 1);
    my $ebusy = script_run("grep -q 'errno=" . EBUSY . " ' $log") == 0;
    my $events = cgroup_read_keyed($cg, 'misc.events')->{"$res.max"} // 0;
    my $current = cgroup_read_keyed($cg, 'misc.current')->{$res} // 0;
    $self->check($ret == KVM_SELFTEST_ASSERT_FAIL && $ebusy, "$res limit 0",
        "sev_smoke_test must fail with EBUSY: exit code $ret, EBUSY in output: " . ($ebusy ? 'yes' : 'no'));
    $self->check($events >= 1, "$res limit 0 event", "misc.events $res.max must be at least 1: $events");
    $self->check($current == 0, "$res limit 0 current", "misc.current $res must be 0: $current");

    # Without a limit, the selftest passes and the ASIDs it used are
    # charged to this cgroup
    misc_set_max($cg, $res => 'max');
    $log = "/tmp/sev_smoke_test-$res-unlimited.log";
    $ret = cgroup_run($cg, $bin, log => $log);
    upload_logs($log, failok => 1);
    my $events_after = cgroup_read_keyed($cg, 'misc.events')->{"$res.max"} // 0;
    $current = cgroup_read_keyed($cg, 'misc.current')->{$res} // 0;
    $self->check($ret == 0, "$res no limit", "sev_smoke_test must pass: exit code $ret");
    $self->check($events_after == $events, "$res no limit event",
        "misc.events $res.max must not change: $events before, $events_after after");
    $self->check($current == 0, "$res no limit current", "misc.current $res must be 0 after the guests exit: $current");
    if ($has_peak) {
        my $peak = cgroup_read_keyed($cg, 'misc.peak')->{$res} // 0;
        $self->check($peak >= 1, "$res no limit peak", "misc.peak $res must be at least 1: $peak");
    }

    cgroup_remove($cg);
}

sub run {
    my ($self) = @_;

    select_serial_terminal;

    unless (cgroup_has_controller('misc')) {
        record_info('SKIP', 'No cgroup v2 misc controller on /sys/fs/cgroup');
        $self->result('skip');
        return;
    }

    my $capacity = misc_capacity();
    record_info('misc.capacity', join("\n", map { "$_ $capacity->{$_}" } sort keys %$capacity) || 'empty');
    my @resources = grep { $capacity->{$_} } qw(sev sev_es);
    unless (@resources) {
        record_info('SKIP', 'No SEV or SEV-ES ASIDs in misc.capacity. Make sure that SEV is enabled in the firmware and that kvm_amd has sev=1.');
        $self->result('skip');
        return;
    }

    # kselftests_prepare installed the selftests in this directory
    my $install = '/lib/modules/$(uname -r)/build/kselftest/kselftest_install';
    my $bin = script_output("find $install -name sev_smoke_test -type f | head -n1");
    die 'sev_smoke_test is not installed, run kselftests_prepare with KSELFTEST_COLLECTION=kvm first' unless $bin;

    $self->test_resource($bin, $_) for @resources;
}

sub post_fail_hook {
    my ($self) = @_;
    script_run("rmdir /sys/fs/cgroup/openqa_misc_$_") for qw(sev sev_es);
    $self->SUPER::post_fail_hook;
}

1;

=head1 Description

Checks the cgroup v2 C<misc> controller with a real resource consumer: the
KVM C<sev_smoke_test> selftest, which starts SEV, SEV-ES and SEV-SNP guests.
KVM charges one ASID to the C<misc> cgroup of the process for each SEV
guest (C<sev> resource) and each SEV-ES or SEV-SNP guest (C<sev_es>
resource).

For each of C<sev> and C<sev_es> with a capacity in C<misc.capacity>, the
module runs C<sev_smoke_test> in a child cgroup two times:

=over

=item * With C<misc.max> 0 for the resource. The test must fail with
C<EBUSY>, C<misc.events> must count the event and C<misc.current> must be
0.

=item * Without a limit. The test must pass, C<misc.events> must not
change, C<misc.current> must be 0 after the guests exit and, if the kernel
has C<misc.peak> (6.11 and later), the peak must be at least 1.

=back

The module skips if there is no C<misc> controller, or if the host has no
SEV or SEV-ES ASIDs. This is the case if SEV is disabled in the firmware.

=head1 Configuration

Schedule the module after C<kselftests_prepare> with
C<KSELFTEST_COLLECTION=kvm>, which builds and installs C<sev_smoke_test>.
The module needs an AMD host with SEV enabled.
