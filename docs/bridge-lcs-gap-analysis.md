# Binderclip freight release: Bridge LCS comparison

Assessment date: 27 October 2026. The customer selected freight operations, sales, documents and accounting first. Bridge LCS's public documentation is the process reference; this is an independent Binderclip implementation, not a copy of Bridge's branding, source or private application. Public descriptions cannot establish complete functional equivalence.

## Process baseline

[Bridge sales documentation](https://docs.lcsbridge.com/sales.html) describes enquiries, quotations, approval, validity, follow-ups and completion. [Its stages documentation](https://docs.lcsbridge.com/stages.html) describes job-stage requirements for information, documents, invoices and tasks. [Operations](https://docs.lcsbridge.com/operation.html) and [finance](https://docs.lcsbridge.com/finance.html) cover a much broader suite than this release. [Reports](https://docs.lcsbridge.com/reports.html) include operational and financial reporting. These are feature descriptions, not evidence of Bridge's internal calculations or guarantees.

Binderclip's implemented flow after installing upgrades 005–006 and enabling `features.freight`:

1. Create customer/supplier masters and an enquiry with route and cargo details.
2. Prepare a quotation with buy estimates, customer sell charges, tax, validity, FX and terms. Approval requires valid routing and sell charges. Approved charges are fixed. Customer-facing quote printing excludes internal buy lines.
3. Convert a valid approved quote into one draft job. Conversion calls the existing permission-checked job and cost commands and copies exact quantities/rates. Concurrent or repeated conversion cannot create duplicate jobs.
4. Maintain a shipment timeline and append-only notes. Assign dated tasks and register required document types for operational stages. Booking and later transitions enforce all applicable task/document gates inside PostgreSQL, including calls made outside the UI.
5. Upload files into a private bucket using exact server-issued paths. Only successfully uploaded and finalized files satisfy stage gates. Keep estimates/accruals, variance approval, cost approval and customer invoice approval/issue as separate processes.
6. Record customer receipts and supplier payments. Supplier settlements use the bill's carrying FX rate, post balanced journals, and reject duplicate references or overpayment.
7. Review receivables/payables ageing, trial balance, the implemented freight income statement and current job profitability. Lock completed financials and close delivered jobs.

## Feature coverage

| Area | Binderclip status after this release | Remaining differences |
|---|---|---|
| Google login, company isolation, role scopes | Implemented | No claim of independent security certification |
| Customer/vendor masters and ledgers | Implemented foundation | Multiple contacts, communication history and richer account summaries need expansion |
| Enquiries → quotations → jobs | Implemented core process | Prospect master, quote revisions/replication, customer approval links and emailed offers remain |
| Quote expiry, approval, customer print | Implemented | Full template designer and multi-language legal templates remain |
| Freight jobs, routes, shipment references | Implemented foundation | Multi-row packages/containers, customs HS catalogue, dispatch/vehicle allocations and bulk imports remain |
| Tasks, due dates, assignments | Implemented in-app queue | Push/email notifications and escalation scheduling remain |
| Milestones and job notes | Implemented manual records | Automatic carrier/AIS/airline feeds are not connected |
| Stage document/task gates | Implemented for fixed job statuses | Arbitrary stage templates, column rules, configurable invoice gates and automated financial actions remain |
| File documents | Private upload/download and stage checks | Version chains, retention cleanup, malware scanning, OCR extraction and document request portal remain |
| Buy/sell costing, accruals, bill matching | Implemented | One bill per estimate; partial allocations and accrual remeasurement need additional accounting workflows |
| Invoices, VAT, consolidated billing | Implemented foundation | Credit/debit notes, advances, proformas and jurisdiction-specific e-invoicing remain |
| Receipts and supplier payments | Implemented carrying-rate settlement | FX gain/loss, bank reconciliation, payment allocations and approval batches remain |
| Trial balance, income, ageing, profitability | Implemented for existing accounts and role scope | Full chart-of-accounts designer, statutory balance sheet, tax filings, comparative periods and report builder remain |
| Search | Cross-module, permission-filtered | Large-data pagination and indexed full-text search need scale testing |
| External portals and cross-company sharing | Not implemented | Requires explicit external identity and record-sharing design |
| Arabic/RTL and native mobile applications | Not implemented | Responsive web layout is available |
| Payroll, stock, fleet, inter-company | Deferred by customer prioritization | Separate implementations and acceptance tests required |

## Verification and practical limits

The CI database uses an isolated PostgreSQL instance with modeled Supabase Auth and Storage boundaries. Tests exercise quote conversion, fixed approved lines, expired quotes, process-permission rollback, stage gates, document path isolation and metadata checks, supplier settlement and report scopes. Browser DOM tests submit real UI forms against a stubbed RPC boundary, including upload failure. This verifies UI wiring and failure handling; it does not test real Google credentials or the hosted Storage service itself.

Live deployment should verify authenticated file upload/download, stage blocking and customer quote printing with a designated test job. Do not insert fake client invoices or real-world accounting entries just to validate the UI. Live smoke checks can read the new modules without changing business records.

Ageing uses document/payment dates, while ledger reports currently use journal creation dates in UTC. These reports are an operational foundation, not a certified statutory reporting package. Profitability reflects current estimates/matched bills for selected jobs; it is not a historical margin snapshot. Lists disclose result limits. File access uses short-lived signed download URLs; a user who already downloaded a file retains that copy. The bucket has type/size restrictions but no malware scanning. Free hosting still requires independent backup and restore planning.

Complete feature parity and an error-free guarantee are not established. The matrix is the release checklist for further work; unimplemented items are not represented as functioning features.
