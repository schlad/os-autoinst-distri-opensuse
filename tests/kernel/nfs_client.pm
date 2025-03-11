# SUSE's openQA tests
#
# Copyright 2023 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: NFS Client
#    This module provisions the NFS client and then runs some basic
#    sanity tests
# Maintainer: Kernel QE <kernel-qa@suse.de>

use Mojo::Base "opensusebasetest";
use testapi;
use serial_terminal "select_serial_terminal";
use lockapi;
use utils;

sub run {
    select_serial_terminal();
    record_info("hostname", script_output("hostname"));
    my $server_node = get_var('SERVER_NODE', '10.162.3.82');

    my $local_nfs3 = get_var('NFS_LOCAL_NFS3', '/home/localNFS3');
    my $local_nfs3_async = get_var('NFS_LOCAL_NFS3_ASYNC', '/home/localNFS3async');
    my $local_nfs4 = get_var('NFS_LOCAL_NFS4', '/home/localNFS4');
    my $local_nfs4_async = get_var('NFS_LOCAL_NFS4_ASYNC', '/home/localNFS4async');
    my $multipath = get_var('NFS_MULTIPATH', '0');

    # check kernel config options and set the variables
    my $kernel_nfs3 = 0;
    my $kernel_nfs4 = 0;
    my $kernel_nfs4_1 = 0;
    my $kernel_nfs4_2 = 0;
    my $kernel_nfsd_v3 = 0;
    my $kernel_nfsd_v4 = 0;

    $kernel_nfs3 = 1 unless script_run('zgrep "CONFIG_NFS_V3=[my]" /proc/config.gz');
    $kernel_nfs4 = 1 unless script_run('zgrep "CONFIG_NFS_V4=[my]" /proc/config.gz');
    $kernel_nfs4_1 = 1 unless script_run('zgrep "CONFIG_NFS_V4_1=[my]" /proc/config.gz');
    $kernel_nfs4_2 = 1 unless script_run('zgrep "CONFIG_NFS_V4_2=[my]" /proc/config.gz');
    $kernel_nfsd_v3 = 1 unless script_run('zgrep "CONFIG_NFSD=[my]" /proc/config.gz');
    $kernel_nfsd_v4 = 1 unless script_run('zgrep "CONFIG_NFSD_V4=[my]" /proc/config.gz');


    barrier_wait("NFS_SERVER_ENABLED");
    record_info("showmount", script_output("showmount -e $server_node"));

    if ($kernel_nfs3 == 1) {
        record_info('INFO', 'Kernel has support for NFSv3');
        assert_script_run("mkdir $local_nfs3 $local_nfs3_async");
        assert_script_run("mount -t nfs -o nfsvers=3,sync $server_node:/nfs/shared_nfs3 $local_nfs3");
        assert_script_run("mount -t nfs -o nfsvers=3 $server_node:/nfs/shared_nfs3_async $local_nfs3_async");
    } else {
        record_info('INFO', 'Kernel has no support for NFSv3, skipping NFSv3 tests');
    }

    if ($kernel_nfs4 == 1) {
        record_info('INFO', 'Kernel has support for NFSv4');
        assert_script_run("mkdir $local_nfs4 $local_nfs4_async");
        assert_script_run("mount -t nfs -o nfsvers=4,sync $server_node:/nfs/shared_nfs4 $local_nfs4");
        assert_script_run("mount -t nfs -o nfsvers=4 $server_node:/nfs/shared_nfs4_async $local_nfs4_async");
    } else {
        record_info('INFO', 'Kernel has no support for NFSv4, skipping NFSv4tests');
    }

    barrier_wait("NFS_CLIENT_ENABLED");

    #run basic checks - add a file to each folder and check for the checksum
    #proper tests should come in the next modules
    assert_script_run("dd if=/dev/zero of=testfile bs=1024 count=10240");
    assert_script_run("md5sum testfile > md5sum.txt");

    if ($kernel_nfs3 == 1) {
        assert_script_run("cp testfile md5sum.txt $local_nfs3");
        assert_script_run("cp testfile md5sum.txt $local_nfs3_async");
    }
    if ($kernel_nfs4 == 1) {
        assert_script_run("cp testfile md5sum.txt $local_nfs4");
        assert_script_run("cp testfile md5sum.txt $local_nfs4_async");
    }

    barrier_wait("NFS_SERVER_CHECK");
}

sub test_flags {
    return {fatal => 1, milestone => 1};
}

sub post_fail_hook {
    my ($self) = @_;
    $self->destroy_test_barriers();
    select_serial_terminal;
}

1;
