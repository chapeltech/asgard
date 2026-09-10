# Asgard

Asgard is a Kerberos appliance. It runs a Heimdal KDC with `bifrost`,
`krb5_admind`, kpasswd, snapshot support, and the supporting admin tooling.

The published image is:

```text
ghcr.io/chapeltech/asgard:latest
```

This is the only published Asgard image. The client and other Docker stages
exist only to build and test the appliance.

## First Start

Run `asgard` in a directory for the new KDC:

```sh
asgard setup-master EXAMPLE.COM kdc.example.com
```

The script writes `docker-compose.yml`, starts the container, and initializes
the realm. It requires Docker with the Compose plugin. The hostname defaults
to the local fully qualified hostname when omitted.

The generated Compose project uses the published image, host networking, a
persistent `/var/heimdal` volume, and `restart: unless-stopped`.

`bifrostd` is disabled by default. To enable it after setup:

```sh
asgard bifrost modify_config bifrostd=1
docker compose restart kdc
```

Use `bifrostd=0` to disable it. Set this on the master: it is stored in
`krb5_admin.db` and replicated to slaves. Each KDC applies it on restart.

The container starts its services after initialization completes.

## Set Up a Slave

On the new KDC host, obtain administrative Kerberos credentials for the realm
and run:

```sh
asgard setup-slave EXAMPLE.COM
```

The command discovers the master, downloads the realm CA over the authenticated
`krb5_admin` connection, creates `docker-compose.yml`, and prepares enrollment.
It prints an approval command containing the new host's bootstrap binding. Run
that command in the master's Asgard directory:

```sh
asgard approve-slave EXAMPLE.COM slave.example.com BINDING
```

Then repeat `asgard setup-slave EXAMPLE.COM` on the new host. It obtains the KDC
service keys, receives full Kerberos and administrative database propagation,
and installs its PKINIT and KX509 identities before starting Kerberos. The
master retains the root CA private key. No keytabs are copied between KDCs.

The local fully qualified hostname is used by default; pass it after the realm
when it must be overridden:

```sh
asgard setup-slave EXAMPLE.COM slave.example.com
```

Slave enrollment requires the `krb5_admin`, `klist`, and `hxtool` client commands.
It does not require the Bifrost HTTPS listener. Setup can be retried after a
failed activation; a successful command reports that the local KDC is ready.

## Create an Admin Principal

```sh
asgard create-admin admin
```

The command prints the generated admin password. Run `kinit admin@EXAMPLE.COM`
on the administrative client and complete its initial password-change prompt.

## Export the CA Certificate

```sh
asgard print-ca > ca-pub.pem
```

Install `ca-pub.pem` on clients.

## Operate

Check readiness:

```sh
asgard status
```

Advanced local administration is available without opening a shell:

```sh
asgard bifrost query_realm EXAMPLE.COM
```

View logs:

```sh
docker compose logs -f kdc
```

Stop:

```sh
docker compose stop
```

Start again:

```sh
docker compose start
```

Remove the container:

```sh
docker compose down
```

The initialized realm remains in the `kdc` named volume when the container is
removed.  `docker compose down -v` removes that volume and its realm state.
