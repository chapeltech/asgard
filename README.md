# Asgard

Asgard is a Kerberos appliance. It runs a Heimdal KDC with `bifrost`,
`krb5_admind`, kpasswd, snapshot support, and the supporting admin tooling.

The current published image is:

```text
ghcr.io/chapeltech/asgard-kdc:sha-280c050b28b7
```

Use the included compose file:

```text
docker-compose.yml
```

## Pull the Image

If the GitHub Container Registry package is public:

```sh
docker pull ghcr.io/chapeltech/asgard-kdc:sha-280c050b28b7
```

Then pull through compose:

```sh
docker compose pull
```

## Configure

```sh
export ASGARD_IMAGE=ghcr.io/chapeltech/asgard-kdc:sha-280c050b28b7
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

The container starts its services after initialization completes.

## Create an Admin Principal

```sh
docker compose exec kdc /cmd create-admin admin
docker compose exec kdc krb5_admin -l modify admin attributes-=needchange
```

The first command prints the generated admin password.

## Export Client Files

```sh
docker compose exec kdc /cmd print-krb5-conf > krb5.conf
docker compose exec kdc /cmd print-ca > ca-pub.pem
```

Install `krb5.conf` on clients and make sure the hostname configured in
`ASGARD_HOSTNAME` resolves to the Docker host.

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

With the stock `docker-compose.yml`, removing the container removes the initialized
realm state too. Use `stop` and `start` for normal operation.
