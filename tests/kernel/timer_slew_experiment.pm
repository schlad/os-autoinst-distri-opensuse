# SUSE's openQA tests
#
# Copyright 2026 SUSE LLC
# SPDX-License-Identifier: FSFAP
#
# Summary: Debug experiment for poo#193939: run epoll_wait02 while the kernel
#          tick length is changed via adjtimex() to emulate chronyd slewing
#          CLOCK_MONOTONIC. Not meant for production schedules.
# Maintainer: QE Kernel <kernel-qa@suse.de>

use Mojo::Base 'opensusebasetest';
use testapi;
use serial_terminal 'select_serial_terminal';
use LTP::utils 'get_ltproot';
use utils 'write_sut_file';

my $settick = '/root/settick.py';

my $settick_py = <<'EOF';
import ctypes, sys

class Timex(ctypes.Structure):
    _fields_ = [("modes", ctypes.c_uint), ("offset", ctypes.c_long),
                ("freq", ctypes.c_long), ("maxerror", ctypes.c_long),
                ("esterror", ctypes.c_long), ("status", ctypes.c_int),
                ("constant", ctypes.c_long), ("precision", ctypes.c_long),
                ("tolerance", ctypes.c_long), ("tv_sec", ctypes.c_long),
                ("tv_usec", ctypes.c_long), ("tick", ctypes.c_long),
                ("pad", ctypes.c_byte * 256)]

ADJ_TICK = 0x4000

tx = Timex()
if len(sys.argv) > 1:
    tx.modes = ADJ_TICK
    tx.tick = int(sys.argv[1])

if ctypes.CDLL(None, use_errno=True).adjtimex(ctypes.byref(tx)) < 0:
    sys.exit("adjtimex failed: errno %d" % ctypes.get_errno())

print("tick %d freq_ppm %.3f status 0x%x" % (tx.tick, tx.freq / 65536, tx.status))
EOF

sub set_tick {
    my ($tick) = @_;

    return script_output("python3 $settick " . ($tick // ''));
}

sub run {
    select_serial_terminal;

    write_sut_file($settick, $settick_py);
    script_run('systemctl stop chronyd');
    record_info('adjtimex before', set_tick());

    my $epoll_wait02 = get_ltproot() . '/testcases/bin/epoll_wait02';

    for my $tick (10000, 10100, 9900) {
        record_info("tick $tick", set_tick($tick));
        my $out = script_output("$epoll_wait02 2>&1 || true", timeout => 300);
        record_info("epoll_wait02 tick=$tick", $out, result => ($out =~ /TFAIL/ ? 'fail' : 'ok'));
    }

    record_info('adjtimex restored', set_tick(10000));
}

sub post_fail_hook {
    script_run("test -f $settick && python3 $settick 10000");
}

sub test_flags {
    return {fatal => 1};
}

1;
