# Compact document workspaces

Deployment status (2026-10-29): the compact UI, migration 028 and compatible Edge Function are live. Frontend (55 tests), database (74 tests), packaging, legacy application and container CI pass. The post-upgrade read-only integrity audit returned 25 controls / zero exceptions. Existing training-job attachment download was verified byte-identical after the upgrade.

The paid training invoice attachment test registered a pending synthetic TXT attachment and exposed the existing Drive refresh-credential merge defect. Migration 029 and the tested recovery handler are deployed. The previously discarded offline credential requires one owner Google reconnection before this retained pending invoice upload can be retried and the final live upload check completed. No financial records were edited or posted for layout verification.

The user's CW Suite screenshot is the layout reference: a document header, status/amount chips, a concise field grid, then a separate item area with tabs. Binderclip keeps its existing sidebar order and company branding.

The five record screens are jobs, quotations, supplier invoices, cost sheets and customer invoices. Their existing forms and action buttons are moved into the new layout without replacing the workflow handlers. Desktop item areas scroll within the document; narrow screens retain normal page scrolling and horizontally scrollable tables/tabs. Active tabs and scroll positions survive saves, and keyboard users can switch tabs with arrows/Home/End. Print/PDF actions still reconstruct the original complete authorized document, independent of the visible screen tab.

Invoice/quotation line items are separated from billing identity and terms on screen. The full legal identity, addresses, tax figures, payments, source links, correction history and original print layouts remain available. Cost-sheet workflow guidance is expandable; approval/lock state and permitted actions remain in the header.

## Attachment upgrade 028

Each attachment is bound to a company, record type and record ID. A quotation can accept files before conversion. Consolidated customer invoices have their own attachment identity without selecting an arbitrary job. Existing job files retain their IDs, document numbers, hashes and Drive locations.

The API requires both access to the parent record and the existing operations document permission for the requested action. Supplier-invoice and cost-sheet files also require access to their job. No new role grants are added. New private record-folder mappings preserve existing job-folder mappings. Non-job files are excluded from the old job document list and cannot satisfy mandatory job BL/POD checks. Adding files to an issued invoice does not update its amounts, snapshot or accounting entries.

## Rollout

1. Complete frontend, packaging and disposable PostgreSQL CI plus synthetic-data browser checks.
2. Deploy the updated `binderclip-documents` Edge Function first, retaining its existing auth configuration and secret values. It supports both the old job context and the new record context.
3. Apply migration 028 in the production database after approval of the expanded document attachment API. Existing private-table restrictions remain enabled.
4. Publish the matching frontend with `features.recordAttachments=true` and run the read-only integrity audit after migration. This rollout is complete; static assets and imports now use one content version to prevent stale browser modules/styles mixing across releases.
5. Verify the five record screens and existing job attachments on the live site. Do not post training financial transactions to validate a layout. A restricted/unavailable attachments panel must not make the parent record unusable.

The local visual review uses generated synthetic fixtures in the ignored `pages-preview` directory; it does not connect to production or add localhost OAuth redirects. Google Drive Testing-mode expiry remains a separate production-readiness requirement documented in `private-attachments.md`.
