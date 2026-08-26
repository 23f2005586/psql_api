# SQL Runner API

Self-hosted SQL execution API for a SQL-learning website.

Designed for a dedicated Azure Ubuntu 24.04 VM (2 vCPU / 1 GB RAM).  
It does **not** connect to any production website database.

## Architecture

```
Internet
   |
   v
Nginx (80/443)          ← configure later
   |
   v
Node.js API (:3000 on 127.0.0.1 only)
   |
   |  private Docker network: sql-network
   v
PostgreSQL 16 Alpine    ← port 5432 NOT published
```

## Project layout

```
/opt/sql-runner/
├── api/
│   ├── server.js
│   ├── package.json
│   ├── Dockerfile
│   ├── .env.example
│   └── .gitignore
├── postgres/
│   ├── 01_create_user.sh
│   └── init.sql
├── scripts/
│   ├── test-api.sh
│   └── deploy-to-opt.sh
├── docker-compose.yml
├── .env.example
└── README.md
```

## Requirements

- Docker Engine + Docker Compose plugin
- (Optional) Nginx on the host for HTTPS later

Do **not** install or expose PostgreSQL on the host. Use the Compose service only.

## Installation

### On the Azure SQL VM

```bash
# 1) Copy this project to the VM, then:
sudo ./scripts/deploy-to-opt.sh

# 2) Edit secrets
sudo nano /opt/sql-runner/.env
sudo nano /opt/sql-runner/api/.env

# 3) Start
cd /opt/sql-runner
sudo docker compose up -d --build
```

### From this repo (local copy)

```bash
cp .env.example .env
cp api/.env.example api/.env
# Edit both files — set strong random values for:
#   POSTGRES_BOOTSTRAP_PASSWORD, PGPASSWORD, API_KEY
# Keep PGPASSWORD the same in .env and api/.env

docker compose up -d --build
```

## Environment variables

### Root `.env` (Compose + Postgres init)

| Variable | Purpose |
|----------|---------|
| `POSTGRES_BOOTSTRAP_PASSWORD` | Internal Postgres bootstrap superuser (init only; never used by the API) |
| `PGPASSWORD` | Password for the non-superuser `playground` role |

### `api/.env` (API process)

| Variable | Purpose |
|----------|---------|
| `API_KEY` | Shared secret; website **backend** sends `Authorization: Bearer <API_KEY>` |
| `PGHOST` | Docker service name `postgres` (not localhost) |
| `PGPORT` | `5432` |
| `PGDATABASE` | `playground` |
| `PGUSER` | `playground` |
| `PGPASSWORD` | Same as root `.env` |
| `PORT` | `3000` |
| `HOST` | `0.0.0.0` (inside container; host maps `127.0.0.1:3000`) |
| `RATE_LIMIT_WINDOW_MS` | Rate-limit window (default `60000`) |
| `RATE_LIMIT_MAX` | Max requests per window per IP (default `60`) |
| `BODY_LIMIT` | Max JSON body size (default `16kb`) |

**Never put `API_KEY` or database passwords in frontend JavaScript.**  
Only your website backend should call this API.

## Start / stop / restart

```bash
cd /opt/sql-runner

# Start (build if needed)
docker compose up -d --build

# Stop
docker compose down

# Restart
docker compose restart

# Rebuild API after code changes
docker compose up -d --build api
```

## Logs

```bash
docker compose logs -f
docker compose logs -f api
docker compose logs -f postgres
```

## Health check

```bash
curl -s http://127.0.0.1:3000/health
# {"ok":true}
```

## API usage

### `POST /api/run-sql`

```bash
curl -s http://127.0.0.1:3000/api/run-sql \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{"query":"SELECT * FROM employees"}'
```

Successful response shape:

```json
{
  "success": true,
  "columns": ["id", "name", "department", "salary"],
  "rows": [[1, "John", "IT", 60000]],
  "rowCount": 1,
  "truncated": false
}
```

### Behaviour

1. Validates `query` is a non-empty string  
2. Limits request body size  
3. Requires API key  
4. Rate limits by IP  
5. Connects **only** to the playground database  
6. Runs each request in a transaction:

   ```text
   BEGIN
   SET LOCAL statement_timeout = '3000'
   <user SQL>
   ROLLBACK
   ```

   So `INSERT` / `UPDATE` / `DELETE` / `CREATE` / `DROP` do not permanently change the shared DB.

7. Caps returned rows at **1000** in Node.js (does not rewrite user SQL with `LIMIT`)  
8. Returns useful SQL errors; never echoes passwords  

## Test suite

```bash
export API_KEY='your-key-from-api/.env'
./scripts/test-api.sh
# or
./scripts/test-api.sh http://127.0.0.1:3000
```

Covers: SELECT, INSERT/UPDATE/DELETE + rollback, GROUP BY, JOIN, invalid SQL, 3s timeout, >1000 rows, unauthorized.

### Manual curl examples

```bash
KEY='your-api-key'
H=(-H "Content-Type: application/json" -H "Authorization: Bearer $KEY")

# SELECT
curl -s http://127.0.0.1:3000/api/run-sql "${H[@]}" \
  -d '{"query":"SELECT * FROM employees;"}'

# GROUP BY
curl -s http://127.0.0.1:3000/api/run-sql "${H[@]}" \
  -d '{"query":"SELECT department, AVG(salary) FROM employees GROUP BY department;"}'

# JOIN
curl -s http://127.0.0.1:3000/api/run-sql "${H[@]}" \
  -d '{"query":"SELECT e.name, d.name FROM employees e JOIN departments d ON e.department = d.name;"}'
```

## Change the API key

1. Edit `api/.env` → set a new `API_KEY`  
2. `docker compose up -d --force-recreate api`  
3. Update the same key in your **website backend** (not the frontend)

## Change sample SQL data

1. Edit `postgres/init.sql`  
2. Reset the playground volume (see below) so init scripts run again  

## Reset the playground database

Destroys all playground data and re-runs `init.sql`:

```bash
cd /opt/sql-runner
docker compose down
docker volume rm sql-runner-postgres-data
docker compose up -d --build
```

## Firewall notes

- Do **not** open port `5432`  
- Do **not** expose port `3000` publicly; keep the Compose bind on `127.0.0.1:3000`  
- Public ports should only be: `22`, `80`, `443`  
- Point Nginx at `http://127.0.0.1:3000` for `https://sql-api.MYDOMAIN.com` when ready  

## Security summary

- Untrusted SQL from learners  
- Non-superuser DB role `playground`  
- No Postgres port on the host  
- No Docker socket mounted into the API  
- API filesystem read-only in Compose  
- API key required; secrets only in `.env`  
- Statement timeout 3s; body size limit; rate limit; max 1000 rows returned  
- Every statement runs inside a transaction that always rolls back  

## Nginx (later)

Example upstream only — enable HTTPS when the API is verified:

```nginx
server {
    listen 80;
    server_name sql-api.MYDOMAIN.com;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```
