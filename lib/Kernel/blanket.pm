# SUSE's openQA tests
#
# Copyright 2026 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: Helper functions for collecting coverage with blanket
# Maintainer: Kernel QE <kernel-qa@suse.de>

package Kernel::blanket;

use base Exporter;
use strict;
use warnings;
use testapi;
use package_utils 'install_package';

our @EXPORT_OK = qw(
  install_blanket
  blanket_init
  blanket_add
  blanket_trace
  blanket_show
  blanket_env
  run_with_blanket
  upload_blanket_results
);

=head1 SYNOPSIS

Helpers for using the blanket preload coverage tool from openQA tests.

The helpers use a dedicated C<BLANKET_CONTROL> file and per-command
C<LD_PRELOAD>. They do not modify F</etc/ld.so.preload>.

=cut

sub _quote {
    my ($value) = @_;
    $value //= '';
    $value =~ s/'/'"'"'/g;
    return "'$value'";
}

sub _blanket_bin {
    return get_var('BLANKET_BIN', '/opt/blanket/blanket');
}

sub _blanket_lib {
    return get_var('BLANKET_LIB', '/opt/blanket/libblanket.so');
}

sub _control_path {
    my (%args) = @_;
    return $args{control_path} // get_var('BLANKET_CONTROL', '/tmp/blanket.conf');
}

sub _coverage_glob {
    return get_var('BLANKET_COVERAGE_GLOB', '/tmp/coverage-*');
}

sub _control_opt {
    my (%args) = @_;
    return '--control-path ' . _quote(_control_path(%args));
}

=head2 install_blanket

 install_blanket();

Build blanket from git on the SUT. Override the defaults with:
C<BLANKET_GIT_REPO>, C<BLANKET_GIT_REF>, and C<BLANKET_DIR>.

=cut

sub install_blanket {
    my (%args) = @_;
    my $repo = $args{repo} // get_var('BLANKET_GIT_REPO', 'https://github.com/schlad/blanket.git');
    my $ref = $args{ref} // get_var('BLANKET_GIT_REF', 'main');
    my $dir = $args{dir} // get_var('BLANKET_DIR', '/opt/blanket');

    install_package('gcc git-core libdw-devel libelf-devel make ncurses-devel', trup_apply => 1);
    assert_script_run('rm -rf ' . _quote($dir));
    assert_script_run('git clone --depth 1 --branch ' . _quote($ref) . ' ' . _quote($repo) . ' ' . _quote($dir), 300);
    record_info('blanket git', script_output('git -C ' . _quote($dir) . ' --no-pager log -1 --oneline'));
    assert_script_run('make -C ' . _quote($dir), 300);
    assert_script_run('test -x ' . _quote("$dir/blanket"));
    assert_script_run('test -f ' . _quote("$dir/libblanket.so"));
}

=head2 blanket_init

 blanket_init(mode => 'touch');

Initialize the blanket control file. Supported optional arguments:
C<mode>, C<sampling_interval>, C<granularity>, C<test_id>, C<measure_all>,
C<control_path>.

=cut

sub blanket_init {
    my (%args) = @_;
    my @opts = (_control_opt(%args));

    push @opts, '--mode ' . _quote($args{mode} // get_var('BLANKET_MODE', 'touch'));
    push @opts, '--sampling-interval ' . _quote($args{sampling_interval}) if defined $args{sampling_interval};
    push @opts, '--granularity ' . _quote($args{granularity}) if defined $args{granularity};
    push @opts, '--test-id ' . _quote($args{test_id}) if defined $args{test_id};
    push @opts, '--measure-all' if $args{measure_all};

    assert_script_run(join(' ', _quote(_blanket_bin()), @opts, 'init'));
}

=head2 blanket_add

 blanket_add('/usr/bin/sha256sum', '/usr/lib64/libcrypto.so.*');

Add ELF objects to the active blanket control file.

=cut

sub blanket_add {
    my (@objects) = @_;
    die 'No blanket objects specified' unless @objects;
    assert_script_run(join(' ', _quote(_blanket_bin()), _control_opt(), 'add', map { _quote($_) } @objects));
}

=head2 blanket_trace

 blanket_trace('/usr/bin/foo', 'main');

Add ptrace targets to the active blanket control file.

=cut

sub blanket_trace {
    my ($object, @symbols) = @_;
    die 'No blanket trace object specified' unless $object;
    die 'No blanket trace symbols specified' unless @symbols;
    assert_script_run(join(' ', _quote(_blanket_bin()), _control_opt(), 'trace', _quote($object), map { _quote($_) } @symbols));
}

=head2 blanket_show

 blanket_show();

Record the current blanket configuration in openQA.

=cut

sub blanket_show {
    record_info('blanket', script_output(join(' ', _quote(_blanket_bin()), _control_opt(), 'show')));
}

=head2 blanket_env

 my $env = blanket_env();

Return the environment prefix needed to run one command under blanket.

=cut

sub blanket_env {
    my (%args) = @_;
    return join(' ',
        'BLANKET_CONTROL=' . _quote(_control_path(%args)),
        'LD_PRELOAD=' . _quote($args{lib} // _blanket_lib()));
}

=head2 run_with_blanket

 run_with_blanket('sha256sum /tmp/file', timeout => 120);

Run a command with blanket preloaded.

=cut

sub run_with_blanket {
    my ($cmd, %args) = @_;
    die 'No command specified' unless $cmd;
    assert_script_run(blanket_env(%args) . " $cmd", $args{timeout});
}

=head2 upload_blanket_results

 upload_blanket_results();

Generate and upload a blanket report plus raw coverage files.

=cut

sub upload_blanket_results {
    my (%args) = @_;
    my $glob = $args{coverage_glob} // _coverage_glob();
    my $report = $args{report} // '/tmp/blanket-report.txt';
    my $archive = $args{archive} // '/tmp/blanket-results.tar.gz';
    my $details = $args{details} // get_var('BLANKET_REPORT_DETAILS', '--symbols');

    if (script_run("ls $glob") != 0) {
        record_info('blanket', "No blanket coverage files found: $glob", result => 'softfail');
        return;
    }

    assert_script_run(join(' ', _quote(_blanket_bin()), 'report', $details, $glob, '>', _quote($report)), 300);
    upload_logs($report, failok => 1);
    assert_script_run('tar -czf ' . _quote($archive) . ' ' . _quote($report) . " $glob", 300);
    upload_logs($archive, failok => 1);
}

1;
