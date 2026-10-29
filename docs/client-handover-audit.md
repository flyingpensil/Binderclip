# Client handover review — 27 October 2026

This is a historical review. See the [29 October review](professional-readiness-audit-2026-10-29.md) for later fixes and current boundaries.

This review covers the GitHub Pages/Supabase freight workflow, entry attribution, navigation and data-access boundary. It is a targeted code and regression review, not an independent penetration test or a guarantee that every possible defect has been found.

## Changes and corrections

- PostgreSQL now assigns created-by/date and updated-by/date on business, financial and administration entries. Browser payloads cannot override authors or creation dates. Names are stored at the time of the action, and dates display in Asia/Dubai time (GST).
- Existing creation timestamps remain intact. Missing historical timestamps are explicitly shown as not recorded; historical update dates are not reconstructed or invented. Tracking starts when migration 011 is installed.
- Entry history is available beside customers, suppliers, rates, tariffs, jobs, cost sheets/lines, quotations/lines, enquiries, supplier bills, customer invoices/items, receipts, supplier payments, tasks, timeline notes, documents, document requirements, ledger entries, company settings, roles and users. Immutable journal/payment history stays immutable. Permission assignment records are also stamped in the database.
- Changing a cost or quotation line marks its parent document as updated. Creation ownership stays fixed, preserving self-only role scopes.
- Removed the SHARED WORKSPACE label. Menu sections start collapsed, use accessible buttons and inert hidden links, animate in 140 ms, and respect reduced-motion preferences. Menu search expands matching sections and restores manual expansion when cleared.
- Detail routes now highlight the correct parent menu. Directory-only users no longer receive inaccessible ledger links. Read-only users are no longer mislabeled as the current account in the member list.
- Missing customer, supplier or rate-card prerequisites receive a useful message before opening an unusable form. Supplier-bill matching checks that an unmatched booked estimate exists.
- Changing currency clears an unrelated FX rate and restores 1 for the company base currency. Expired quotations no longer offer approval/conversion actions.
- Editing customer/supplier or sales forms preserves previously stored detail fields that are not exposed by that form.
- Quotation editors must have the existing cost-read permission to create or modify BUY lines, including attempts to turn a hidden BUY line into SELL using its identifier. No new user permissions are granted.

## Data protection evidence

- Client operational/accounting rows are in the private Supabase PostgreSQL schema; uploaded documents use the private Supabase Storage bucket. GitHub Pages contains frontend assets and public configuration only.
- Packaging uses an explicit file allowlist. Database files, exports, attachments, OAuth secrets, database credentials and server keys are not packaged. The public project URL/publishable key is intentional, not a password or administrator key.
- Regression tests check every private table has RLS enabled and no SELECT/INSERT/UPDATE/DELETE grants to anonymous or authenticated browser roles. RPCs enforce verified Google sessions, enabled membership, tenant boundaries and process/row scope.
- Direct live anonymous calls to session, customer-read and billing APIs with the public key returned HTTP 401. The public key does not authorize access to client records.
- The tracked-file review found no client data exports or database files. Credential-pattern scans across 33 repository revisions found no Google client secrets, Supabase secret keys or private keys. Database URL matches in current files were checked and are placeholders in example/test configuration. This is a pattern scan, not proof against every possible credential format.
- Downloading or copying the public application source does not copy Supabase records or bypass these access checks. Database/project administrators and authorized company users still have the access explicitly assigned to them.

References: [Supabase API keys](https://supabase.com/docs/guides/getting-started/api-keys), [Securing your API](https://supabase.com/docs/guides/api/securing-your-api).

## Validation and boundaries

The automated suites cover the complete freight-to-invoice flow, exact money calculations, accruals, bill variance matching, invoice/receipt and supplier-payment controls, immutable and balanced journals, tenant/role scope, quotation privacy, concurrent numbering, server-assigned authorship, two-user updates, private uploads, menu search/toggling, historical tracking labels and safe static packaging. Real browser layout checks use isolated synthetic fixtures; no test transactions are posted to the client's live accounts.

The current app retains its documented functional boundaries: manually maintained FX rates, two-decimal monetary amounts, current-state ageing rather than historical snapshots, and browser print/save-PDF. This review does not validate tax treatment for every jurisdiction or a backup/restore procedure. Verify those operational requirements before relying on the system as the client's sole accounting record.
