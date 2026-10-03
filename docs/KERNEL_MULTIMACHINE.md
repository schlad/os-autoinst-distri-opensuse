# Kernel multimachine tests with a topology

This guide explains how to write and run kernel multimachine tests where
a YAML file describes the machines. It is mainly meant for bare metal,
where machines have real names, addresses, cards and disks, but it also
works with QEMU.

## When to use it

Use a topology when:

* the test runs on bare metal machines, so peer names and addresses are
  not fixed by openQA
* the setup has more than a server and a client, for example a router
  between two networks
* a machine takes part without running an openQA job, for example a
  storage appliance
* several tests use the same machines

Plain two-node QEMU tests do not need it: openQA already gives them fixed
host names and a fixed network.

## How it works

```
test_data/kernel/multimachine/<setup>.yaml   machines, roles, networks, interfaces
        |  included by the schedule
        v
openQA scheduler -> test_data
        |
        v
Kernel::multimachine_topology                reads and validates it, answers questions:
        |                                    which node am I, who are my peers,
        |                                    which interface, which network
        v
kernel/mm_barriers                           creates the barriers
Kernel::net_tests and other libraries        set up the machine
test modules                                 the actual test
```

The same test modules run on any setup. A different pair of machines or
other addresses only need another YAML file and a schedule that includes
it. Each job only needs its `ROLE` and the worker it runs on.

## The topology file

The examples in this guide use a two machine "hello" setup to show the
pieces. They are not in the repository; the complete example is listed at
the end of "The test module".

```yaml
multimachine_topology:
  name: hello_2hosts

  networks:
    - id: lab
      ipv4_cidr: "10.146.14.0/23"

  nodes:
    - id: coppi              # unique name of the node
      role: sut              # matches ROLE of the job on this machine
      interfaces:
        - id: eno1           # interface name on the machine
          network: lab       # id of a network above
          ipv4: "10.146.14.87"

    - id: merckx
      role: peer
      interfaces:
        - id: eno1
          network: lab
          ipv4: "10.146.14.90"
```

Fields:

* `networks`: `id`, and `ipv4_cidr` or `ipv6_cidr`.
* `nodes`: `id` and `role` (both unique) and `interfaces`.
  * `external: 1` marks a node that does not run a job, for example a
    storage appliance. Other nodes can look it up, but it does not take
    part in barriers.
* `interfaces`: `id`, `network`, and optionally `ipv4` and `ipv6`.
  * `static: 1` means that the test adds the addresses. Without it, the
    addresses come from the lab network, for example from DHCP, and the
    test only waits for them.
* Tests can add their own keys, for example `storage_devices` of a node
  for `irq_delivery_storage`. Only the test that uses a key defines its
  meaning.

## The schedule

```yaml
name: hello_2hosts
vars:
    INST_AUTO: agama_auto/sle_default_ipmi.jsonnet
    DESKTOP: textmode
test_data:
    <<: !include test_data/kernel/multimachine/hello_2hosts.yaml
    multimachine_barriers:
        - HELLO_READY
        - HELLO_DONE
schedule:
    - kernel/mm_barriers        # first, before the installation
    - installation/ipxe_install
    - installation/agama_reboot
    - installation/grub_test
    - installation/first_boot
    - kernel/hello              # the test
```

Both jobs use the same schedule. Barrier names belong to the test code, so
they are in the schedule, not in the topology file.

`kernel/mm_barriers` creates the barriers in `multimachine_barriers` for
the number of nodes that run a job. Every job schedules it; only the
first node that runs a job creates the barriers. It is the only generic
module: each test sets up what it needs on the machine itself, see the
next section.

## The test module

```perl
use Mojo::Base 'opensusebasetest';
use testapi;
use lockapi;
use Kernel::multimachine_topology qw(get_local_node get_peers get_node_interface);
use Kernel::net_tests qw(set_link_up wait_for_ipv4_addr);

sub run {
    my $me = get_local_node();
    my $if = get_node_interface($me, 0);
    set_link_up($if->{id});
    wait_for_ipv4_addr($if->{id}, $if->{ipv4});
    barrier_wait({name => 'HELLO_READY', check_dead_job => 1});
    for my $peer (@{get_peers($me)}) {
        my $ip = get_node_interface($peer, 0)->{ipv4};
        assert_script_run("ping -c 3 $ip");
        record_info('Hello', "$me->{id} ($me->{role}) reached $peer->{id} at $ip");
    }
    barrier_wait({name => 'HELLO_DONE', check_dead_job => 1});
}
```

Helpers of `Kernel::multimachine_topology` (see its POD):

| Helper | Returns |
|---|---|
| `get_local_node()` | the node of this job, from `ROLE` |
| `get_node_by_role($role)` | the node with that role |
| `get_peers($node)` | all other nodes, external ones included |
| `get_job_nodes()` | the nodes that run a job |
| `get_node_interface($node, $index)` | an interface entry of a node |
| `get_topology_network($id)` | a network entry |
| `get_topology()` | the whole topology |
| `require_field($value, $message)` | `$value`, or dies with `$message` |

The topology library only reads the topology; it does not change the
machine. Libraries such as `Kernel::net_tests` set up the machine with
getters and setters that take plain values, for example an interface
name and an address, not topology entries. The test module reads the
topology and passes the values on. `setup_interface` in
`irq_delivery_network` also adds `static` addresses.

Use `check_dead_job => 1` in `barrier_wait`, so that a job stops waiting
when the other job died, instead of hanging until the timeout.

A complete example is `irq_delivery_network` with
`schedule/kernel/agama_irq_delivery_2hosts_baremetal.yaml` and
`test_data/kernel/multimachine/irq_delivery_2hosts.yaml`. The same schedule
also runs `irq_delivery_storage`, a single machine test, on each node: it
does not talk to the other node and only takes the disks of the local node
from the topology (`storage_devices`).

## Running it in openQA

A multimachine test needs one job per node that runs a job:

* each job has its own `ROLE` and `WORKER_CLASS` (the machine)
* the jobs are linked with `PARALLEL_WITH`, so that they start together
* both jobs use the same `YAML_SCHEDULE`

In a job group, define one test suite per role.
