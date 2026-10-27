# Initial release scope and remaining work

This repository implements a working foundation and the immediate schema/scaffolding request. It is intentionally explicit about what remains before it can carry live accounting obligations.

| Area | Implemented | Remaining for a fuller release |
|---|---|---|
| Tenancy | Membership-scoped reads/writes/exports, tenant FK guards on PostgreSQL | Forced RLS or separate databases if the threat model requires SQL-level read isolation |
| RBAC | Four-tier catalog, multiple roles, self/branch/global report scope, export control | Department dimension, role deletion UI, user deactivation UI, security-admin-specific approval and delegation controls |
| Customers/suppliers | Search, create/edit, identity, contact/terms, supplier bank field, drill-down ledgers | Bank encryption/key management, payment approvals, hard enforcement of credit limits/holds |
| Jobs | Full operational fields, cargo/routing, controlled status workflow, POD reference | POD binary attachments/object storage, integrations, tracking feeds, richer milestones, post-booking amendment workflows |
| Cost sheets | Immutable estimates after booking, buy/sell, accruals, quantity/price/value matching, audited variance approval, approval/locking | Separate goods/service receipt entity for full procurement three-way matching, estimate amendments, partial and multiple bills against one estimate, automatic quote conversion |
| Supplier accounting | Bill-line matching and accrual-to-payable posting | Supplier bill headers, invoice-level duplicate detection across jobs, input VAT, supplier payments/credits and AP aging |
| Invoicing | Frozen invoice lines and legal identity, approval/issue, consolidation, receipts, overdue, browser print/PDF | Credit notes, void/reversal workflows, configurable invoice numbering rules, jurisdiction-specific e-invoicing/tax validation |
| Multi-currency | Currency and explicit FX snapshots; base-currency cost/margin/journals | Currency master/rounding for zero/three-decimal currencies, exchange rate feed, FX revaluation and realized settlement gains/losses |
| VAT | Customer charge tax rates, exemption reasons, tax totals and output VAT journal | Input tax/recoverability, country/tax-place rules, tax reports and filing, invoice tax in mandatory local currency where required |
| Accounting | Fixed account catalog, balanced immutable journal service and PostgreSQL guards | Configurable chart of accounts, fiscal periods/closing, reversals, trial balance/P&L/balance sheet and external accountant validation |
| Documents/exports | Browser print / Save as PDF, Excel-readable CSV | Direct generated PDFs/XLSX, branded template designer, permissioned object storage, malware scanning for uploads |
| Admin | Company bootstrap, user/role assignment, permissions matrix | Deactivate/reactivate members, MFA policy, role change approvals, security audit UI |
| Operations | Local startup, Docker/Render blueprints, 54 passing PostgreSQL CI tests including concurrent booking | Managed deployment smoke tests, broader load testing, monitoring, rate limiting, backups/restore drills and penetration testing |

All receipt settlements currently use invoice carrying FX, so do not record actual foreign-currency settlements with a different bank exchange rate until realized FX accounting is implemented. Dashboard receivables explicitly include only base-currency invoices; transaction ledgers retain each invoice's currency. Supplier payables are not presented as settled because no supplier payment workflow exists.

Issued invoice corrections must wait for a proper credit-note/reversal workflow; editing posted documents is not an acceptable workaround. Supervisor unlock applies to active jobs and does not permit rewriting posted journals or issued invoice snapshots. Closed/cancelled jobs cannot be unlocked, and this foundation does not yet allow estimate amendments after booking.
