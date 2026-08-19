# Asgard

Asgard is a Kerberos appliance. It runs a Heimdal KDC with `bifrost`,
`krb5_admind`, kpasswd, snapshot support, and the supporting admin tooling.

The published image is:

```text
ghcr.io/chapeltech/asgard:latest
```

This is the only published Asgard image. The client and other Docker stages
exist only to build and test the appliance.

Use the included compose file:

```text
docker-compose.yml
```

## Configure

```sh
export ASGARD_HOSTNAME=kdc.example.com
```

`ASGARD_HOSTNAME` must resolve to the Docker host from clients. Use real
host naming, or add it to client `/etc/hosts`.

## First Start

Start the appliance:

```sh
docker compose up -d kdc
```

Initialize the realm inside the running container:

```sh
docker compose exec kdc /cmd setup-master EXAMPLE.COM
```

`bifrostd` is disabled by default. To enable it after setup:

```sh
docker compose exec kdc bifrost -l modify_config bifrostd=1
docker compose restart kdc
```

Use `bifrostd=0` to disable it. Set this on the master: it is stored in
`krb5_admin.db` and replicated to slaves. Each KDC applies it on restart.

The container starts its services after initialization completes.

## Create an Admin Principal

```sh
docker compose exec kdc /cmd create-admin admin
docker compose exec kdc krb5_admin -l modify admin attributes-=needchange
```

The first command prints the generated admin password.

## Export the CA Certificate

```sh
docker compose exec kdc /cmd print-ca > ca-pub.pem
```

Install `ca-pub.pem` on clients.

## Operate

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
