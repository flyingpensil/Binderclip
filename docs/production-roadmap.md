# Attachments, subscriptions and domain — decisions for the next stage

This is a proposed design, not an activated integration. No payment, email reminders, Drive permissions or domain purchases have been made.

## Attachments

Current uploads go to the private Supabase Storage bucket `binderclip-documents`; PostgreSQL stores the tenant/job/document metadata and exact object path. Current limits are 10 MB and PDF, PNG, JPEG, TXT or CSV. Downloads require an active Google session, company/job scope and document export permission. Files are not saved in GitHub. Current registration is at job level; attaching to a specific customer/supplier invoice needs an explicit validated document association.

| Option | Benefits | Tradeoffs |
|---|---|---|
| Keep Supabase Storage as primary | Existing protected upload/download path, matching tenant RBAC, low implementation effort | Storage/egress quotas and separate attachment backups; no malware scanner is currently installed |
| Personal Google Drive folder | Uses the folder owner's Drive allocation; familiar owner-side file browsing | Needs separate owner OAuth consent and securely stored refresh token, quota monitoring and revocation handling; a personal account controls availability |
| Google Workspace shared drive | Organization-owned files and continuity when staff change | Requires an eligible Workspace edition and Drive integration; folder permissions must not expose another tenant's documents |
| Private storage with a Drive archive | Keeps interactive access under app permissions while exporting an archive | Two copies need retention, deletion, retry and reconciliation rules; an archive alone is not a tested backup |

Recommendation: keep private Supabase Storage for interactive documents initially, and decide whether Drive is an archive or the primary provider. A personal folder is possible, but normal Google sign-in only supplies identity access; it does not authorize writing to that folder. Use limited `drive.file` access where suitable, selected with Google Picker. Keep owner refresh tokens/service credentials on a protected server, never in GitHub or the browser. A service account cannot own files using its own Drive quota; use owner OAuth for My Drive or an organizational shared drive.

The app would store provider, external file ID, tenant, parent document ID/type, filename, size, MIME type, uploader/time and checksum. All uploads/downloads must recheck the app's tenant and document permissions. Use separate tenant folders, unpredictable file IDs, server-side destination control, file-content validation, malware quarantine, upload retry/finalization and deletion/retention history. Do not use public sharing links as the authorization mechanism.

Sources: [private Storage buckets](https://supabase.com/docs/guides/storage/buckets/fundamentals), [Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth), [shared-drive ownership and service-account limits](https://developers.google.com/workspace/drive/api/guides/about-shareddrives).

## Subscription lifecycle

Use a fixed **30-day** interval as requested, rather than assuming a calendar month. Store exact UTC instants and display deadlines in the company timezone.

| Time | State | Access |
|---|---|---|
| Start through just before start + 30 days | Active | Normal role-based access |
| At start + 30 days through just before start + 37 days | Grace | Normal access plus a payment reminder; one reminder each of the 7 grace days |
| At start + 37 days if still unpaid | Suspended | Business screens/APIs and attachments blocked; sign-in, subscription/payment and support remain available |
| Verified payment | Active | Restore access and display the next paid-through date |

Enforcement belongs in tenant access checks on the server as well as the interface. Changing a browser date or calling an API directly must not bypass suspension. A background job queues daily reminders even when nobody has the app open. Give each reminder a unique `(tenant, due_period, grace_day)` key and each payment a unique provider event ID so retries do not duplicate messages or extend subscriptions twice.

Keep subscription revenue/billing records separate from the logistics customer's operational accounts. Ordinary company administrators cannot mark their own subscription paid. Use a hosted payment page and verified/signed provider webhooks, or an audited platform-owner approval for bank transfers; a customer screenshot or successful browser redirect is not payment confirmation. Handle duplicated/out-of-order events, failures, refunds, chargebacks and reactivation explicitly.

Suspension must preserve records and retain a way to pay. Agree the contractual retention/export and cancellation rules before enforcing a total business lockout. Do not delete operational/accounting data because a subscription is overdue.

Decisions still needed: merchant country/provider, fee/currency/tax, per-company vs per-user charging, reminder recipients/channels, and the renewal anchor after late payment (original cycle vs 30 days from payment). The chosen provider must support the required 30-day schedule; a generic monthly plan can mean calendar months.

Reference: [subscription webhooks and payment events](https://docs.stripe.com/billing/subscriptions/webhooks). Stripe is an example, not a selected or configured provider.

## Hosting and .com domain

GitHub's Pages rules exclude using it to provide commercial SaaS. Move the frontend before enabling paid subscriptions. Cloudflare Pages is a candidate for the static frontend and supports custom domains on its Free plan; Supabase can remain the backend. Hosting quotas, functions/email/payment costs and support requirements still need a production budget.

Buy the .com only after the name/availability and price are chosen. Configure `app.<chosen-domain>.com`, HTTPS, canonical redirects, Supabase Site URL/redirect allowlist, Google authorized origins and any payment webhook/callback settings. Test a complete sign-in and document workflow at the new origin before retiring the evaluation address. Code currently has the deployed evaluation address for local-preview sign-in; update that as part of the migration.

References: [GitHub Pages usage limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits), [Cloudflare custom domains](https://developers.cloudflare.com/pages/configuration/custom-domains/), [Cloudflare Pages quotas](https://developers.cloudflare.com/pages/platform/limits/).

## Backup priority

The Supabase Free plan does not include automatic backups as a plan feature. Maintain your own encrypted exports, protect keys separately, and test restoration. Database backups do not contain Storage file bytes, so back up attachments independently, including file IDs/paths and integrity checks. Select a separate private backup destination and retention before copying any live client data.

References: [Supabase backups](https://supabase.com/docs/guides/platform/backups), [plan features](https://supabase.com/pricing).
