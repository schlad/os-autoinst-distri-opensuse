# SUSE's openQA tests
#
# Copyright 2024 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: Base module for security tests.
# Maintainer: QE Security <none@suse.de>

package security_boot_utils;

use base Exporter;

use strict;
use warnings;
use opensusebasetest;
use grub_utils qw(grub_test);
use utils;
use testapi;
use Utils::Architectures;
use security::config;
use version_utils 'is_sle';

our @EXPORT = qw(
  boot_has_no_video
  boot_encrypt_no_video
);

sub boot_has_no_video {
    my $is_encrypted = check_var('FULL_LVM_ENCRYPT', '1') || check_var('ENCRYPT', '1');
    return ($is_encrypted && is_aarch64);
}

sub boot_encrypt_no_video {
    my ($self) = shift;

    grub_test;
    # used, for example, by aarch64 on 15-SP5 QR (https://progress.opensuse.org/issues/156655)
    assert_screen 'encrypted-disk-no-video';
    wait_serial("Please enter passphrase for disk.*");
    my $password = check_var('SYSTEM_ROLE', 'Common_Criteria') ? $security::config::strong_password : $testapi::password;
    type_string_slow("$password");
    send_key 'ret';
    wait_still_screen 15;
    $self->wait_boot_past_bootloader;
}

1;
