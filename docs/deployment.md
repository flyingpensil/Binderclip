# Deployment

## Local development

`scripts/start.ps1` starts the demo on loopback port 8001. Local demo authentication requires both `DEBUG=true` and `DEMO_LOGIN=true`. Production startup requires an explicit `SECRET_KEY` and PostgreSQL configuration. Do not use the SQLite preview for multiple financial users.

## PostgreSQL / Docker

Docker is optional and was not available in the development environment. The container configuration is supplied for review and deployment; it is not a claim that a container build has been run.

1. Copy `.env.example` to `.env` and replace the secret key, database password, domain, trusted CSRF origin and Google credentials. Production values must use the actual HTTPS hostname. `DEBUG=false`, `DEMO_LOGIN=false`.
2. Build, start PostgreSQL, migrate and collect static assets into the named static volume:

```sh
docker compose build
docker compose up -d db
docker compose run --rm web python manage.py migrate
docker compose run --rm web python manage.py collectstatic --noinput
docker compose run --rm web python manage.py bootstrap_company --name "Your Logistics LLC" --email "admin@gmail.com"
docker compose up -d web
```

Static assets must persist across the `run` and `web` containers. The Compose `static_data` volume is mounted at `/app/staticfiles`, with initial ownership supplied by the image. Re-run collectstatic after each application update. Alternatively, bake collected static files into a release image with temporary build-only settings and deploy that immutable image.

3. Run an HTTPS reverse proxy such as Caddy or nginx in front of loopback `127.0.0.1:8000`. The app binds only to loopback on the host; PostgreSQL is private to the Compose network.
4. Configure `ALLOWED_HOSTS`, `CSRF_TRUSTED_ORIGINS`, `GOOGLE_REDIRECT_URI`, and a trusted proxy. Set `TRUST_PROXY=true` **only** when the proxy strips untrusted forwarded headers and overwrites `X-Forwarded-Proto`. Otherwise keep it false and terminate TLS directly at a trusted ingress.
5. Run `python manage.py check --deploy` using the production settings and verify Google sign-in against the real registered callback URI. Check `/health/` through HTTPS. The lightweight health endpoint checks HTTP process availability, not database readiness.

The Compose example uses the database owner for convenient bootstrap. Before a live release, use a separate migration role and a non-superuser runtime role with only required SELECT/INSERT/UPDATE privileges, without trigger/DDL permissions. Never give tenant users database credentials. An application role that can change database triggers can also bypass their controls.

## Backups and operations

- Automate encrypted PostgreSQL backups with off-host retention and restore drills. Database volume persistence alone is not a backup.
- Store secrets outside source control; rotate credentials through your deployment secret store.
- Run the PostgreSQL CI suite and database migrations in a controlled release step before starting new workers.
- Collect structured application/proxy logs and error alerts. Avoid logging OAuth codes, ID tokens, bank data or secrets.
- Configure ingress rate limits on sign-in and mutation endpoints. Add monitored audit retention and disaster recovery procedures.
- Set company VAT/TRN identity before issuing invoices. Obtain local tax and accounting validation for the final implementation.
- Pin a reviewed dependency lock for releases and keep security patches current. `requirements.txt` intentionally allows supported patch updates; it is not a reproducible lockfile.

## Verification status

The local domain/security/screen suite runs on SQLite. All 54 tests also passed on PostgreSQL 17 in [GitHub Actions](https://github.com/flyingpensil/Binderclip/actions/runs/40460963364), including deferred balance checks, immutable postings, insertion into committed journals, cross-company relationships, role assignments and concurrent booking. Docker build, real Google credentials, broader multi-user load testing and deployment-domain HTTPS verification remain separate release checks. For the prepared Admin1/Render setup, follow [client-launch.md](client-launch.md).
