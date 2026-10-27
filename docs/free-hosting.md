# Free client-evaluation deployment: Northflank Sandbox

Render has been rejected for this deployment. No Render resources or paid subscription were created. The preferred free option for Binderclip's existing Django/PostgreSQL stack is **Northflank Sandbox**.

## Why this option

Northflank's published Sandbox plan includes two services, one database addon and two jobs, with always-on compute rather than idle sleeping. Its official signup guide says no credit card is required, **but the live dashboard for this account requires card verification before creating an addon**. The dashboard states that Sandbox resources will not be charged. No addon has been created; proceed only if card verification is acceptable. The platform provides HTTPS endpoints, secret groups and private database networking. This fits one Binderclip service plus one PostgreSQL database without rewriting the application.

The provider explicitly positions its free tier for development/testing, **not production applications**. Use this environment for the client walkthrough and evaluation. It preserves the implemented application's Google authentication, tenant/RBAC checks, CSRF protection, secure cookies and PostgreSQL integrity constraints; a free plan is not a promise of audited security, production SLAs or durable backup coverage. Confirm the Sandbox plan still shows a zero charge in your actual account before creating resources. Do not select Pay-as-you-go, BYOC or paid upgrades.

Alternatives checked: Koyeb requires card verification and its free service sleeps; PythonAnywhere requires a paid account for PostgreSQL connections; Alwaysdata's free plan excludes profit purposes. Neon supplies a free PostgreSQL database but still needs a separate compatible app host. Northflank is the simplest candidate for this evaluation because it hosts both components together.

## 1. Account and project

1. Create/sign into [Northflank](https://app.northflank.com/signup) yourself and select the free **Sandbox** plan. Complete any account verification or terms acceptance directly. This account's live UI requires a verification card; the written no-card guide is not accurate for this account.
2. Create a project named `binderclip` on **Northflank Cloud**, using an available Sandbox region. Do not use BYOC, which bills through your own cloud account.
3. Connect only `flyingpensil/Binderclip` if GitHub repository authorization is requested. The app repository is public; access to unrelated private repositories is unnecessary.

## 2. Private PostgreSQL

Within the project, create the free PostgreSQL addon and select PostgreSQL 17 if available. Keep **Deploy with TLS** enabled and **public access disabled**. Use the included free resource allocation; if the dashboard requests a paid allocation, stop before submitting.

Create a secret group and link the database's connection URI (typically `POSTGRES_URI`) to the runtime variable `DATABASE_URL`. Confirm the exact generated key in the addon dashboard rather than assuming a secret name. The application requires PostgreSQL and defaults to TLS `sslmode=require` when using `DATABASE_URL`.

## 3. App service

Create a **Combined** build-and-deployment service:

| Setting | Value |
|---|---|
| Repository | `https://github.com/flyingpensil/Binderclip` |
| Branch | `main` |
| Build method | Dockerfile |
| Dockerfile | `/Dockerfile.northflank` |
| Build context | Repository root |
| Container port | `8000` |
| Port protocol | HTTP, exposed through Northflank's HTTPS ingress |
| Health check | HTTP `/health/` |
| Replicas | `1` |
| Resource plan | Included free Sandbox allocation |

The Docker image bakes static assets in at build time, using temporary build-only settings and no live credentials. At startup it requires secrets and the exact app origin, applies migrations, provisions Admin1 idempotently, and starts Gunicorn with one worker. Sample users and sample transactions are not inserted.

Use [deploy/northflank.env.example](../deploy/northflank.env.example) as the runtime-variable reference. Store `SECRET_KEY`, database URI and Google credentials in Northflank's secret group, not GitHub or build arguments. Set:

```text
DEBUG=false
DEMO_LOGIN=false
PORT=8000
WEB_CONCURRENCY=1
TRUST_PROXY=true
INITIAL_ADMIN_EMAIL=inventory.choco@gmail.com
INITIAL_ADMIN_NAME=Admin1
INITIAL_ADMIN_USERNAME=Admin1
INITIAL_COMPANY_NAME=Binderclip
```

Once the port receives its actual HTTPS `*.code.run` domain, set `APP_BASE_URL` to that origin (no path). If the hostname is available only after creating the service, the first startup intentionally fails until you set it and redeploy. Do not work around that check with wildcard hosts or disabled HTTPS.

`TRUST_PROXY=true` is for managed ingress that overwrites forwarded protocol headers. During deployment verification, confirm HTTPS requests reach the app as secure and that secure cookies are set. Do not publicly expose a second direct Gunicorn endpoint that bypasses the trusted ingress.

## 4. Google login

Use a dedicated Binderclip Google Cloud project. The project currently selected in the browser belongs to a different app; it has not been changed. Configure External audience for Gmail accounts, then a Web application OAuth client.

Register the actual assigned application address:

```text
Authorized redirect URI: https://ACTUAL-DOMAIN.code.run/auth/google/callback/
Authorized JavaScript origin: https://ACTUAL-DOMAIN.code.run
```

The backend derives its callback from `APP_BASE_URL`. Enter the client ID and secret into Northflank's runtime secret group and redeploy. Add `inventory.choco@gmail.com` to Google's test users if the OAuth app is in testing.

Admin1 signs in with `inventory.choco@gmail.com`; no application password is created. All implemented modules are accessible to that company administrator. Additional client access is provisioned through **Users & access → Add user**, once the client's exact Google email is supplied.

## 5. Existing GitHub Pages link

After the backend is verified, set GitHub repository variable `BINDERCLIP_APP_URL` to the actual Northflank HTTPS origin and run the existing Pages workflow. Alternatively, update the public `deployment.json` with that origin. The existing Pages address becomes the entry point and sends users to the real backend for sign-in and shared data.

No changes to the public page are needed just to switch providers: it already accepts any valid HTTPS application origin.

## Verification before the client walkthrough

- Confirm the account and both resources remain on free Sandbox allocations.
- Confirm the database has TLS and private-only access.
- Verify HTTPS, secure session cookies, successful Admin1 Google login and denial of an uninvited Google account.
- Run `python manage.py check_login --strict` in the service shell; it does not print credentials.
- Verify user creation, job booking, supplier matching and invoice issuance with evaluation data. All 54 domain/security/PostgreSQL tests already passed in GitHub Actions before this hosting change.
- Export an off-platform database backup before adding important records. Check whether backups are included in the selected free plan rather than assuming coverage.

The Docker image build, container startup, Admin1 provisioning, versioned static assets and all 54 PostgreSQL tests passed in [GitHub Actions](https://github.com/flyingpensil/Binderclip/actions/runs/40463613836). Docker is unavailable locally; the build was verified in CI. Actual Northflank startup, HTTPS and Google login still require your account configuration. Remaining product functionality is tracked in [release-scope.md](release-scope.md).

## Official sources

- [Northflank pricing and free Sandbox](https://northflank.com/pricing)
- [Free-tier limits and intended use](https://northflank.com/docs/v1/application/billing/pricing-on-northflank)
- [Official signup guide: no credit card](https://northflank.com/blog/how-to-deploy-vibe-coded-v0-apps-to-production)
- [Django deployment guide](https://northflank.com/guides/deploy-django-app-northflank)
- [PostgreSQL and secret groups](https://northflank.com/guides/deploy-postgres-database-on-northflank)
- [Managed HTTPS and networking](https://northflank.com/docs/v1/application/network/networking-on-northflank)
