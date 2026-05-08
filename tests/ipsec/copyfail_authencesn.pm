# SUSE's openQA tests
#
# Copyright 2026 SUSE LLC
# SPDX-License-Identifier: FSFAP
#
# Summary: CVE-2026-31431 / Copy Fail regression harness for IPsec jobs.
#          The vulnerable kernel path is local AF_ALG authencesn access, not
#          ESP forwarding itself. This module is intended to run after the
#          existing IPsec scenario so the same kernel/IPsec context is covered.
#          By default it runs the upstream LTP af_alg08 regression test when
#          available; job settings may override the command for internal builds.
#
# Maintainer: Kernel QE <kernel-qa@suse.de>

use Mojo::Base 'opensusebasetest';
use testapi;
use serial_terminal 'select_serial_terminal';
use utils;

my $workdir = '/tmp/copyfail-authencesn';
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
    script_run("lsmod | grep -E 'algif_aead|authenc|esp|xfrm' > $workdir/lsmod.before.txt 2>&1");
    script_run("grep -E '^(name|driver|module|type|async)' /proc/crypto > $workdir/proc-crypto.before.txt 2>&1");
    script_run("modprobe algif_aead > $workdir/modprobe-algif-aead.txt 2>&1");
    script_run("modprobe authencesn > $workdir/modprobe-authencesn.txt 2>&1");
    script_run("grep -A8 -E 'name[[:space:]]*: authencesn' /proc/crypto > $workdir/authencesn.txt 2>&1");
}

sub build_reproducer_command {
    my $args = get_var('COPYFAIL_REPRO_ARGS', '');

    if (my $cmd = get_var('COPYFAIL_REPRO_CMD')) {
        return $cmd;
    }

    if (my $url = get_var('COPYFAIL_REPRO_URL')) {
        my $reproducer = "$workdir/reproducer";
        assert_script_run('curl -fsSL ' . shell_quote($url) . ' -o ' . shell_quote($reproducer), timeout => 180);
        assert_script_run('chmod 0700 ' . shell_quote($reproducer));
        return shell_quote($reproducer) . " $args";
    }

    if (my $path = get_var('COPYFAIL_REPRO_PATH')) {
        return shell_quote($path) . " $args";
    }

    my $ltp_af_alg08 = script_output(
        'command -v af_alg08 || test -x /opt/ltp/testcases/bin/af_alg08 && echo /opt/ltp/testcases/bin/af_alg08',
        proceed_on_failure => 1
    );
    chomp $ltp_af_alg08;

    return shell_quote($ltp_af_alg08) . " $args" if $ltp_af_alg08;

    die 'COPYFAIL_REPRO=1 requires LTP af_alg08 or COPYFAIL_REPRO_CMD, COPYFAIL_REPRO_URL, or COPYFAIL_REPRO_PATH';
}

sub run {
    select_serial_terminal;

    unless (get_var('COPYFAIL_REPRO')) {
        record_info('SKIP', 'Set COPYFAIL_REPRO=1 to run the Copy Fail reproducer harness');
        return;
    }

    my $role = get_var('IPSEC_SETUP', '');
    my $run_role = get_var('COPYFAIL_REPRO_ROLE', 'left');
    if ($role && $role ne $run_role) {
        record_info('SKIP', "Copy Fail reproducer runs only on IPSEC_SETUP=$run_role; this host is $role");
        return;
    }

    record_info('CVE-2026-31431', 'Running Copy Fail authencesn reproducer harness after IPsec setup');
    collect_context();

    my $cmd = build_reproducer_command();
    my $timeout = get_var('COPYFAIL_REPRO_TIMEOUT', 120);
    my $expected_exit = get_var('COPYFAIL_REPRO_EXPECT_EXIT', 0);

    assert_script_run(
        "set -o pipefail; timeout $timeout $cmd > $stdout 2>&1; rc=\$?; echo \$rc > $exit_status; test \$rc -eq $expected_exit",
        timeout => $timeout + 30
    );

    if (my $fail_pattern = get_var('COPYFAIL_REPRO_FAIL_PATTERN')) {
        assert_script_run("! grep -Eiq " . shell_quote($fail_pattern) . " $stdout");
    }

    if (my $safe_pattern = get_var('COPYFAIL_REPRO_SAFE_PATTERN')) {
        assert_script_run("grep -Eiq " . shell_quote($safe_pattern) . " $stdout");
    }

    script_run("dmesg > $workdir/dmesg.after.txt 2>&1");
    upload_logs($stdout, failok => 1);
    upload_logs($exit_status, failok => 1);
    upload_logs("$workdir/dmesg.after.txt", failok => 1);
    upload_logs("$workdir/proc-crypto.before.txt", failok => 1);
    upload_logs("$workdir/authencesn.txt", failok => 1);
}

sub post_fail_hook {
    script_run("dmesg > $workdir/dmesg.fail.txt 2>&1");
    upload_logs($stdout, failok => 1);
    upload_logs($exit_status, failok => 1);
    upload_logs("$workdir/dmesg.fail.txt", failok => 1);
    upload_logs("$workdir/xfrm-state.before.txt", failok => 1);
    upload_logs("$workdir/xfrm-policy.before.txt", failok => 1);
    upload_logs("$workdir/proc-crypto.before.txt", failok => 1);
    upload_logs("$workdir/authencesn.txt", failok => 1);
}

sub test_flags {
    return {fatal => 1};
}

1;
