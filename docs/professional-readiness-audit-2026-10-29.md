# Binderclip professional readiness review — 29 October 2026

Binderclip is the software name. Each tenant's legal business name belongs in Company profile. New customer invoices capture the profile in a document snapshot; changing the profile must not rewrite issued documents. The invoice layout now gives the legal company name prominence and identifies Binderclip in a secondary software credit.

## Live data review

Read-only checks ran against the production Supabase project. The first 22 controls returned zero exceptions. The inspected dataset at 11:10 GST contained 2 jobs, 1 customer invoice (issued), 3 matched supplier bill lines, 1 receipt, 2 supplier payments, 13 journals and 0 ready attachments. Two additional checks cover negative invoice net/VAT lines and non-finite financial values. After migrations 017–020 were installed, all **24 checks returned zero exceptions** at **11:20 GST**. No stored data required repair.

The versioned [audit SQL](../supabase/audits/integrity.sql) runs in a read-only transaction and returns exception counts without client names, document numbers or transaction amounts. It checks:

- Balanced, nonempty journals; accruals against their estimates.
- Invoice line arithmetic, discount/adjustment allocations, headers, receipt totals and payment status.
- Invoice receivable postings and receipt credits against their source documents.
- Supplier bill payable postings (including input VAT), settlements and overpayments.
- Job/customer/supplier/company source links and base-currency FX consistency.
- Prepared supplier source links, private table RLS and browser table grants.
- Private document storage and ready-document metadata/object consistency.
- Negative invoice net/VAT values and non-finite stored financial amounts.

Passing these controls means internally consistent records, not independent confirmation that the underlying commercial documents, tax registrations or bank movements are genuine. No live training or client accounting entries were posted, corrected, renumbered or deleted during the audit. Zero ready attachments means the production dataset cannot establish a successful real upload/download round trip.

## Defects corrected

| Finding | Correction and regression evidence |
|---|---|
| Overprecision and NaN could reach numeric columns through direct API requests | Server-side precision checks run before storage/posting in every financial command. Quantity supports 3 places, amounts 2, percentage 2, FX 8; invalid values are rejected rather than silently rounded. |
| Direct supplier matching lacked the complete date/reference checks | Reject blank vendor references, future invoice dates and due dates before the invoice. Existing role and job locks still apply. |
| Receipts could have a blank reference or precede the invoice date | Reject both at the protected command boundary. Supplier payments also require a reference. Historical test fixtures now specify appropriate invoice dates. |
| Payables ageing could use backdated document/payment dates without respecting when they were posted | Include only bills and payments posted by the selected Dubai cutoff. Tests cover late posting and a backdated payment. |
| Report period fields could be silently ignored | Ageing exposes only its cutoff date; period fields apply to ledger/job reports. Server rejects invalid or ignored date ranges. Filters remain editable after a report validation error. |
| UTC date checks disagreed with the Dubai UI near midnight | Business commands and reports share the Dubai business date; financial cutoff timestamps use Dubai time. Client overdue labels use the same date convention. |
| Historical job profitability could look like a historical accounting snapshot | Require today's as-of date; clarify that period fields filter job creation and figures reflect current estimates/matched costs. |
| Discount plus a negative adjustment could allocate a negative one-cent invoice line | Allocate negative adjustment against amounts remaining after discount; identical browser/server tests protect line net and tax amounts. |
| Product logo could compete with legal identity on invoices | Company snapshot name becomes the prominent heading; Binderclip remains software branding. Tests use a distinct legal company name. |

## Verification

The audit uses the existing complete freight-to-invoice tests, posted/deferred journal constraints, RBAC and tenant isolation tests, concurrent numbering, immutable posting tests, export controls and private document tests. New regressions cover the defects above and run the read-only audit against a synthetic posted flow. Browser integration tests cover error recovery and company identity. CI also runs the retained Django and container checks.

The full backend suite passed with **61 tests**, and the final frontend suite passed with **37 browser/domain checks**. Packaging checks passed. Final publication is verified through the deployment workflow and comparison of served frontend assets against this release. This review is not a penetration test, load certification, tax certification or external accountant sign-off.

## Work needed before a paid accounting launch

1. **Backups and recovery:** Choose an off-site encrypted backup destination and retention, back up PostgreSQL and attachment bytes separately, and demonstrate restoration to an isolated project. Do not assume the free Supabase plan supplies a recoverable backup.
2. **Accounting scope:** Implement controlled opening balances/manual journals, configurable chart of accounts and balance sheet, credit notes/reversals, fiscal period closing, bank reconciliation, variable-rate settlement gains/losses, and currency-specific minor-unit precision before claiming a complete international accounting ERP. Posted documents must stay immutable. The current engine uses 2 monetary decimal places, including currencies whose normal minor units differ.
3. **Tax review:** Agree jurisdiction, input VAT recoverability, tax reporting and any e-invoicing obligations with the client's accountant. The current supplier workflow treats entered supplier VAT as recoverable; it does not determine eligibility from tax law.
4. **Documents:** Finish the attachment retention, malware/file-content validation, interrupted-upload recovery, and document-level binding requirements. Current metadata checks do not constitute a malware scan.
5. **Operations:** Establish a staging project, monitoring/alerts, capacity and rate-limit testing, release/rollback procedure and support process. Existing CI is useful but does not establish production availability or successful disaster recovery.
6. **Commercial service:** Agree terms, billing provider, reminder channel, suspension/data-retention policy and merchant-country eligibility; then implement/test payment webhooks and tenant entitlement enforcement. No subscription lockout is currently enabled.
7. **Hosting/domain:** Move the commercial frontend off GitHub Pages, buy the chosen domain, configure HTTPS and exact OAuth redirects, and test Google sign-in at the new origin.

See the [attachments, subscriptions and domain roadmap](production-roadmap.md) for the decisions needed next.
