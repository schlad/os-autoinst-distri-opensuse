# SUSE's openQA tests
#
# Copyright 2026 SUSE LLC
# SPDX-License-Identifier: FSFAP
#
# Summary: CVE-2026-43284 / DirtyFrag regression harness for IPsec jobs.
#          The vulnerable path is xfrm ESP-in-UDP receiving spliced file pages
#          and decrypting in-place on page-cache backed skb frags. This module
#          is intended to run after the existing IPsec scenario so normal ESP
#          coverage and the targeted LTP regression can share the same job.
#          By default it runs the upstream LTP xfrm01 regression test when
#          available; job settings may override the command for internal builds.
#
# Maintainer: Kernel QE <kernel-qa@suse.de>

use Mojo::Base 'opensusebasetest';
use testapi;
use serial_terminal 'select_serial_terminal';
use utils;
use package_utils 'install_package';

my $workdir = '/tmp/dirtyfrag-xfrm-esp';
my $stdout = "$workdir/reproducer.log";
my $exit_status = "$workdir/reproducer.exit";

sub shell_quote {
    my ($value) = @_;
    $value =~ s/'/'"'"'/g;
    return "'$value'";
}

sub collect_context {
    assert_script_run("mkdir -p $workdir");
    assert_script_run("uname -a | tee $workdir/uname.txt");
    script_run("ip -d xfrm state > $workdir/xfrm-state.before.txt 2>&1");
    script_run("ip -d xfrm policy > $workdir/xfrm-policy.before.txt 2>&1");
    script_run("ip netns list > $workdir/netns.before.txt 2>&1");
    script_run("lsmod | grep -E 'esp4|esp6|xfrm|udp|gcm|rxrpc' > $workdir/lsmod.before.txt 2>&1");
    script_run("grep -E '^(name|driver|module|type|async)' /proc/crypto > $workdir/proc-crypto.before.txt 2>&1");
    script_run("modprobe esp4 > $workdir/modprobe-esp4.txt 2>&1");
    script_run("modprobe esp6 > $workdir/modprobe-esp6.txt 2>&1");
}

sub build_reproducer_command {
    my $args = get_var('DIRTYFRAG_REPRO_ARGS', '');

    if (my $cmd = get_var('DIRTYFRAG_REPRO_CMD')) {
        return $cmd;
    }

    if (my $url = get_var('DIRTYFRAG_REPRO_URL')) {
        my $reproducer = "$workdir/reproducer";
        assert_script_run('curl -fsSL ' . shell_quote($url) . ' -o ' . shell_quote($reproducer), timeout => 180);
        assert_script_run('chmod 0700 ' . shell_quote($reproducer));
        return shell_quote($reproducer) . " $args";
    }

    if (my $path = get_var('DIRTYFRAG_REPRO_PATH')) {
        return shell_quote($path) . " $args";
    }

    my $ltp_xfrm01 = script_output(
        'command -v xfrm01 || test -x /opt/ltp/testcases/bin/xfrm01 && echo /opt/ltp/testcases/bin/xfrm01',
        proceed_on_failure => 1
    );
    chomp $ltp_xfrm01;

    return shell_quote($ltp_xfrm01) . " $args" if $ltp_xfrm01;

    install_package('gcc');
    my $source = "$workdir/xfrm01_standalone.c";
    my $binary = "$workdir/xfrm01_standalone";

    assert_script_run('curl -fsSL ' . data_url('ipsec/xfrm01_standalone.c') . ' -o ' . shell_quote($source), timeout => 180);
    assert_script_run("gcc -Wall -Wextra -O2 " . shell_quote($source) . ' -o ' . shell_quote($binary));

    return shell_quote($binary) . " $args";
}

sub run {
    select_serial_terminal;

    unless (get_var('DIRTYFRAG_REPRO')) {
        record_info('SKIP', 'Set DIRTYFRAG_REPRO=1 to run the DirtyFrag xfrm ESP reproducer harness');
        return;
    }

    my $role = get_var('IPSEC_SETUP', '');
    my $run_role = get_var('DIRTYFRAG_REPRO_ROLE', 'left');
    if ($role && $role ne $run_role) {
        record_info('SKIP', "DirtyFrag reproducer runs only on IPSEC_SETUP=$run_role; this host is $role");
        return;
    }

    record_info('CVE-2026-43284', 'Running DirtyFrag xfrm ESP reproducer harness after IPsec setup');
    collect_context();

    my $cmd = build_reproducer_command();
    my $timeout = get_var('DIRTYFRAG_REPRO_TIMEOUT', 120);
    my $expected_exit = get_var('DIRTYFRAG_REPRO_EXPECT_EXIT', 0);

    assert_script_run(
        "set -o pipefail; timeout $timeout $cmd > $stdout 2>&1; rc=\$?; echo \$rc > $exit_status; test \$rc -eq $expected_exit",
        timeout => $timeout + 30
    );

    if (my $fail_pattern = get_var('DIRTYFRAG_REPRO_FAIL_PATTERN')) {
        assert_script_run("! grep -Eiq " . shell_quote($fail_pattern) . " $stdout");
    }

    if (my $safe_pattern = get_var('DIRTYFRAG_REPRO_SAFE_PATTERN')) {
        assert_script_run("grep -Eiq " . shell_quote($safe_pattern) . " $stdout");
    }

    script_run("dmesg > $workdir/dmesg.after.txt 2>&1");
    upload_logs($stdout, failok => 1);
    upload_logs($exit_status, failok => 1);
    upload_logs("$workdir/dmesg.after.txt", failok => 1);
    upload_logs("$workdir/proc-crypto.before.txt", failok => 1);
    upload_logs("$workdir/lsmod.before.txt", failok => 1);
}

sub post_fail_hook {
    script_run("dmesg > $workdir/dmesg.fail.txt 2>&1");
    upload_logs($stdout, failok => 1);
    upload_logs($exit_status, failok => 1);
    upload_logs("$workdir/dmesg.fail.txt", failok => 1);
    upload_logs("$workdir/xfrm-state.before.txt", failok => 1);
    upload_logs("$workdir/xfrm-policy.before.txt", failok => 1);
    upload_logs("$workdir/proc-crypto.before.txt", failok => 1);
    upload_logs("$workdir/lsmod.before.txt", failok => 1);
}

sub test_flags {
    return {fatal => 1};
}

1;
