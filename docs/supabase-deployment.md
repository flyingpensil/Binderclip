# GitHub Pages + Supabase

Binderclip's static workspace runs on GitHub Pages. Supabase provides Google authentication and PostgreSQL; financial commands run inside database transactions. A Python hosting service is not required for this deployment. The original Django application remains available for a separately hosted deployment.

Project: `qdglfydbwbhzeixgpiro` in the Binderclip organization. This project is separate from Choco_Requests. `supabase-config.json` contains only the public project URL and publishable browser key. Never add a service-role key, database password, Google client secret or session token to this repository.

## First installation

Run these files in the **new, empty Binderclip project's SQL Editor**, in order, after CI passes:

1. `supabase/migrations/001_binderclip.sql`
2. `supabase/migrations/002_api.sql`
3. `supabase/migrations/003_initial_admin.sql`
4. `supabase/migrations/004_scoped_drilldowns.sql`

Files 001–003 are first-install migrations, not scripts to rerun over an existing installation. Bootstrap refuses to replace an existing company. File 004 is a function-only upgrade for existing installations. Bootstrap creates Admin1 (`inventory.choco@gmail.com`) and four role presets, with no sample transactions. The Google account binds to the invited membership on first verified sign-in.

All business tables are in the private `binderclip` schema, with RLS enabled and no direct anonymous/authenticated grants. Only three authenticated RPCs are public: `bc_session`, `bc_read`, `bc_command`. Each checks verified Google identity, active session, company membership and process/data scope. Dashboard totals and exports respect their own grants. Roles combine positive grants; no grant means no access. Scoped report export additionally requires `can_export`.

## Google authentication

Create a dedicated Google OAuth **Web application** client. Configure only basic `openid`, email and profile scopes.

| Setting | Value |
|---|---|
| JavaScript origin | `https://flyingpensil.github.io` |
| Google authorized redirect URI | `https://qdglfydbwbhzeixgpiro.supabase.co/auth/v1/callback` |
| Supabase Site URL | `https://flyingpensil.github.io/Binderclip/` |
| Supabase allowed redirect | `https://flyingpensil.github.io/Binderclip/` |

Enter the Google client ID and secret directly in Supabase **Authentication → Sign In / Providers → Google** and enable it. Keep nonce verification on. Disable unused email/password authentication. Keep anonymous authentication and manual identity linking off. Google users may authenticate, but only active invited members can access company data. Google Testing mode may require named test users; configure the OAuth audience appropriately before client evaluation.

Official setup: [Supabase Google OAuth](https://supabase.com/docs/guides/auth/social-sign-in/auth-google).

After SQL and Auth are configured, set `enabled` to `true` in `supabase-config.json` and push main. The Pages workflow packages only explicit public assets. Configure repository Pages source as **GitHub Actions**. The browser uses PKCE and sessionStorage, checks the verified user with Supabase, and obtains authorization from PostgreSQL. Closing the tab removes its local session storage.

## First walkthrough

Sign in as Admin1, then enter the legal company name, TRN and address in Company profile. Create a customer and supplier; optionally associate a negotiated rate card. Create a job, enter buy/sell estimates, book it to accrue costs, match supplier bills, approve any variance with a reason, approve the cost sheet, generate/approve/issue the invoice, record receipts, lock the cost sheet and close the delivered job. Financial postings use PostgreSQL numeric arithmetic, immutable journals and deferred balance constraints.

To add a client: **Users & access → Add user**, enter their Google email, branch and roles, then save. Share the Pages URL yourself; this action does not send email. Each client signs in using their own Google account. While Google OAuth remains in Testing, also add that email in the Binderclip Google Cloud project's **Audience → Test users**. Admin1 is already on that list. Publishing the OAuth audience requires completing Google's branding requirements; company data access remains controlled by Binderclip membership and roles. Start with the Read-only role unless they need operational or finance actions. Disabling membership blocks subsequent RPCs; existing screens clear when the periodic access check detects the change. Admin1 cannot disable or reassign itself, or edit its own assigned role.

## Scope and operating limits

This is the implemented ERP foundation for evaluation, not a claim of tier-1 accounting certification. Current flows include accruals, quantity/price/amount matching, variance approval, immutable issued charge snapshots, multi-job invoices, VAT, carrying-rate receipts and job locks. Invoice PDFs use the browser print dialog; ledgers export CSV for Excel. POD is a reference field; document upload/storage, arbitrary invoice layout design, FX settlement gains/losses, credit notes, partial supplier bill allocation, supplier payments, bank reconciliation and statutory submissions require additional workflows. Booked estimates are fixed; supervisor unlock does not permit rewriting posted accounting history.

List screens show up to 500 matching records and disclose the limit; narrow the search. Configure a separate test environment for test transactions. Free-tier quotas, inactivity pauses and backup availability are provider-controlled. Arrange off-platform database backups and verify restore procedures before relying on this for real accounting. Review current plan limits in the Supabase dashboard; no paid upgrade is part of this setup.

Run `npm test` for browser decimal/export/config checks. The Supabase CI job applies the schema to disposable PostgreSQL with a modeled Auth boundary and tests accounting and authorization. These tests do not replace an actual Google OAuth sign-in and cross-user browser check.
