"""All financial mutations: authorize, lock, validate, post and audit atomically."""
from datetime import timedelta
from decimal import Decimal, ROUND_HALF_UP
from django.core.exceptions import ValidationError
from django.db import transaction
from django.utils import timezone
from .models import (AuditEvent, CostSheet, CostSheetItem, CustomerInvoice, InvoiceItem, Job,
                     JobSupplierInvoice, JournalEntry, JournalLine, Receipt)
from .security import require

D = Decimal
def rounded(value): return value.quantize(D('.01'), rounding=ROUND_HALF_UP)
def attrs(member): return {'tenant': member.tenant, 'branch': member.branch, 'created_by': member.user}
def audit(member, action, obj, detail=''):
    values = attrs(member)
    values['branch'] = getattr(obj, 'branch', member.branch)
    AuditEvent.objects.create(**values, action=action, object_type=type(obj).__name__, object_id=str(obj.pk), detail=detail)

def post(member, key, description, lines, job=None, branch=None):
    """Private primitive. A unique source key makes posting exactly-once."""
    lines = [(account, rounded(D(debit)), rounded(D(credit))) for account, debit, credit in lines]
    lines = [row for row in lines if row[1] or row[2]]
    if not lines: return None  # zero-value documents do not need a journal
    if any(d < 0 or c < 0 or (d and c) for _, d, c in lines): raise ValidationError('Invalid journal line.')
    if sum(d for _, d, _ in lines) != sum(c for _, _, c in lines): raise ValidationError('Debits must equal credits.')
    with transaction.atomic():
        values = attrs(member)
        values['branch'] = branch or (job.branch if job else member.branch)
        entry = JournalEntry.objects.create(**values, source_key=key, description=description, job=job)
        JournalLine.objects.bulk_create([JournalLine(entry=entry, account=a, debit=d, credit=c) for a, d, c in lines])
    return entry

def locked_sheet(member, sheet_id, process, action='U'):
    sheet = CostSheet.objects.select_for_update().select_related('job', 'tenant').get(pk=sheet_id, tenant=member.tenant)
    require(member, f'costs.detail.{process}', action, sheet)
    if sheet.locked_at: raise ValidationError('This cost sheet is locked. A supervisor must unlock it first.')
    if sheet.job.status in ('Closed', 'Cancelled'): raise ValidationError('This job is closed or cancelled.')
    return sheet

@transaction.atomic
def create_job(member, job):
    require(member, 'jobs.list.manage', 'C')
    job.tenant = member.tenant; job.branch = member.branch; job.created_by = member.user
    job.status = 'Draft'; job.full_clean(); job.save()
    CostSheet.objects.create(**attrs(member), job=job)
    audit(member, 'job.created', job)
    return job

@transaction.atomic
def add_line(member, sheet_id, line):
    sheet = locked_sheet(member, sheet_id, 'manage', 'C')
    if sheet.job.status != 'Draft': raise ValidationError('Add estimates before booking the job.')
    line.tenant = member.tenant; line.branch = sheet.branch; line.created_by = member.user; line.sheet = sheet
    line.full_clean(); line.save()
    sheet.approved = False; sheet.save(update_fields=['approved'])
    audit(member, 'cost.line_added', line)
    return line

@transaction.atomic
def book_job(member, sheet_id):
    sheet = locked_sheet(member, sheet_id, 'book')
    job = Job.objects.select_for_update().get(pk=sheet.job_id)
    if job.status != 'Draft': raise ValidationError('Only a draft job can be booked.')
    items = list(sheet.items.filter(side='BUY'))
    if not items or not sheet.items.filter(side='SELL').exists(): raise ValidationError('Add buy and sell estimates before booking.')
    for line in items:
        value = line.base_amount
        post(member, f'accrual:{line.id}', f'Booking accrual · {line.service}', [('5000 Direct costs', value, 0), ('2000 Accrued costs', 0, value)], job)
        line.accrued = True; line.save(update_fields=['accrued'])
    job.status = 'Booked'; job.save(update_fields=['status'])
    audit(member, 'job.booked', job)

def _post_bill(member, bill):
    expected = bill.cost_item.base_amount
    actual = bill.base_amount
    delta = actual - expected
    post(member, f'bill:{bill.id}', f'Supplier bill {bill.number}', [
        ('2000 Accrued costs', expected, 0), ('5000 Direct costs', max(delta, 0), max(-delta, 0)),
        ('2100 Payables', 0, actual)], bill.job)
    bill.status = 'Matched'; bill.save(update_fields=['status'])

@transaction.atomic
def match_bill(member, sheet_id, bill):
    sheet = locked_sheet(member, sheet_id, 'match', 'C')
    line = sheet.items.select_for_update().filter(pk=bill.cost_item_id, side='BUY', accrued=True).first()
    if not line: raise ValidationError('Select a booked buy estimate from this job.')
    if bill.currency != line.currency or bill.supplier_id != line.supplier_id:
        raise ValidationError('Supplier and currency must match the operational estimate.')
    if bill.currency == member.tenant.base_currency and bill.fx_rate != 1: raise ValidationError('Base currency exchange rate must be 1.')
    bill.tenant = member.tenant; bill.branch = sheet.branch; bill.created_by = member.user; bill.job = sheet.job
    bill.variance = rounded(bill.base_amount - line.base_amount)
    bill.full_clean()
    bill.save()
    tolerance = member.tenant.variance_tolerance / D(100)
    quantity_variance = abs(bill.quantity - line.quantity) / line.quantity
    price_variance = abs(bill.unit_rate - line.unit_rate) / line.unit_rate if line.unit_rate else (D(1) if bill.unit_rate else D(0))
    value_variance = abs(bill.variance) / line.base_amount if line.base_amount else (D(1) if bill.base_amount else D(0))
    if max(quantity_variance, price_variance, value_variance) <= tolerance: _post_bill(member, bill)
    sheet.approved = False; sheet.save(update_fields=['approved'])
    audit(member, 'bill.received', bill, f'Variance {bill.variance}; {bill.status}')
    return bill

@transaction.atomic
def approve_variance(member, bill_id, reason):
    bill = JobSupplierInvoice.objects.select_for_update().get(pk=bill_id, tenant=member.tenant)
    locked_sheet(member, bill.cost_item.sheet_id, 'variance')
    if bill.status != 'Pending': raise ValidationError('This supplier bill is already matched.')
    if not reason.strip(): raise ValidationError('A variance approval reason is required.')
    bill.variance_approved = True; bill.approval_reason = reason; bill.approved_by = member.user
    bill.save(update_fields=['variance_approved', 'approval_reason', 'approved_by'])
    _post_bill(member, bill)
    audit(member, 'bill.variance_approved', bill, reason)

@transaction.atomic
def approve_sheet(member, sheet_id):
    sheet = locked_sheet(member, sheet_id, 'approve')
    if sheet.job.status == 'Draft': raise ValidationError('Book the job before approving its cost sheet.')
    if not sheet.items.filter(side='SELL').exists(): raise ValidationError('Add customer charges first.')
    if sheet.items.filter(side='BUY', supplier_invoice__isnull=True).exists() or sheet.job.supplier_invoices.exclude(status='Matched').exists():
        raise ValidationError('Match all supplier bills before approving the cost sheet.')
    sheet.approved = True; sheet.save(update_fields=['approved'])
    audit(member, 'cost.approved', sheet)

@transaction.atomic
def generate_invoice(member, sheet_ids):
    require(member, 'invoicing.detail.generate', 'C')
    if not sheet_ids: raise ValidationError('Select at least one cost sheet.')
    sheets = list(CostSheet.objects.select_for_update().filter(pk__in=sheet_ids, tenant=member.tenant).select_related('job__customer').order_by('id'))
    if len(sheets) != len(set(map(str, sheet_ids))): raise ValidationError('One or more selected jobs are unavailable.')
    for sheet in sheets:
        require(member, 'invoicing.detail.generate', 'C', sheet)
        if not sheet.approved or sheet.job.status in ('Draft', 'Cancelled'): raise ValidationError('All cost sheets must be approved.')
    customers = {s.job.customer_id for s in sheets}
    if len(customers) != 1: raise ValidationError('Consolidated invoices must have one customer.')
    lines = list(CostSheetItem.objects.filter(sheet__in=sheets, side='SELL', invoice_item__isnull=True).select_related('sheet__job'))
    if not lines: raise ValidationError('All approved charges are already invoiced.')
    rates = {(line.currency, line.fx_rate) for line in lines}
    if len(rates) != 1: raise ValidationError('Use a single currency and exchange rate per invoice.')
    currency, fx = rates.pop(); customer = sheets[0].job.customer
    # A UUID-based number needs no race-prone MAX()+1 counter; accounting sequence can be localized later.
    import uuid
    invoice = CustomerInvoice.objects.create(**attrs(member), customer=customer,
        number=f'INV-{timezone.localdate():%Y%m}-{uuid.uuid4().hex[:10].upper()}', currency=currency, fx_rate=fx,
        due_date=timezone.localdate() + timedelta(days=customer.credit_days),
        company_name=member.tenant.name, company_trn=member.tenant.trn, company_address=member.tenant.address,
        customer_name=customer.name, customer_trn=customer.trn, billing_address=customer.billing_address)
    subtotal = tax_total = D(0)
    for line in lines:
        net = line.amount; tax = rounded(net * line.tax_rate / 100)
        InvoiceItem.objects.create(**attrs(member), invoice=invoice, cost_item=line, job=line.sheet.job,
            description=line.service, quantity=line.quantity, unit_rate=line.unit_rate,
            tax_rate=line.tax_rate, tax_exemption=line.tax_exemption, net=net, tax=tax)
        subtotal += net; tax_total += tax
    invoice.subtotal = subtotal; invoice.tax_total = tax_total; invoice.total = subtotal + tax_total
    invoice.full_clean(); invoice.save()
    audit(member, 'invoice.generated', invoice)
    return invoice

@transaction.atomic
def transition_invoice(member, invoice_id, action):
    invoice = CustomerInvoice.objects.select_for_update().get(pk=invoice_id, tenant=member.tenant)
    require(member, f'invoicing.detail.{action}', 'U', invoice)
    if action == 'approve' and invoice.status == 'Draft': invoice.status = 'Approved'
    elif action == 'issue' and invoice.status == 'Approved':
        net = rounded(invoice.subtotal * invoice.fx_rate); tax = rounded(invoice.tax_total * invoice.fx_rate)
        post(member, f'invoice:{invoice.id}', f'Customer invoice {invoice.number}', [
            ('1100 Receivables', net + tax, 0), ('4000 Freight revenue', 0, net), ('2200 VAT payable', 0, tax)], branch=invoice.branch)
        invoice.status = 'Issued'
    else: raise ValidationError('Invalid invoice state transition.')
    invoice.save(update_fields=['status']); audit(member, f'invoice.{action}', invoice)
    return invoice

@transaction.atomic
def receive_payment(member, invoice_id, receipt):
    invoice = CustomerInvoice.objects.select_for_update().get(pk=invoice_id, tenant=member.tenant)
    require(member, 'invoicing.detail.receipt', 'C', invoice)
    if invoice.status not in ('Issued', 'Partially Paid'): raise ValidationError('Only issued invoices can receive payments.')
    if receipt.amount <= 0 or receipt.amount > invoice.balance: raise ValidationError('Payment must be positive and cannot exceed the balance.')
    receipt.tenant = member.tenant; receipt.branch = invoice.branch; receipt.created_by = member.user; receipt.invoice = invoice
    receipt.full_clean(); receipt.save()
    # Carrying-rate settlement; final receipt clears any rounding residue on the receivable.
    old_paid = invoice.amount_paid; invoice.amount_paid += receipt.amount
    carrying_total = rounded(invoice.subtotal * invoice.fx_rate) + rounded(invoice.tax_total * invoice.fx_rate)
    before = rounded(old_paid / invoice.total * carrying_total) if invoice.total else D(0)
    after = rounded(invoice.amount_paid / invoice.total * carrying_total) if invoice.total else D(0)
    value = after - before
    post(member, f'receipt:{receipt.id}', f'Receipt {receipt.reference}', [('1000 Bank', value, 0), ('1100 Receivables', 0, value)], branch=invoice.branch)
    invoice.status = 'Paid' if invoice.balance == 0 else 'Partially Paid'; invoice.save(update_fields=['amount_paid', 'status'])
    audit(member, 'payment.received', receipt)
    return receipt

@transaction.atomic
def lock_sheet(member, sheet_id):
    sheet = locked_sheet(member, sheet_id, 'lock')
    if not sheet.approved: raise ValidationError('Approve the cost sheet before locking.')
    if sheet.items.filter(side='BUY', supplier_invoice__isnull=True).exists() or sheet.job.supplier_invoices.exclude(status='Matched').exists():
        raise ValidationError('Every buy line must have a matched supplier bill.')
    sell = sheet.items.filter(side='SELL')
    if not sell.exists() or sell.filter(invoice_item__isnull=True).exists() or sell.filter(invoice_item__invoice__status__in=['Draft', 'Approved']).exists():
        raise ValidationError('Issue all customer charges before locking.')
    sheet.locked_at = timezone.now(); sheet.locked_by = member.user; sheet.save(update_fields=['locked_at', 'locked_by'])
    audit(member, 'cost.locked', sheet)

@transaction.atomic
def unlock_sheet(member, sheet_id, reason):
    sheet = CostSheet.objects.select_for_update().get(pk=sheet_id, tenant=member.tenant)
    require(member, 'costs.detail.unlock', 'U', sheet)
    if not reason.strip(): raise ValidationError('Give a reason for unlocking.')
    if not sheet.locked_at: raise ValidationError('The cost sheet is already open.')
    if sheet.job.status in ('Closed', 'Cancelled'):
        raise ValidationError('Closed or cancelled jobs cannot be unlocked in this release.')
    sheet.locked_at = None; sheet.locked_by = None; sheet.save(update_fields=['locked_at', 'locked_by'])
    audit(member, 'cost.unlocked', sheet, reason)

def financials(sheet):
    expected = actual = sell = D(0)
    for item in sheet.items.select_related('supplier_invoice'):
        if item.side == 'SELL': sell += item.base_amount
        else:
            expected += item.base_amount
            actual += item.supplier_invoice.base_amount if hasattr(item, 'supplier_invoice') and item.supplier_invoice.status == 'Matched' else item.base_amount
    margin = sell - actual
    return {'buy': expected, 'actual': actual, 'sell': sell, 'expected_margin': sell - expected,
            'margin': margin, 'margin_percent': rounded(margin / sell * 100) if sell else D(0)}
