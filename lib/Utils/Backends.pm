# Copyright (C) 2018-2019 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

=head1 Backends

=head1 SYNOPSIS

use Utils::Backends
It defines various functions that allows to check for different backend or console types. It exports C<CONSOLES> and C<BACKEND>

=cut

package Utils::Backends;
use strict;
use warnings;

use base 'Exporter';
use Exporter;
use testapi ':DEFAULT';

use constant {
    BACKEND => [
        qw(
          is_remote_backend
          has_ttys
          has_serial_over_ssh
          is_hyperv
          is_hyperv_in_gui
          is_svirt_except_s390x
          is_pvm
          is_xen_pv
          is_ipmi
          is_qemu
          is_svirt
          is_image_backend
          )
    ],
    CONSOLES => [
        qw(
          set_sshserial_dev
          unset_sshserial_dev
          use_ssh_serial_console
          set_ssh_console_timeout
          )
    ]
};

our @EXPORT = (@{(+CONSOLES)}, @{+BACKEND});

our %EXPORT_TAGS = (
    CONSOLES => (CONSOLES),
    BACKEND  => (BACKEND)
);

sub set_sshserial_dev {
    $serialdev = 'sshserial';
    set_var('SERIALDEV', $serialdev);
    bmwqemu::save_vars();
}

sub unset_sshserial_dev {
    $serialdev = get_var('SERIALDEV_');
    set_var('SERIALDEV', $serialdev);
    bmwqemu::save_vars();
}

# Use it after SUT boot finish, as it requires ssh connection to SUT to
# interact with SUT, including window and serial console

=head2 use_ssh_serial_console

Selects the root-ssh and saves it to SERIALDEV

=cut

sub use_ssh_serial_console {
    select_console('root-ssh');
    set_sshserial_dev;
}

=head2 is_remote_backend

Returns true if the current instance is running as remote backend

=cut

sub is_remote_backend {
    # s390x uses only remote repos
    return check_var('ARCH', 's390x') || (get_var('BACKEND', '') =~ /ipmi|svirt/) || is_pvm();
}

# In some cases we are using a VNC connection provided by the hypervisor that
# allows access to the ttys same as for accessing any remote libvirt instance
# but not what we use for s390x-kvm.

=head2 has_ttys

Returns true if the current instance is using ttys

=cut

sub has_ttys {
    return ((get_var('BACKEND', '') !~ /ipmi|s390x|spvm|pvm_hmc/) && !get_var('S390_ZKVM') && !(check_var('BACKEND', 'generalhw') && !defined(get_var('GENERAL_HW_VNC_IP'))) && !get_var('PUBLIC_CLOUD'));
}

=head2 has_serial_over_ssh

Returns true if the current instance is using a serial through ssh

=cut

sub has_serial_over_ssh {
    return ((get_var('BACKEND', '') =~ /^(ikvm|ipmi|spvm|pvm_hmc|generalhw)/) && !defined(get_var('GENERAL_HW_VNC_IP')) && !defined(get_var('GENERAL_HW_SOL_CMD')));
}

=head2 is_hyperv

Returns true if the current instance is running as hyperv backend

=cut

sub is_hyperv {
    my $hyperv_version = shift;
    return 0 unless check_var('VIRSH_VMM_FAMILY', 'hyperv');
    return defined($hyperv_version) ? check_var('HYPERV_VERSION', $hyperv_version) : 1;
}

=head2 is_hyperv_in_gui

Returns true if the current instance is running as hyperv gui backend

=cut

sub is_hyperv_in_gui {
    return is_hyperv && !check_var('VIDEOMODE', 'text');
}

=head2 is_xen_pv

Returns true if the current VM runs in Xen host in paravirtual mode 

=cut

sub is_xen_pv {
    return check_var('VIRSH_VMM_FAMILY', 'xen') && check_var('VIRSH_VMM_TYPE', 'linux');
}

=head2 is_svirt_except_s390x

Returns true if the current instance is running as svirt backend except s390x

=cut

sub is_svirt_except_s390x {
    return !get_var('S390_ZKVM') && check_var('BACKEND', 'svirt');
}

=head2 is_pvm

Returns true if the current instance is running as PowerVM backend 'spvm' or 'hmc_pvm'

=cut

sub is_pvm {
    return check_var('BACKEND', 'spvm') || check_var('BACKEND', 'pvm_hmc');
}

=head2 is_ipmi

Returns true if the current instance is running as ipmi backend

=cut

sub is_ipmi {
    return check_var('BACKEND', 'ipmi');
}

=head2 is_qemu

Returns true if the current instance is running as qemu backend

=cut

sub is_qemu {
    return check_var('BACKEND', 'qemu');
}

=head2 is_svirt

Returns true if the current instance is running as svirt backend

=cut

sub is_svirt {
    return check_var('BACKEND', 'svirt');
}

=head2 is_image_backend

Returns true if the current instance is running on backend with image support

=cut

sub is_image_backend {
    return (is_qemu || is_svirt);
}

#This subroutine takes absolute file path of sshd config file and desired ssh connection timeout as arguments
#The ssh connection timeout is counted as seconds
sub set_ssh_console_timeout {
    my ($sshd_config_file, $sshd_timeout) = @_;
    my $client_count_max = $sshd_timeout / 60;
    script_run("sed -irnE 's/^.*TCPKeepAlive.*\$/TCPKeepAlive yes/g; s/^.*ClientAliveInterval.*\$/ClientAliveInterval 60/g; s/^.*ClientAliveCountMax.*\$/ClientAliveCountMax $client_count_max/g' $sshd_config_file");
    script_run("service sshd restart") if (script_run("systemctl restart sshd") ne '0');
}

1;
