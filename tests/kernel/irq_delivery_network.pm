# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP
# Summary: Check network card interrupt delivery during traffic on a multi-socket system.
# Maintainer: Kernel QE <kernel-qa@suse.de>
# Ticket: poo#49517

use Mojo::Base 'opensusebasetest';
use testapi;
use serial_terminal 'select_serial_terminal';
use LTP::utils 'check_kernel_taint';
use Kernel::cpu qw(lscpu_info get_cpu_model get_cpu_map has_cpu_flag);
use Kernel::irq qw(get_interrupts get_irq_total get_irq_per_cpu get_irq_remapped get_device_irqs);
use Kernel::net_tests 'get_net_dev_pci_device';

# Check that an interface is usable and find the interrupts of its card
sub prepare_nic {
    my ($name) = @_;
    die "Use a network interface name: $name" unless $name =~ /^[A-Za-z0-9_.:-]{1,15}$/;
    assert_script_run("test -e /sys/class/net/$name", fail_message => "Network interface $name not found");
    # A network driver requests its interrupts only when the interface is up
    # (IFF_UP, bit 0 of the interface flags)
    assert_script_run("test \$((\$(cat /sys/class/net/$name/flags) & 1)) = 1", fail_message => "Network interface $name is not up");
    my $card = get_net_dev_pci_device($name);
    my @irqs = get_device_irqs($card);
    record_info("Card $name", "$card\nIRQs: " . join(',', @irqs));
    return {name => $name, card => $card, irqs => \@irqs};
}

# TODO: send and receive traffic with a peer machine, with one stream per
# CPU and enough flows that RSS spreads them over all receive queues, for
# example with iperf3. Then check that the streams moved data without
# errors.
sub generate_traffic {
    my ($nic, $duration) = @_;
    record_info("No traffic $nic->{name}", 'No traffic generator yet, the counters only show the existing traffic');
}

sub test_nic {
    my ($self, $nic, $info, $map, $duration) = @_;
    my @irqs = @{$nic->{irqs}};
    my $before = get_interrupts();

    # poo#49517 broke interrupt remapping on x2APIC machines. Show if this
    # run went through that path.
    my $remapped = get_irq_remapped($before, @irqs);
    my $remapped_count = grep { $_ } values %$remapped;
    record_info("Interrupt mode $nic->{name}", 'x2APIC offered by the CPU: ' . (has_cpu_flag('x2apic', $info) ? 'yes' : 'no')
          . "\nRemapped card IRQs: $remapped_count of " . scalar(@irqs));

    generate_traffic($nic, $duration);
    my $after = get_interrupts();

    # Report the distribution per socket and NUMA node, but do not require it
    # to be even
    my ($cpu_before, $cpu_after) = (get_irq_per_cpu($before, @irqs), get_irq_per_cpu($after, @irqs));
    for my $level (qw(socket node)) {
        my %delta;
        $delta{$map->{$_}{$level} // 'unknown'} += $cpu_after->{$_} - ($cpu_before->{$_} // 0) for keys %$cpu_after;
        record_info("IRQ per $level $nic->{name}", join("\n", map { "$level $_: $delta{$_}" } sort keys %delta));
    }

    # TODO: fail if there are no new interrupts, once the test generates its
    # own traffic
    my $delta = get_irq_total($after, @irqs) - get_irq_total($before, @irqs);
    record_info("IRQ total $nic->{name}", "$delta new card interrupts");
    # A transmit queue timeout of the card triggers a kernel warning, which
    # taints the kernel
    check_kernel_taint($self);
}

sub run {
    my ($self) = @_;
    select_serial_terminal;

    my $info = lscpu_info();
    my $map = get_cpu_map();
    my @cpus = sort { $a <=> $b } grep { $map->{$_}{online} } keys %$map;
    my %sockets = map { ($map->{$_}{socket} // 'unknown') => 1 } @cpus;
    record_info('CPU topology', (get_cpu_model($info) // 'unknown') . "\nonline CPUs: " . join(',', @cpus)
          . "\nsockets with online CPUs: " . join(',', sort keys %sockets));
    die 'This scenario requires more than eight online CPUs on at least two sockets'
      unless @cpus > 8 && keys(%sockets) >= 2 && !$sockets{unknown};

    my @names = split ' ', get_required_var('IRQ_DELIVERY_DEVICE');
    die 'IRQ_DELIVERY_DEVICE has no network interface' unless @names;
    my $duration = get_var('IRQ_DELIVERY_DURATION', 30);
    die 'IRQ_DELIVERY_DURATION must be a positive integer' unless $duration =~ /^[1-9]\d*$/;

    # Check all interfaces first, so that a configuration error fails before
    # the traffic runs
    my @nics = map { prepare_nic($_) } @names;
    my %seen;
    die "Network interface $_ is selected more than once" for grep { $seen{$_}++ } @names;

    # Test one card at a time, so that the counters belong to one card
    $self->test_nic($_, $info, $map, $duration) for @nics;
}

sub post_fail_hook {
    my ($self) = @_;
    select_serial_terminal;
    my $logs = '/var/log/irq-delivery-network';
    script_run("mkdir -p $logs; cat /proc/interrupts > $logs/interrupts.txt; dmesg > $logs/dmesg.txt");
    upload_logs("$logs/$_", failok => 1) for qw(interrupts.txt dmesg.txt);
    $self->SUPER::post_fail_hook;
}

sub test_flags {
    return {fatal => 1};
}

1;

=head1 Description

Work in progress: this test does not generate traffic yet.

Exercise network card interrupts on a system with more than eight online
CPUs on at least two sockets (poo#49517). This is the network counterpart
of C<irq_delivery_storage>. For each selected network interface, the test
finds the interrupts of its PCI card, records which of them go through
interrupt remapping, and records the new interrupts per socket and per NUMA
node. The kernel must not be tainted: a transmit queue timeout of the card,
as seen with the original regression, triggers a kernel warning.

Planned: a peer machine sends and receives traffic with one stream per
CPU, so that all queues of the card get interrupts. The test then fails if
the card gets no new interrupts or a stream fails.

=head1 Configuration

=head2 IRQ_DELIVERY_DEVICE

Required network interface names, separated by spaces, for example
C<eth2>. Each interface must be up and belong to a PCI network card.
Loopback, bridge, bond and other virtual interfaces are not supported.

=head2 IRQ_DELIVERY_DURATION

Traffic duration in seconds. Defaults to C<30>. Not used until the test
generates traffic.

=head2 LTP_TAINT_EXPECTED

Mask of the kernel taint flags that are expected and do not fail the test.
See C<check_kernel_taint> in C<LTP::utils>.

=cut
