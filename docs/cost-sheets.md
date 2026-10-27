# Job cost sheets

Open **Cost sheets** in the menu, or **Jobs → open a job → Open cost sheet**. Each job has one cost sheet. Create a job first; the sheet connects that customer's shipment to its supplier costs and customer billing.

The workbench displays supplier cost, customer revenue, gross profit and gross margin in company base currency. Customer VAT is excluded from those profit figures. Supplier costs use matched bills where available and estimated costs elsewhere, so an open sheet can still contain estimates. Supplier/customer payments do not change job gross profit.

## Working sequence

1. **Enter costs and charges.** Add supplier BUY lines and customer SELL lines, with quantities, rates, currencies and explicit FX. You can correct draft lines with a recorded reason. Alternatively, use **Apply quotation** on an empty draft sheet: select a valid approved quote for the same customer. This copies its buy/sell lines without changing the source quote. A second application is rejected to avoid duplicate charges. Jobs created through quotation conversion already contain their charges.
2. **Book and accrue.** Booking creates the existing expense accruals and fixes BUY estimates. Match each supplier invoice against its booked BUY line. Quantity, unit-price or amount variances beyond tolerance require authorized variance approval. This release matches one supplier bill to each buy estimate.
3. **Review profitability.** The supplier section separates estimated base cost from actual/accrued base cost. The customer section contains revenue and VAT rates. Unbilled SELL charges can be added/corrected after booking, before cost approval. Booked BUY estimates and matched bills cannot be rewritten.
4. **Approve the cost sheet.** All supplier bills must be matched and customer charges present. Approved charges are read-only. A user with disapproval permission can reopen the sheet with a reason, provided no customer invoice has been generated. Corrections retain append-only before/after history visible only through the financial cost sheet.
5. **Create the final customer invoice.** Choose invoice date and payment due date. The existing invoice engine copies approved sell charges once into a Draft customer invoice. Open that invoice, approve it, then issue it to post receivables/revenue/VAT. Cost-sheet changes are blocked once customer invoice charges have been generated, including draft invoice snapshots.
6. **Lock the cost sheet.** All supplier bills must be matched and customer charges issued. Manager unlock remains subject to its own permission and audit reason. An operationally delivered job can then be closed.

**Print / Save PDF** prints an internal cost sheet that includes supplier costs and profitability. Send the separate customer invoice to the customer; it contains customer charges rather than internal buy amounts.

This follows the principal buy/sell/profit/approval/invoicing concept described in [Bridge's operations guide](https://docs.lcsbridge.com/operation.html), with Binderclip's existing accrual and immutable-posting rules. It does not reproduce all Bridge document types or disapproval behavior: supplier-invoice-first posting without booking, credit notes, draft invoice cancellation/reissue, and reopening already invoiced cost sheets require separate workflows.

## Deployment and permissions

Apply `supabase/migrations/008_cost_sheet_workspace.sql` once after 007. It adds the authenticated-only `bc_costsheet` RPC, a private append-only correction-history table, and correction/disapproval/quotation-apply/internal-print permissions. Existing company administrators receive the new permissions; other roles remain explicitly assigned. Then enable `features.costSheets` in `supabase-config.json` and deploy Pages.

The workbench respects both job-read and cost-sheet-read scopes. Print additionally requires its X/export grant; editing, quotation application, disapproval and customer invoice generation each require their own grants. An action or HTML edit in the browser cannot bypass database validation.
