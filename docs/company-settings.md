# Company operating and VAT settings

Open **Administration → Company profile → Edit company profile**. Binderclip remains the software name; the legal company name here appears on new document snapshots.

1. Select/type the two-letter registration country code. Suggestions include AE — United Arab Emirates and common trading countries; another code can be entered manually.
2. Choose the accounting currency and company timezone before financial documents are created. They become read-only once quotations, purchase invoices, cost lines, customer invoices or journals exist. A controlled migration is required to change those foundations afterward; changing them would reinterpret historical figures.
3. Confirm the VAT registration status with the client. Existing companies start **Unconfirmed**; installing this feature does not assert UAE registration or validate a client's legal status.
4. For **VAT registered**, enter the TRN and review the default sales VAT percentage. UAE setup suggests AED, Asia/Dubai and the standard 5% rate. The current UAE VAT setup requires AED accounting for local tax reporting, and checks that a UAE TRN contains 15 digits. This validates format, not FTA registration. A default zero rate requires a reason.
5. For **Not VAT registered**, new sales defaults become 0% with a registration-status reason. New supplier-document VAT is treated as a job cost rather than recoverable input VAT. Registered/unconfirmed legacy treatment remains recoverable by default and needs accountant review for eligibility.

Save only information confirmed with the client. The country preset is a convenience, not a taxability decision. International transport, zero-rated and exempt services need their own correct rate/reason. Countries other than the UAE have manually maintained defaults; there is no automatic tax-law engine or certified e-invoicing integration.

## What changes automatically

- New customer/supplier masters and operational forms inherit the accounting currency.
- New quotation SELL lines, cost-sheet customer charges and imported supplier-document sell charges inherit the default sales VAT rate/reason.
- New invoice lines inherit sales defaults; saved lines retain their own percentages/reasons.
- Company dates, report cutoffs, ledger dates and entry history use the configured timezone.
- For a company confirmed as not VAT registered, new sales VAT is blocked above 0%, and supplier VAT is expensed in job costs. The supplier payable still includes the full VAT amount.
- Cost-sheet billed revenue uses allocated invoice discounts/adjustments; line totals agree with the job's profitability figures. Non-recoverable supplier VAT is included in actual cost rows and totals.

Existing invoice snapshots, saved rates, supplier VAT snapshots and posted journals are not rewritten when settings change. Existing unconfirmed documents retain the legacy treatment; an accountant must review any historical correction through a controlled accounting process.

The current monetary engine uses two decimal places. Currency selection alone does not supply zero-/three-decimal currency accounting, VAT filing, tax eligibility decisions, credit notes, fiscal closing or bank reconciliation.

Reference: [UAE FTA standard VAT rate](https://tax.gov.ae/en/faq.aspx?keyword=What+is+the+standard+rate+of+VAT+in+the+UAE%3F), [FTA taxable supplies and zero rating](https://tax.gov.ae/en/content/what.is.a.taxable.supply.aspx).
