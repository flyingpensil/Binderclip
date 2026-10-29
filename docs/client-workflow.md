# Client entry workflow

Use the sidebar in order: accounts and rates → sales and operations → billing and payments → finance and reports. Role permissions still determine which screens are visible.

1. Add the customer and suppliers. Customer currency offers 176 current ISO 4217 currency/fund codes from SIX List One, published 2026-09-17. Select only the customer currency; choose a business-type suggestion or enter your own. Maintain shared conversions under Accounts & rates → Currency exchange (all four fields required). Reverse and company-base cross conversions are automatic. New documents use the shared rate; saved documents retain their own rate. The monetary engine still uses two decimal places.
2. Optionally prepare an enquiry and quotation, then convert an approved quotation to a job. Alternatively create a job directly. Record shipper and consignee addresses on the job. The removed supplier-job-number control does not erase historical job data.
3. Open the job's cost sheet, enter buy estimates and customer sell charges, then book the job.
4. Match supplier invoices against the booked estimates and approve any required variances. Approve the completed cost sheet.
5. Open Customer invoices → **Create invoice**, choose a ready job and review invoice/payment dates. To consolidate, select ready jobs for the same customer, currency and exchange rate. The page explains the next step for unfinished jobs; it does not submit empty selections.
6. Review the draft invoice, approve and issue it, then record receipts. Supplier payments are recorded separately. Close and lock completed jobs using the existing controls.

## Automatic numbers

Migration `010_numbering_and_billing.sql` assigns separate, atomic, company-specific sequences at insert time. Examples: CUS-000001 (customer), SUP-000001 (supplier), JOB-000001 (job), CS-000001 (cost sheet), INV-000001 (customer invoice), ENQ-000001 (enquiry), QUO-000001 (quotation), BIL-000001 (supplier bill), REC-000001 (receipt), PAY-000001 (supplier payment), DOC-000001 (uploaded document), RAT-000001 (rate card), TAR-000001 (tariff).

Existing identifiers are preserved; matching numeric sequences continue beyond the largest existing number. Existing jobs receive a separate cost-sheet number. Historical payments and uploads retain their existing references. Failed database transactions do not consume counters; deleting a record never reuses its number. Counters are private and unavailable to browser clients. Number controls are read-only, and database triggers preserve identifiers on updates.

Supplier invoice references and bank payment references remain entered from the external document. Their separate internal BIL, REC and PAY numbers are assigned automatically.

## Release order

Run the automated PostgreSQL and browser tests on the feature branch. Install migration 010 in the Binderclip Supabase SQL editor before publishing the new frontend to GitHub Pages. The migration uses existing role grants and adds no new administrator or financial permissions.

Currency source: https://www.six-group.com/en/products-services/financial-information/market-reference-data/data-standards.html

## Session and entry controls

After two hours without human activity the workspace locks and signs out. Background permission checks and token refreshes do not extend this deadline. The server also rejects expired idle sessions; sign in again to continue.

Supplier selections are searchable dropdowns with checkboxes. Search fields accept `*`/`%` for any text and `?`/`_` for a single character, in addition to ordinary partial searches. Cost-sheet line corrections restore the previous scroll position and display Saved successfully beside that line.

The deferred journal-balance constraint runs as its private database owner. Browser accounts retain no private-schema or direct table access. A posting regression test reproduces the former schema-denied error and evaluates deferred constraints before rollback.
