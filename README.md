# Binderclip

A logistics ERP for freight forwarding and 3PL operations. The client workspace uses **GitHub Pages + Supabase Auth/PostgreSQL**, with transactional database commands, company isolation and process-level role permissions. The original Django 5.2 application is retained for separately hosted deployments.

## Client deployment and Google login

Follow [GitHub Pages + Supabase setup](docs/supabase-deployment.md). The initial account is **Admin1**, signing in with **inventory.choco@gmail.com**, with company administrator access. Fresh installation provisions no other members or sample transactions. Google credentials belong only in Supabase's Google provider settings.

The static app is in `web/`; database tables, financial commands, access checks and first administrator bootstrap are in `supabase/migrations/`. Set the public `supabase-config.json` enabled flag after installing and checking the database and Auth configuration. The Pages builder packages only public assets. Never publish database passwords or service-role keys.

Use **Users & access → Add user** to authorize a client's Google email and roles. Clients can open the same website from their own computers. See the deployment guide for financial workflows, test coverage and current implementation limits. Free-tier hosting is suitable for evaluation; configure backups before using real accounting data.

## Start locally on Windows

Python 3.13 is required. From PowerShell:

```powershell
cd D:\github\binderclip\Binderclip
.\scripts\start.ps1
```

Open **[http://127.0.0.1:8001](http://127.0.0.1:8001)** and choose **Explore the local demo**. The script creates `.venv` if needed, installs dependencies, applies migrations, and seeds a local SQLite database. Seeding is idempotent. The sample workspace includes eight jobs, six customers, four suppliers, rate cards, four issued invoices, receipts, and a pending supplier variance. The demo identity is Amina; there is no demo password.

If script execution is restricted, run the equivalent commands manually:

```powershell
python -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements.txt
$env:DEBUG='true'
$env:DEMO_LOGIN='true'
.\.venv\Scripts\python manage.py migrate
.\.venv\Scripts\python manage.py seed_demo
.\.venv\Scripts\python manage.py runserver 127.0.0.1:8001 --noreload
```

SQLite is a **single-user development preview**, not the financial production database. PostgreSQL provides row locks and the database triggers described below. Environment variables are read from the process. `.env` is consumed by Docker Compose; the local commands do not automatically load it.

## What works

- Dashboard with live scoped shipment counts, base-currency invoice balances, and pending variances.
- Customer and supplier creation/editing, searchable directories, transaction ledgers, date/status/job/invoice filters, and Excel-readable CSV exports.
- Job creation/editing with shipment identifiers, routing, cargo, customs, dates, POD reference, and controlled lifecycle transitions.
- Buy/sell cost lines with quantities, currencies, explicit FX rates, VAT rates and exemption reasons; negotiated customer price-list associations and default tariffs.
- Booking accruals; supplier invoice matching against quantity, price, and base-value estimates; tolerance checks; separately authorized variance approval with reasons.
- Cost-sheet approval, single-job and consolidated draft invoices copied from approved charges, independent invoice approval and issue, payments, overdue calculation, and browser print / Save as PDF.
- Balanced journals for booking, matched bills, issued invoices and receipts. Unique posting sources and payment references prevent duplicate financial recognition.
- Cost-sheet locking after bills are matched and charges issued; supervisor unlock with audit reason; closing requires a locked sheet.
- Invitation-only Google OIDC, session authentication, tenant memberships, configurable roles, four-tier grants, self/branch/company scopes, and separate export permission.
- Database migrations, sample data, deployment files, CI, domain/security tests, PostgreSQL-specific integrity tests, architecture notes, and ERD.

## Typical workflow

The freight release adds **Sales → Enquiry → Quotation → Approval → Convert to job**, private job files, required document/task stage checks, shipment milestones, a work queue, supplier payments and ageing/trial-balance/income/profitability reports. It is activated after database upgrades 005–006. See the [Bridge LCS feature comparison](docs/bridge-lcs-gap-analysis.md) for what works and what remains; this release does not claim complete product parity.

1. Create a customer and supplier, optionally a rate card and tariffs.
2. Create a draft job. Add BUY estimates linked to suppliers and SELL charges; use the customer's negotiated tariff or a default rate card as a starting point.
3. **Book job & accrue** to recognize estimated expense. Estimates become fixed for this foundation.
4. **Match supplier bill** against each buy estimate. Beyond-tolerance quantity, unit-price, or base-value variance stays pending without posting the payable. An authorized manager approves it with a reason.
5. **Approve cost sheet**, then generate an invoice. For consolidation, select approved jobs for one customer, currency and FX rate from the Invoices screen.
6. **Approve invoice**, then **Issue & post to ledger**. Record payments against the issued invoice.
7. **Lock cost sheet** once all buy lines are matched and sell charges are issued. Progress operations through In transit → Delivered → Closed.

## Google sign-in and first company

Create a Google OAuth web client and register the exact callback URI. For a local test, use `http://127.0.0.1:8001/auth/google/callback/`. Configure the consent screen and test users as required by your Google project.

```powershell
$env:DEBUG='true'
$env:DEMO_LOGIN='false'
$env:GOOGLE_CLIENT_ID='your-client-id.apps.googleusercontent.com'
$env:GOOGLE_CLIENT_SECRET='your-client-secret'
$env:GOOGLE_REDIRECT_URI='http://127.0.0.1:8001/auth/google/callback/'
.\.venv\Scripts\python manage.py bootstrap_company --name 'Your Logistics LLC' --email 'your-google-email@gmail.com' --currency AED --branch Dubai
.\.venv\Scripts\python manage.py runserver 127.0.0.1:8001 --noreload
```

The bootstrap command provisions the initial company security administrator. It sends no invitation email. That administrator can use **Roles & access → Assign user** to provision other Google email addresses and assign multiple roles. The database-driven role grants—not Google scopes or a browser-provided company ID—authorize each operation. See [architecture](docs/architecture.md) for the OIDC flow and permission model.

## Schema and structure

The complete ORM schema is [erp/models.py](erp/models.py); executable DDL is represented by the committed [Django migrations](erp/migrations/). See [docs/schema.md](docs/schema.md) for the ERD and constraints. Generate deployment-specific PostgreSQL DDL with:

```powershell
.\.venv\Scripts\python manage.py sqlmigrate erp 0001
```

```text
Binderclip/
├── binderclip/              # Settings, URL routing, WSGI
├── erp/
│   ├── models.py            # Tenant, RBAC, masters, jobs, billing, journals
│   ├── security.py          # Tenant resolution, scopes, permission catalog
│   ├── auth.py              # Google OIDC and session lifecycle
│   ├── services.py          # Atomic accounting and job workflows
│   ├── forms.py             # Validated, tenant-filtered data entry
│   ├── views.py             # Screens, drill-downs and exports
│   ├── migrations/          # Schema + PostgreSQL integrity triggers
│   ├── management/commands/ # Company bootstrap and sample workspace
│   ├── templatetags/        # Permission-aware UI helpers
│   └── tests/               # Domain, security, UI and PostgreSQL tests
├── templates/               # Responsive application screens, invoice print
├── static/                  # CSS, small JS layer, favicon
├── docs/                    # Architecture, ERD, deployment and limitations
├── scripts/start.ps1        # Windows local startup
├── .github/workflows/ci.yml # PostgreSQL-backed CI
├── Dockerfile
├── compose.yaml
├── .env.example
├── requirements.txt
└── manage.py
```

## Verify

```powershell
$env:DEBUG='true'
.\.venv\Scripts\python manage.py check
.\.venv\Scripts\python manage.py makemigrations --check --dry-run
.\.venv\Scripts\python manage.py test erp.tests --verbosity 2
```

PostgreSQL integrity tests skip on SQLite. CI runs the suite against PostgreSQL, including raw SQL attempts to unbalance or mutate journals, append to committed postings, and cross tenant boundaries. CI must run successfully before deployment; a workflow file alone is not evidence of a successful run.

## Deployment and release scope

See [deployment](docs/deployment.md) for PostgreSQL, HTTPS, Docker and backup configuration. This is an initial implementation, **not an audited, localization-complete tier-1 accounting system**. The [release scope](docs/release-scope.md) describes the deliberate boundaries: supplier tax/AP settlement, foreign-currency settlement gains/losses, reversals and credit notes, fiscal periods, partial bills, attachment storage, direct PDF/XLSX generation, and jurisdiction-specific tax validation still need implementation before live accounting use.
