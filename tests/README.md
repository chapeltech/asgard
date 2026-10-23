# Focused Tests

Run from the repository root. The focused commands use existing images without
building or publishing them. The broad runner described below does build images.

## Service Wiring

```sh
sh tests/actiond.sh
sh tests/asgard.sh
```

`actiond.sh` requires Bubblewrap and unprivileged user namespaces. It isolates
the filesystem and mocks service commands. It checks the setup gate, master-only
worker, missing master identity, master iprop waiting for an ACL (including an
empty ACL), slave iprop starting without one, Supervisor child-process handling,
master-only worker readiness, and clearing a stale master ACL before Supervisor
starts while keeping HTTPS disabled.

## Appliance Acceptance

```sh
sh tests/appliance.sh asgard/kdc:action-queue-review asgard/client:action-queue-review \
    > /tmp/asgard-actiond-appliance.log 2>&1
```

Use tags built by the image owner with the changes under review. The KDC image
must contain `bifrost actiond` and this repository's scripts and Supervisor
configuration. The Kerberos administration packages must queue notifications
when the Bifrost action schema is present; the client must accept the KDC's
`krb5_admin/HOST@REALM` notification credentials. Older `master-slave-review`
images are not sufficient for the worker tests.

The harness requires Docker, its Compose plugin, and `/var/run/docker.sock`.
It creates and removes its own network, containers, and test realm volumes.
Image tags are resolved to local image IDs at startup, so recreating a container
cannot switch builds if a tag changes during the test. Do not edit the executing
test scripts until the run exits.
The client image runs the test driver and a separately enrolled host client.
The test uses appliance commands, Kerberos operations, Supervisor controls, and
action-query APIs, without inspecting KDC internal files, keys, or SQL.

`appliance.sh` includes `appliance-actions.sh` after slave enrollment. It checks:

- Master and slave setup, approval, ticket issuance and renewal, PKINIT, KX509,
  incremental HDB and administrative replication, and recreation of both KDC
  containers.
- Stopping the master worker makes readiness fail while local Bifrost and
  remote `krb5_admin` mutations return with work still queued.
- A slave with a copied queued action does not claim it, including after
  container recreation; stopping its idle worker does not affect readiness.
- Restarting the master worker completes the same action and delivers usable
  client credentials without another mutation.
- An unavailable client produces a visible failed action; starting the client
  lets the same action retry automatically without `retry_action` or another
  mutation.
- The optional Bifrost HTTPS listener remains disabled on both KDCs.

The driver has a fifteen-minute overall timeout to allow enrollment,
administrative replication, and the sixty-second automatic retry interval.

## Debian/Rocky Matrix

```sh
sh tests/action-queue.sh asgard/kdc:action-queue-review \
    asgard/client:action-queue-review asgard/rocky96-public:latest
```

This separate matrix requires Docker with privileged systemd containers and
cgroup support, plus `jq` and `timeout` on the host. It does not build or pull
images. Rocky 9.6 uses the packages from `repo.chapeltech.uk`.

It verifies real KNC delivery with KDC HTTPS disabled, usable tickets and
certificate chains, recipient PKINIT, stopped-worker queuing, restart draining,
and the sixty-second automatic retry on Debian and Rocky. Logical-host
`modify_host member+=` must deliver to both physical members. Scheduled client
fetches are masked so they cannot hide a notification failure.

## Final Results

2026-09-22: final-image appliance acceptance passed with exit status 0 on native
Linux amd64, including cleanup. The matrix owner separately confirmed the final
Debian/Rocky matrix passed. Image IDs:

- `asgard/kdc:action-queue-review`: `0923da18ae57`
- `asgard/client:action-queue-review`: `da1df2d4fb38`
- `asgard/rocky96-public:latest`: `4d5d71b3e2ca`

The appliance log is `/tmp/asgard-actiond-appliance.log`; its first line records
the full KDC/client image IDs. All appliance checks passed, with both test scripts
unchanged during the run. Fixture setup uses local appliance host creation and
explicit appid ownership for the remote administrator. Delivered credentials
are tested as their recipient, without changing production authorization.

## Broad Runner

```sh
./run-tests -P
```

`run-tests` always runs `tests/appliance.sh asgard/kdc asgard/client` after
building the KDC/client images. With `-P`, it also builds the Rocky 9.6
public-package image and invokes
`tests/action-queue.sh asgard/kdc asgard/client asgard/rocky96-public` before
starting the broader Compose tests. The matrix uses its own HTTPS-disabled KDC,
independent of the broader suite's HTTPS-enabled tests.

The broad runner was not run for the focused acceptance above and is not needed
to repeat it.
