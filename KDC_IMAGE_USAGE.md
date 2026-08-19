# Running Asgard

The only published image is:

```text
ghcr.io/chapeltech/asgard:latest
```

The other Docker targets in this repository are used only by the build and
test suite. Use the included Compose file:

```text
docker-compose.yml
```

## Login and Pull

If the package is private, log in to GHCR on the target host:

```sh
export GITHUB_USER=<github-user>
export GHCR_TOKEN=<token-with-read-packages>

echo "$GHCR_TOKEN" |
    docker login ghcr.io -u "$GITHUB_USER" --password-stdin
```

Pull the image:

```sh
docker compose pull
```

The included Compose file keeps appliance state in the `kdc` named volume
and restarts the container after host reboots.

## Configure

Optional `.env` file:

```sh
ASGARD_IMAGE=ghcr.io/chapeltech/asgard:latest
ASGARD_HOSTNAME=kdc1.example.com
```

`ASGARD_HOSTNAME` must resolve to the Docker host from clients.

## Initialize the Realm

Start Asgard and initialize the realm:

```sh
docker compose up -d kdc
docker compose exec kdc /cmd setup-master EXAMPLE.COM
```

Do not initialize the same realm data again.

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

Install `krb5.conf` on clients, and make sure `kdc1.example.com` resolves to the
Docker host.

## Operate

View logs:

```sh
docker compose logs -f kdc
```

Stop:

```sh
docker compose stop
```

Start it again:

```sh
docker compose start
```
