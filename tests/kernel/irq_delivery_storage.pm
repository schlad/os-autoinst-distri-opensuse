# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP
# Summary: Check device interrupt delivery during I/O on a multi-socket system.
# Maintainer: Kernel QE <kernel-qa@suse.de>
# Ticket: poo#49517

use Mojo::Base 'opensusebasetest';
use testapi;
use serial_terminal 'select_serial_terminal';
use package_utils 'install_package';
use Mojo::JSON 'decode_json';
use LTP::utils 'check_kernel_taint';
use Kernel::cpu qw(get_cpu_model get_cpu_map);
use Kernel::irq qw(get_interrupts get_irq_total get_irq_per_cpu get_device_irqs);
use Kernel::block_dev qw(is_block_device record_storage_info get_block_dev_kernel_name get_block_dev_pci_device);

my $logs = '/var/log/irq-delivery-storage';

# Pin one reader to each online CPU. Direct reads exercise the controller
# without changing the disk contents or relying on the page cache.
# TODO: consider a fio library when more tests run fio.
sub run_fio {
    my ($dev, $duration, @cpus) = @_;
    assert_script_run("fio --name=irq-delivery-storage --filename=$dev --readonly --allow_file_create=0 "
          . '--rw=randread --direct=1 --ioengine=libaio --bs=4k --iodepth=16 --size=1G '
          . '--numjobs=' . scalar(@cpus) . ' --cpus_allowed=' . join(',', @cpus) . ' --cpus_allowed_policy=split '
          . "--runtime=$duration --time_based --output-format=json --output=$logs/fio.json",
        timeout => $duration + 120);
    my $jobs = decode_json(script_output("cat $logs/fio.json"))->{jobs} // [];
    die 'fio did not report all CPU workers' unless @$jobs == @cpus;
    die 'A fio worker completed no reads' if grep { $_->{read}{total_ios} == 0 } @$jobs;
}

sub io_error_count {
    my ($kernel_name) = @_;
    return script_output("dmesg | grep -c 'I/O error, dev $kernel_name,' || true");
}

sub run {
    my ($self) = @_;
    select_serial_terminal;

    my $map = get_cpu_map();
    my @cpus = sort { $a <=> $b } grep { $map->{$_}{online} } keys %$map;
    my %sockets = map { ($map->{$_}{socket} // 'unknown') => 1 } @cpus;
    record_info('CPU topology', (get_cpu_model() // 'unknown') . "\nonline CPUs: " . join(',', @cpus)
          . "\nsockets with online CPUs: " . join(',', sort keys %sockets));
    die 'This scenario requires more than eight online CPUs on at least two sockets'
      unless @cpus > 8 && keys(%sockets) >= 2 && !$sockets{unknown};

    my $dev = get_required_var('IRQ_DELIVERY_DEVICE');
    die 'Use an absolute device path without shell metacharacters' unless $dev =~ m{^/dev/[A-Za-z0-9_./:-]+$};
    my $duration = get_var('IRQ_DELIVERY_DURATION', 30);
    die 'IRQ_DELIVERY_DURATION must be a positive integer' unless $duration =~ /^[1-9]\d*$/;
    is_block_device($dev);
    my $kernel_name = get_block_dev_kernel_name($dev);
    assert_script_run("test ! -e /sys/class/block/$kernel_name/partition", fail_message => "$dev is a partition");
    assert_script_run("test \$(blockdev --getsize64 $dev) -ge 1073741824", fail_message => "$dev is smaller than 1 GiB");
    record_storage_info();
    my $controller = get_block_dev_pci_device($dev);
    my @irqs = get_device_irqs($controller);
    record_info('Controller', "$kernel_name\n$controller\nIRQs: " . join(',', @irqs));

    install_package('fio', trup_apply => 1);
    assert_script_run("mkdir -p $logs");
    my $before = get_interrupts();
    my $io_errors = io_error_count($kernel_name);
    run_fio($dev, $duration, @cpus);
    my $after = get_interrupts();

    # Report the distribution per socket and NUMA node, but do not require it
    # to be even
    my ($cpu_before, $cpu_after) = (get_irq_per_cpu($before, @irqs), get_irq_per_cpu($after, @irqs));
    for my $level (qw(socket node)) {
        my %delta;
        $delta{$map->{$_}{$level} // 'unknown'} += $cpu_after->{$_} - ($cpu_before->{$_} // 0) for keys %$cpu_after;
        record_info("IRQ per $level", join("\n", map { "$level $_: $delta{$_}" } sort keys %delta));
    }

    my $delta = get_irq_total($after, @irqs) - get_irq_total($before, @irqs);
    die 'No new controller interrupts during direct I/O' unless $delta > 0;
    die "New I/O errors on $kernel_name" if io_error_count($kernel_name) > $io_errors;
    check_kernel_taint($self);
    record_info('I/O passed', scalar(@cpus) . " CPU workers completed reads; $delta new controller interrupts");
}

sub post_fail_hook {
    my ($self) = @_;
    select_serial_terminal;
    script_run("mkdir -p $logs; cat /proc/interrupts > $logs/interrupts.txt; dmesg > $logs/dmesg.txt");
    upload_logs("$logs/$_", failok => 1) for qw(interrupts.txt dmesg.txt fio.json);
    $self->SUPER::post_fail_hook;
}

sub test_flags {
    return {fatal => 1};
}

1;

=head1 Description

Exercise PCI storage interrupts on a system with more than eight online
CPUs on at least two sockets (poo#49517). Run one direct-read fio worker
per online CPU. Each worker must complete reads, the selected controller's
interrupt count must increase, no new I/O errors may be logged for the disk
and the kernel must not be tainted (see C<check_kernel_taint> in
C<LTP::utils>).

The test records the new interrupts per socket and per NUMA node, but does
not require equal interrupt distribution, activity on every CPU, or activity
on every queue.
These are not requirements for working interrupt delivery. A pass is a
smoke-test result, not proof that the original regression can be
reproduced on this controller.

=head1 Configuration

=head2 IRQ_DELIVERY_DEVICE

Required whole-disk device path, preferably under C</dev/disk/by-id/>.
Select local PCI storage such as NVMe or a disk behind a SATA controller.
The disk must have at least 1 GiB. The workload only reads the disk.
Loop devices, device mapper devices, and partitions are not supported.

=head2 IRQ_DELIVERY_DURATION

Workload duration in seconds. Defaults to C<30>.

=head2 LTP_TAINT_EXPECTED

Mask of the kernel taint flags that are expected and do not fail the test.
See C<check_kernel_taint> in C<LTP::utils>.

=cut
