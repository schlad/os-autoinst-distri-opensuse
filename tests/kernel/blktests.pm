# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP

# Package: blktests
# Summary: Block device layer tests
# Maintainer: Kernel QE <kernel-qa@suse.de>

use Mojo::Base 'opensusebasetest';
use testapi;
use serial_terminal 'select_serial_terminal';
use utils;
use repo_tools 'add_qa_head_repo';
use LTP::WhiteList;
use Kernel::blanket qw(install_blanket blanket_init blanket_add blanket_show blanket_env upload_blanket_results);
use package_utils 'install_package';
use Utils::Logging qw(export_logs_basic save_and_upload_log);

sub prepare_blktests_config {
    my ($devices) = @_;

    if ($devices eq 'none') {
        record_info('INFO', 'No specific tests device selected');
    } else {
        script_run("echo TEST_DEVS=\\($devices\\) > /etc/blktests/config");
        record_info('INFO', "$devices");
    }
}

sub list_skipped_blktests {
    my ($whitelist, $environment) = @_;
    my %skipped_tests;

    for my $test ($whitelist->list_skipped_tests($environment, 'blktests')) {
        my $entry = $whitelist->find_whitelist_entry($environment, 'blktests', $test);
        $skipped_tests{$test} = $entry->{message} // '';
    }

    return %skipped_tests;
}

sub prepare_whitelist_environment {
    my ($trtypes) = @_;

    return {
        product => get_var('DISTRI') . ':' . get_var('VERSION'),
        revision => get_var('BUILD'),
        flavor => get_var('FLAVOR'),
        arch => get_var('ARCH'),
        backend => get_var('BACKEND'),
        machine => get_var('MACHINE'),
        test_variant => $trtypes // '',
        kernel => script_output('uname -r')
    };
}

sub get_known_excludes {
    my (%args) = @_;
    my $issues = $args{issues};

    return unless $issues;

    my $whitelist = LTP::WhiteList->new($issues);
    my $environment = prepare_whitelist_environment($args{trtypes});

    return list_skipped_blktests($whitelist, $environment);
}

sub process_blktests_results {
    my ($log_dir) = @_;

    script_run("cd ${log_dir}");
    script_run('wget --quiet ' . data_url('kernel/post_process') . ' -O post_process');
    script_run('chmod +x post_process');
    script_run('./post_process');

    record_info('results', script_output('ls ./results'));
    script_run('tar -zcvf results.tar.gz results');
    upload_logs('results.tar.gz');

    record_info('XML', script_output('ls ./'));
    my $output = script_output("find ${log_dir} -name \"*_results.xml\" 2>/dev/null || true");
    foreach my $file (split /\n/, $output) {
        parse_extra_log('XUnit', $file);
    }
}

sub run {
    select_serial_terminal;

    #below variable exposes blktests options to the openQA testsuite
    #definition, so that it allows flexible ways of re-runing the tests
    my $tests = get_required_var('BLKTESTS');
    my $devices = get_required_var('BLKTESTS_TEST_DEVS');
    my $quick = get_var('BLKTESTS_QUICK', 60);
    my $exclude = get_var('BLKTESTS_EXCLUDE');
    my $trtypes = get_var('BLKTESTS_TRTYPES');
    my $issues = get_var('BLKTESTS_KNOWN_ISSUES');
    my $use_blanket = get_var('BLKTESTS_BLANKET');
    my $blanket_objects = get_var('BLKTESTS_BLANKET_OBJECTS');

    record_info('KERNEL', script_output('rpm -qi kernel-default'));
    save_and_upload_log('rpm -qi kernel-default', 'kernel_bug_report.txt');

    #QA repo is added with lower prio in order to avoid possible problems
    #with some packages provided in both, tested product and qa repo; example: fio
    add_qa_head_repo(priority => 100);
    install_package('blktests fio', trup_apply => 1);

    if ($use_blanket) {
        install_blanket();
        blanket_init();
        blanket_add(split(/,/, $blanket_objects)) if $blanket_objects;
        blanket_show();
    }

    #Prepare configuration, log/results directories
    assert_script_run('mkdir -p /etc/blktests');

    my $log_dir = '/var/log/blktests';
    assert_script_run("mkdir -p ${log_dir}/results");

    prepare_blktests_config($devices);

    my @tests = map { s/^\s+|\s+$//gr } split(',', $tests);
    assert_script_run('cd /usr/lib/blktests');

    my @exclude = split(/,/, $exclude // '');
    my %known_exclude = get_known_excludes(issues => $issues, trtypes => $trtypes);
    push @exclude, sort keys(%known_exclude);
    for my $test (sort keys(%known_exclude)) {
        my $message = $known_exclude{$test} ? ": $known_exclude{$test}" : '';
        record_info('Known issue', "Skipping $test$message");
    }

    $exclude = join(' ', map { "--exclude=$_" } grep { $_ ne '' } @exclude);
    $trtypes = "NVMET_TRTYPES=\"$trtypes\" " if $trtypes;

    my $blanket_prefix = $use_blanket ? blanket_env() . ' ' : '';
    foreach my $i (@tests) {
        my $config = $devices eq 'none' ? '' : '-c /etc/blktests/config';
        script_run("${trtypes}${blanket_prefix}./check $config -o ${log_dir}/results --quick=$quick $exclude $i", 1200);
    }

    process_blktests_results($log_dir);
    upload_blanket_results() if $use_blanket;
}

sub test_flags {
    return {fatal => 1};
}

sub post_fail_hook {
    my ($self) = @_;
    select_serial_terminal;
    export_logs_basic;
}

1;

=head1 Description

Run the upstream blktests suite from the C<blktests> package.

The test groups to execute are selected with C<BLKTESTS>. Individual tests can
be skipped either directly with C<BLKTESTS_EXCLUDE> (mostly for debugging purposes)
or through known-issues metadata referenced by C<BLKTESTS_KNOWN_ISSUES>.
Most native C<blktests> variables are exposed as C<BLKTESTS_NAME>, where C<NAME>
matches the upstream C<blktests> variable name, for example C<BLKTESTS_TRTYPES>
for C<TRTYPES>.

=head1 Configuration

=head2 BLKTESTS

Required. Comma-separated list of blktests groups or individual tests passed to
C<./check>. Examples:

  BLKTESTS=block
  BLKTESTS=dm,throtl,scsi,loop
  BLKTESTS=nvme/001

=head2 BLKTESTS_TEST_DEVS

Required. Device list written to F</etc/blktests/config> as C<TEST_DEVS>.
Set to C<none> to skip writing a device list.

=head2 BLKTESTS_EXCLUDE

Optional. Comma-separated list of tests to exclude directly from this job. The
value is converted to C<./check --exclude=...> arguments.

This remains useful for temporary debugging overrides. Persistent product or
transport specific skips should be represented in C<BLKTESTS_KNOWN_ISSUES>
instead.

=head2 BLKTESTS_KNOWN_ISSUES

Optional. URL or local path to a known-issues YAML file parsed with
C<LTP::WhiteList>. Entries under the C<blktests> suite with C<skip: 1> are
added to the C<./check --exclude=...> arguments when they match the current
openQA environment.

Known-issues keys must use the full upstream blktests test ID format
C<group/number>. Matching C<skip: 1> entries are passed directly to
C<./check --exclude=...>.

Example:

  blktests:
      block/033:
      - product: sle:16\.1$
        skip: 1
        message: miniublk uses legacy ublk command opcodes
      nvme/041:
      - test_variant: ^fc$
        skip: 1
        message: skipped only for NVMe Fibre Channel transport

The common C<LTP::WhiteList> fields such as C<product>, C<revision>, C<flavor>,
C<arch>, C<backend>, C<machine>, C<kernel>, and C<test_variant> are supported.
For blktests, C<test_variant> matches C<BLKTESTS_TRTYPES>.

=head2 BLKTESTS_QUICK

Optional. Value passed to C<./check --quick>. Defaults to C<60>.

=head2 BLKTESTS_TRTYPES

Optional. NVMe transport type passed to blktests through C<NVMET_TRTYPES>.
This value is also available to C<BLKTESTS_KNOWN_ISSUES> entries through the
C<test_variant> matcher.

=head2 BLKTESTS_BLANKET

Optional. Set to any true value to enable coverage collection with the blanket
tool (L<https://github.com/schlad/blanket>). When set, blanket is built from
source on the SUT and each C<./check> invocation is run with
C<LD_PRELOAD=libblanket.so> so that all child processes are covered. A report
and raw coverage archive are uploaded at the end of the test. Override blanket
defaults with C<BLANKET_GIT_REPO>, C<BLANKET_GIT_REF>, C<BLANKET_DIR>,
C<BLANKET_BIN>, C<BLANKET_LIB>, C<BLANKET_CONTROL>, and C<BLANKET_MODE>.

=head2 BLKTESTS_BLANKET_OBJECTS

Optional. Comma-separated list of ELF binary paths to register with blanket for
coverage measurement. Required when C<BLKTESTS_BLANKET> is set — without it no
coverage files are produced. Choose binaries relevant to the test group being
run, for example C</usr/bin/nvme> for C<BLKTESTS=nvme> or C</usr/bin/sg_raw>
for SCSI tests.
