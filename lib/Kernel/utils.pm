# SUSE's openQA tests
#
# Copyright 2026 SUSE LLC
# SPDX-License-Identifier: FSFAP
# Summary: Generic kernel-related helpers shared across kernel test modules.
# Maintainer: Kernel QE <kernel-qa@suse.de>

package Kernel::utils;

use base Exporter;
use Exporter;

use strict;
use warnings;
use testapi;
use utils 'systemctl';

our @EXPORT_OK = qw(
  is_debugfs_mounted
  enable_debugfs
  has_driver
  record_driver_support
);

=head2 is_debugfs_mounted

 is_debugfs_mounted();

Checks whether debugfs is mounted at /sys/kernel/debug, same check as
blktests' C<_have_debugfs()>. Returns true/false.

=cut

sub is_debugfs_mounted {
    return script_run('findmnt -t debugfs /sys/kernel/debug') == 0;
}

=head2 enable_debugfs

 enable_debugfs();

Mounts debugfs at /sys/kernel/debug (e.g. on SLE 16.1+, where it is
disabled by default per PED-8812).

=cut

sub enable_debugfs {
    record_info('debugfs', 'debugfs not mounted, enabling sys-kernel-debug.mount');
    systemctl('enable --now sys-kernel-debug.mount');
}

=head2 has_driver

 has_driver($module);

Checks whether the given kernel module/driver is available, either already
loaded or loadable via modprobe - same check as blktests' C<_have_driver()>.

=cut

sub has_driver {
    my ($module) = @_;
    return script_run("test -d /sys/module/$module || modprobe -q $module") == 0;
}

=head2 record_driver_support

 record_driver_support(@patterns);

Probes kernel modules/drivers matching each given name or glob pattern
(e.g. C<raid*>) with C<has_driver()> and records a yes/no summary under a
single log entry, for visibility before running tests that depend on
specific drivers (e.g. blktests md RAID personalities).

A pattern is matched against module files found under
F</lib/modules/$(uname -r)> on the SUT.

=cut

sub record_driver_support {
    my (@patterns) = @_;
    my @modules = map { /[*?]/ ? _find_modules($_) : $_ } @patterns;

    record_info('driver support',
        join("\n", map { "$_: " . (has_driver($_) ? 'yes' : 'no') } @modules));
}

# Finds module basenames under /lib/modules/$(uname -r) on the SUT matching
# the given glob pattern (e.g. "raid*"), via find's own -iname matching.
sub _find_modules {
    my ($pattern) = @_;

    my $out = script_output(
        qq{find /lib/modules/\$(uname -r) -iname '$pattern.ko*' | xargs -n1 basename | sed -E 's/\\.ko.*\$//' | sort -u},
        proceed_on_failure => 1
    );
    return split(/\n/, $out // '');
}

1;
