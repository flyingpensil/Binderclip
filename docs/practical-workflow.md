# Practical freight workflow and worked example

Release prepared 28 October 2026 for GitHub Pages + Supabase. The older Django demo is retained separately and does not have these screens.

## Entry sequence

1. **Customer:** legal name, nature of business, TRN, CRN, billing address, currency, credit terms and default FX rate/source. Shipping address is removed from the form; cargo-party addresses belong to the job. FX means company currency per one customer-currency unit. Rates are explicitly entered and reviewed, not downloaded daily.
2. **Suppliers:** create the carrier, customs broker and other vendors with currency/payment terms.
3. **Job:** choose activity code and multiple planned suppliers. Enter client reference/PO, loading port, optional transshipment port, discharge port, container numbers and shipper/consignee details. Delivery-order entry is removed. Historical fields are preserved.
4. **Supplier invoices:** use the job row's Supplier invoices option. Add one vendor document per reference, with up to 100 service lines. Enter quantity, price, unit, comments and vendor VAT percentage. Duplicate references for the same vendor are rejected. Draft invoices can be corrected.
5. **Cost sheet:** select supplier documents or Select all, then Import selected invoices. Their service lines appear in one cost sheet with source documents retained. Review customer sell prices. If imported incorrectly, Return to draft with a reason before booking; source lines and correction history stay controlled together.
6. **Book & match imported supplier invoices:** creates accruals and matches vendor lines. Remaining unimported documents block booking. Differences from edited buy estimates use variance approval. Vendor VAT is carried in payables and a separate recoverable-VAT account, rather than added to job expense.
7. **Approve cost sheet**, then Create final invoice. Use **Prepare / edit invoice lines** to review serial number, description, comments, unit, quantity, price and VAT percentage, or add a charge. Enter a correction reason, discount and adjustment before VAT. Save, approve and issue.
8. **Receipt and reports:** record the receipt. Under Reports, open Customer statement of account or Customer aging. Select customer, date and currency, then run, export CSV or print/save PDF according to permissions.
9. Once bills and charges are finalized and issued, lock the cost sheet. Progress the job through In transit → Delivered → Closed.

## Worked example — synthetic training data

Use an authorized training context. No sample records or payments are inserted into the live company automatically. Actual numbers depend on existing sequences.

| Entry | Example |
|---|---|
| Customer | Example Manufacturing — TRAINING |
| Nature of business / CRN | Manufacturing / TRAIN-CRN-001 |
| Currency / FX / credit days | AED / 1 / 30 |
| Billing address | Training warehouse, Dubai |
| TRN | Leave blank for the synthetic example; use a real registered TRN for real invoices |
| Suppliers | Training Ocean Carrier; Training Customs Broker |
| Activity / PO | Ocean import / TRAIN-PO-001 |
| Route | Shanghai → Singapore (transshipment) → Jebel Ali |
| Container reference | TRAIN-CONTAINER-001 (training reference only) |

Supplier documents dated today, payment terms 30 days:

| Vendor reference | Supplier | Description | Unit | Qty | Price AED | VAT | Net | VAT amount | Payable |
|---|---|---|---|---:|---:|---:|---:|---:|---:|
| TRAIN-OCEAN-001 | Training Ocean Carrier | Ocean freight | container | 2 | 500 | 5% | 1,000 | 50 | 1,050 |
| TRAIN-CUSTOMS-001 | Training Customs Broker | Customs clearance | shipment | 1 | 200 | 5% | 200 | 10 | 210 |

Import both. Set customer sell prices to **600 per container** for freight and **300 per shipment** for clearance. Book/match and approve. Generate the invoice, then enter discount **100** and adjustment **+20**, both before VAT.

| Checkpoint | Expected AED |
|---|---:|
| Supplier expense excluding recoverable VAT | 1,200.00 |
| Supplier input VAT / total payables | 60.00 / 1,260.00 |
| Customer charges before adjustments | 1,500.00 |
| Discount / adjustment | −100.00 / +20.00 |
| Net customer revenue | 1,420.00 |
| Customer VAT | 71.00 |
| Final invoice | **1,491.00** |
| Gross job profit excluding VAT | **220.00** |
| Customer receipt | 491.00 |
| Closing statement / aging outstanding | **1,000.00** |

Before the due date, AED 1,000 belongs in Current. Later-posted receipts do not reduce an earlier historical balance. The regression suite runs this example against disposable PostgreSQL and checks balanced journals.

## Calculations and controls

- Discount and adjustment are fixed invoice-currency amounts before VAT, apportioned across line net values by cumulative rounding. Each line retains its own VAT percentage, including mixed taxable/exempt rates.
- PostgreSQL numeric values and integer-cent previews avoid floating-point money errors. Base revenue is allocated so line/job sums reconcile to the rounded invoice posting.
- Invoice corrections require existing costing and invoice-generation permissions. Issued invoices, posted journals and matched supplier history cannot be rewritten through the draft editor.
- Statement opening balances include postings before the selected start date; running/closing balances include invoice debits and receipt credits. Aging buckets are Current, 1–30, 31–60, 61–90 and 90+. Each currency has separate totals.
- Reports use posting dates in Dubai time. A backdated document posted today does not appear as posted yesterday. Legacy invoices use their journal timestamp where available.
- Vendor VAT is treated as recoverable input VAT in this release. Confirm eligibility with the accountant. Foreign invoice preparation records FX source/date and displays company-currency VAT/total equivalents. This is not certification of tax compliance in every jurisdiction. Monetary precision remains two decimals.

## Industry references

This design follows shipment-linked vendor/customer transactions and traceable document transfer described by [Magaya](https://www.magaya.com/wp-content/uploads/2020/05/Magaya-Supply-Chain-Data-Sheet.pdf), and separate partner ledgers/aged receivables described in [Odoo's customer invoicing documentation](https://www.odoo.com/documentation/20.0/applications/finance/accounting/customer_invoices.html). These are workflow references, not claims of product parity.

For UAE invoice content, consult the [FTA tax invoice guidance](https://tax.gov.ae/Datafolder/Files/Pdf/2023/Knowledge%20Center%20Page/VAT11%20-%20Tax%20invoices%20En.pdf). The accountant should confirm rates, FX source and input-VAT recovery.
