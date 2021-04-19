# SUSE's openQA tests
#
# Copyright © 2021 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved. This file is offered as-is,
# without any warranty.

# Package: selftests
# Summary: Simplistic kernel selftests runner. Must be run with the
# build_git_kernel module
# Maintainer: Sebastian Chlad <sebastianchlad@gmail.com>

use base 'opensusebasetest';
use strict;
use warnings;
use testapi;
use utils;

sub prepare_prepare_selftests {
}

sub run {
    my $self = shift;
    $self->select_serial_terminal;
}

sub test_flags {
    return {fatal => 1};
}

sub post_fail_hook {
    my ($self) = @_;
    $self->select_serial_terminal;
    $self->export_logs_basic;
    script_run('rpm -qi kernel-default > /tmp/kernel_info');
    upload_logs('/tmp/kernel_info');
}

1;
