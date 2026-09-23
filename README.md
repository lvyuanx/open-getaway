# Open-Getaway

Open-Getaway is an Nginx reverse proxy for Linux servers. It exposes one public
entry point and routes requests to services running in separate Docker Compose
projects through a shared Docker network.

## Architecture

```text
client -> gateway:80/443 -> open-getaway-network -> service container
```

The gateway Compose project creates a bridge network named exactly
`open-getaway-network`. A child project only needs to join that network; the
gateway resolves the child service by its Docker Compose service name.

Only the gateway should publish ports on the host. A child service normally
uses `expose` (or no port declaration) instead of publishing a host port.

## Start the gateway

The host needs Docker Engine and Docker Compose v2 or newer.

```bash
docker compose up -d --build
```

The gateway responds to its built-in health endpoint:

```bash
curl http://127.0.0.1/healthz
```

The expected response is `ok`.

The `443` port is reserved. Certificates are mounted read-only from
`nginx/letsencrypt` to `/etc/letsencrypt` inside the gateway. Add an HTTPS
`server` block before enabling TLS in a real environment.

## Request a Let's Encrypt certificate

The repository provides `scripts/issue-letsencrypt.sh`. It uses the official
Certbot Docker image in standalone mode. The gateway does not need to be
running before the first request. If it is running, the script stops only the
`gateway` service while Certbot uses host port 80, then restores the gateway to
its previous state.

Before running the script:

- Point every requested domain's DNS A/AAAA record to this server;
- Allow inbound TCP ports 80 and 443;
- Make sure port 80 is not occupied by another host process;
- Use a real email address for the ACME account.

Request a certificate for `lvyx.cc`:

```bash
./scripts/issue-letsencrypt.sh \
  --domain lvyx.cc \
  --email admin@lvyx.cc
```

Include `www.lvyx.cc` only after its DNS record points to the same server:

```bash
./scripts/issue-letsencrypt.sh \
  --domain lvyx.cc \
  --domain www.lvyx.cc \
  --email admin@lvyx.cc
```

The first domain is the certificate name. The resulting files are stored under
`nginx/letsencrypt/live/<first-domain>/` and are available inside Nginx under
`/etc/letsencrypt/live/<first-domain>/`.

After copying the HTTPS `server` block from
`nginx/conf.d/service.conf.example` into a real service config, check and reload
Nginx:

```bash
docker compose exec gateway nginx -t
docker compose exec gateway nginx -s reload
```

The certificate script also supports renewal:

```bash
./scripts/issue-letsencrypt.sh renew --dry-run
./scripts/issue-letsencrypt.sh renew
docker compose exec -T gateway nginx -s reload
```

Run the renewal command from a systemd timer or cron job. The gateway is
temporarily stopped and restored during standalone renewal as well.

## Add one service

Copy the example once for each service:

```bash
cp nginx/conf.d/service.conf.example nginx/conf.d/order-api.conf
```

Edit `order-api.conf` and replace:

- `service.example.com` with the public hostname;
- `<service-name>` with the child Compose service name;
- `<container-port>` with the port listened to inside that container.

For example, a service named `order-api` listening on port `8080` can be
exposed as `api.example.com` with:

```nginx
server {
    listen 80;
    server_name api.example.com;

    location / {
        set $order_api_upstream http://order-api:8080;
        proxy_pass $order_api_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
```

The variable form of `proxy_pass` uses Docker's embedded DNS resolver at
request time. The child container can start after the gateway, and replacing a
child container with a new IP does not require restarting the gateway.

The `.example` file is intentionally excluded from the Nginx `*.conf` include.
It becomes active only after it is copied to a file ending in `.conf`.

## Connect a child Compose project

The child project joins the already-created network as an external network:

```yaml
services:
  order-api:
    image: example/order-api:latest
    expose:
      - "8080"
    networks:
      - gateway

networks:
  gateway:
    external: true
    name: open-getaway-network
```

Start the gateway before starting a child project so the external network
exists:

```bash
docker compose up -d
```

The target process must listen on `0.0.0.0:8080` inside its container. A
process bound only to `127.0.0.1` cannot be reached by the gateway container.

## Check and reload configuration

After adding or editing a service file, validate the complete Nginx
configuration:

```bash
docker compose exec gateway nginx -t
```

If validation succeeds, reload Nginx without rebuilding or restarting the
gateway container:

```bash
docker compose exec gateway nginx -s reload
```

If validation fails, the reload is rejected and the currently active
configuration remains in use.

Useful diagnostics:

```bash
docker network inspect open-getaway-network
docker compose exec gateway getent hosts order-api
docker compose logs gateway
```

## Path-based routing

The default example uses one hostname per service. A service can instead be
mounted below a path:

```nginx
location /orders/ {
    set $order_api_upstream http://order-api:8080;
    rewrite ^/orders/(.*)$ /$1 break;
    proxy_pass $order_api_upstream;
}
```

The rewrite makes `/orders/users` reach the upstream as `/users` while keeping
dynamic Docker DNS resolution. Static `proxy_pass` examples showing the
trailing-slash URI behavior are also included in
`nginx/conf.d/service.conf.example`.

For frontend applications, configure static files and SPA history fallback in
the frontend container. The gateway forwards requests and does not read files
from the child project's host filesystem.

## Repository safety

Deployment-specific `*.conf` files, environment files, Certbot state,
certificates and private keys are ignored by Git. Keep only sanitized examples
in this repository.
