# SUSE's openQA tests
#
# Copyright 2026 SUSE LLC
# SPDX-License-Identifier: FSFAP

package Kernel::nfs;

use strict;
use warnings;
use Exporter 'import';
use version_utils 'is_transactional';

our @EXPORT_OK = qw(nfs_client_mount nfs_server_export);

sub nfs_server_export {
    my ($name) = @_;
    return is_transactional ? "/var/lib/nfs-tests/server/$name" : "/nfs/$name";
}

sub nfs_client_mount {
    my ($name) = @_;
    return is_transactional ? "/var/lib/nfs-tests/client/$name" : "/home/$name";
}

1;
