"""Tenant-owned ERP schema. Monetary values are Decimal, never binary floats."""
import uuid
from decimal import Decimal, ROUND_HALF_UP
from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator, MaxValueValidator, RegexValidator
from django.db import models
from django.db.models import Q
from django.utils import timezone

ZERO = Decimal('0')
currency_validator = RegexValidator(r'^[A-Z]{3}$', 'Use a three-letter uppercase currency code.')

def money(default=0, **kwargs):
    return models.DecimalField(max_digits=18, decimal_places=2, default=default, **kwargs)

class Tenant(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(max_length=160)
    trn = models.CharField(max_length=40, blank=True)
    address = models.TextField(blank=True)
    base_currency = models.CharField(max_length=3, default='AED', validators=[currency_validator])
    variance_tolerance = models.DecimalField(max_digits=6, decimal_places=2, default=5, validators=[MinValueValidator(0), MaxValueValidator(100)])
    def __str__(self): return self.name

class TenantRow(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    tenant = models.ForeignKey(Tenant, on_delete=models.PROTECT)
    branch = models.CharField(max_length=80, default='Dubai')
    created_by = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.PROTECT)
    created_at = models.DateTimeField(default=timezone.now, editable=False)
    class Meta:
        abstract = True
        indexes = [models.Index(fields=['tenant', 'branch'])]
    def clean(self):
        super().clean()
        for field in self._meta.fields:
            if isinstance(field, models.ForeignKey) and field.name not in ('tenant', 'created_by') and getattr(self, field.attname):
                related = getattr(self, field.name)
                if hasattr(related, 'tenant_id') and related.tenant_id != self.tenant_id:
                    raise ValidationError({field.name: 'Related records must belong to the same company.'})

class Role(TenantRow):
    name = models.CharField(max_length=80)
    description = models.CharField(max_length=240, blank=True)
    class Meta:
        constraints = [models.UniqueConstraint(fields=['tenant', 'name'], name='role_tenant_name')]
    def __str__(self): return self.name

class Membership(models.Model):
    tenant = models.ForeignKey(Tenant, on_delete=models.PROTECT)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    branch = models.CharField(max_length=80, default='Dubai')
    roles = models.ManyToManyField(Role, blank=True)
    active = models.BooleanField(default=True)
    class Meta:
        constraints = [models.UniqueConstraint(fields=['tenant', 'user'], name='membership_tenant_user')]

class GoogleIdentity(models.Model):
    user = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    subject = models.CharField(max_length=255, unique=True)

class Permission(models.Model):
    application = models.CharField(max_length=60)
    window = models.CharField(max_length=60)
    process = models.CharField(max_length=60)
    action = models.CharField(max_length=1, choices=[(s, s) for s in 'CRUDX'])
    class Meta:
        constraints = [models.UniqueConstraint(fields=['application', 'window', 'process', 'action'], name='permission_path_action')]
    def __str__(self): return f'{self.application}.{self.window}.{self.process}:{self.action}'

class Grant(models.Model):
    role = models.ForeignKey(Role, on_delete=models.CASCADE, related_name='grants')
    permission = models.ForeignKey(Permission, on_delete=models.CASCADE)
    scope = models.CharField(max_length=10, choices=[(s, s.title()) for s in ['none', 'self', 'branch', 'global']], default='none')
    can_export = models.BooleanField(default=False)
    class Meta:
        constraints = [models.UniqueConstraint(fields=['role', 'permission'], name='grant_role_permission')]

class PriceList(TenantRow):
    name = models.CharField(max_length=120)
    currency = models.CharField(max_length=3, default='AED', validators=[currency_validator])
    valid_from = models.DateField(default=timezone.localdate)
    valid_until = models.DateField(null=True, blank=True)
    is_default = models.BooleanField(default=False)
    def clean(self):
        super().clean()
        if self.valid_until and self.valid_until < self.valid_from:
            raise ValidationError('The end date must follow the start date.')
    def __str__(self): return self.name

class Tariff(TenantRow):
    price_list = models.ForeignKey(PriceList, on_delete=models.PROTECT, related_name='tariffs')
    service = models.CharField(max_length=120)
    unit = models.CharField(max_length=24, default='shipment')
    route = models.CharField(max_length=160, blank=True)
    buy_rate = money(validators=[MinValueValidator(0)])
    sell_rate = money(validators=[MinValueValidator(0)])
    def __str__(self): return f'{self.service} / {self.unit}'

class Customer(TenantRow):
    code = models.CharField(max_length=24)
    name = models.CharField(max_length=160)
    trn = models.CharField(max_length=40, blank=True)
    contact = models.CharField(max_length=120, blank=True)
    email = models.EmailField(blank=True)
    phone = models.CharField(max_length=40, blank=True)
    city = models.CharField(max_length=80, blank=True)
    billing_address = models.TextField(blank=True)
    shipping_address = models.TextField(blank=True)
    currency = models.CharField(max_length=3, default='AED', validators=[currency_validator])
    credit_limit = money(validators=[MinValueValidator(0)])
    credit_days = models.PositiveIntegerField(default=30)
    payment_terms = models.CharField(max_length=120, default='Net 30 days')
    price_list = models.ForeignKey(PriceList, null=True, blank=True, on_delete=models.PROTECT)
    class Meta:
        constraints = [models.UniqueConstraint(fields=['tenant', 'code'], name='customer_tenant_code')]
    def __str__(self): return self.name

class Supplier(TenantRow):
    TYPES = ['Ocean Line', 'Air Carrier', 'Customs Broker', 'Trucker', 'Port Agent', 'Other']
    code = models.CharField(max_length=24)
    name = models.CharField(max_length=160)
    service_type = models.CharField(max_length=40, choices=[(s, s) for s in TYPES])
    trn = models.CharField(max_length=40, blank=True)
    contact = models.CharField(max_length=120, blank=True)
    email = models.EmailField(blank=True)
    phone = models.CharField(max_length=40, blank=True)
    bank_details = models.TextField(blank=True)
    currency = models.CharField(max_length=3, default='AED', validators=[currency_validator])
    payment_terms = models.CharField(max_length=120, default='Net 30 days')
    credit_days = models.PositiveIntegerField(default=30)
    class Meta:
        constraints = [models.UniqueConstraint(fields=['tenant', 'code'], name='supplier_tenant_code')]
    def __str__(self): return self.name

class Job(TenantRow):
    MODES = ['Ocean', 'Air', 'Road', 'Multimodal']
    STATUSES = ['Draft', 'Booked', 'In transit', 'Delivered', 'Closed', 'Cancelled']
    number = models.CharField(max_length=40)
    customer = models.ForeignKey(Customer, on_delete=models.PROTECT, related_name='jobs')
    status = models.CharField(max_length=20, choices=[(s, s) for s in STATUSES], default='Draft')
    mode = models.CharField(max_length=20, choices=[(s, s) for s in MODES], default='Ocean')
    client_reference = models.CharField(max_length=100, blank=True)
    supplier_job_number = models.CharField(max_length=100, blank=True)
    master_bl = models.CharField(max_length=100, blank=True)
    house_bl = models.CharField(max_length=100, blank=True)
    bayan_number = models.CharField(max_length=100, blank=True)
    delivery_order = models.CharField(max_length=100, blank=True)
    pol = models.CharField('Port of loading', max_length=100)
    pod = models.CharField('Port of discharge', max_length=100)
    vessel = models.CharField(max_length=100, blank=True)
    voyage = models.CharField('Voyage / flight', max_length=60, blank=True)
    shipper = models.CharField(max_length=160, blank=True)
    consignee = models.CharField(max_length=160, blank=True)
    commodity = models.TextField(blank=True)
    gross_weight = models.DecimalField(max_digits=14, decimal_places=3, default=0, validators=[MinValueValidator(0)])
    chargeable_weight = models.DecimalField(max_digits=14, decimal_places=3, default=0, validators=[MinValueValidator(0)])
    volume = models.DecimalField('Volume (CBM)', max_digits=14, decimal_places=3, default=0, validators=[MinValueValidator(0)])
    packages = models.PositiveIntegerField(default=0)
    booking_date = models.DateField(default=timezone.localdate)
    delivery_date = models.DateField(null=True, blank=True)
    milestone_date = models.DateField(null=True, blank=True)
    credit_due_date = models.DateField(null=True, blank=True)
    pod_reference = models.CharField('Proof of delivery reference', max_length=240, blank=True)
    class Meta:
        constraints = [models.UniqueConstraint(fields=['tenant', 'number'], name='job_tenant_number')]
        indexes = [models.Index(fields=['tenant', 'status']), models.Index(fields=['tenant', 'master_bl'])]
    def __str__(self): return self.number

class CostSheet(TenantRow):
    job = models.OneToOneField(Job, on_delete=models.PROTECT, related_name='cost_sheet')
    locked_at = models.DateTimeField(null=True, blank=True)
    locked_by = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.PROTECT, related_name='+')
    approved = models.BooleanField(default=False)

class CostSheetItem(TenantRow):
    sheet = models.ForeignKey(CostSheet, on_delete=models.PROTECT, related_name='items')
    side = models.CharField(max_length=4, choices=[('BUY', 'Buy'), ('SELL', 'Sell')])
    service = models.CharField(max_length=120)
    supplier = models.ForeignKey(Supplier, on_delete=models.PROTECT, null=True, blank=True)
    tariff = models.ForeignKey(Tariff, on_delete=models.PROTECT, null=True, blank=True)
    quantity = models.DecimalField(max_digits=14, decimal_places=3, default=1, validators=[MinValueValidator(Decimal('.001'))])
    unit_rate = money(validators=[MinValueValidator(0)])
    currency = models.CharField(max_length=3, default='AED', validators=[currency_validator])
    fx_rate = models.DecimalField('Base currency per unit', max_digits=16, decimal_places=8, default=1, validators=[MinValueValidator(Decimal('.00000001'))])
    tax_rate = models.DecimalField(max_digits=5, decimal_places=2, default=5, validators=[MinValueValidator(0), MaxValueValidator(100)])
    tax_exemption = models.CharField(max_length=160, blank=True)
    accrued = models.BooleanField(default=False)
    @property
    def amount(self): return (Decimal(self.quantity) * Decimal(self.unit_rate)).quantize(Decimal('.01'), rounding=ROUND_HALF_UP)
    @property
    def base_amount(self): return (self.amount * Decimal(self.fx_rate)).quantize(Decimal('.01'), rounding=ROUND_HALF_UP)
    def clean(self):
        super().clean()
        if self.side == 'BUY' and not self.supplier_id:
            raise ValidationError({'supplier': 'A buy line requires a supplier.'})
        if self.currency == self.tenant.base_currency and self.fx_rate != 1:
            raise ValidationError({'fx_rate': 'Base currency must have an exchange rate of 1.'})
        if self.side == 'SELL' and self.tax_rate == 0 and not self.tax_exemption:
            raise ValidationError({'tax_exemption': 'Explain zero-rated or exempt treatment.'})
    class Meta:
        constraints = [models.CheckConstraint(condition=Q(quantity__gt=0) & Q(unit_rate__gte=0) & Q(fx_rate__gt=0), name='cost_positive_values')]

class JobSupplierInvoice(TenantRow):
    job = models.ForeignKey(Job, on_delete=models.PROTECT, related_name='supplier_invoices')
    cost_item = models.OneToOneField(CostSheetItem, on_delete=models.PROTECT, related_name='supplier_invoice')
    supplier = models.ForeignKey(Supplier, on_delete=models.PROTECT, related_name='invoices')
    number = models.CharField(max_length=80)
    invoice_date = models.DateField(default=timezone.localdate)
    due_date = models.DateField()
    quantity = models.DecimalField(max_digits=14, decimal_places=3, validators=[MinValueValidator(Decimal('.001'))])
    unit_rate = money(validators=[MinValueValidator(0)])
    currency = models.CharField(max_length=3, validators=[currency_validator])
    fx_rate = models.DecimalField(max_digits=16, decimal_places=8, default=1, validators=[MinValueValidator(Decimal('.00000001'))])
    variance = money()
    variance_approved = models.BooleanField(default=False)
    approval_reason = models.CharField(max_length=240, blank=True)
    approved_by = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.PROTECT, related_name='+')
    status = models.CharField(max_length=20, default='Pending', choices=[('Pending', 'Pending variance'), ('Matched', 'Matched')])
    @property
    def amount(self): return (Decimal(self.quantity) * Decimal(self.unit_rate)).quantize(Decimal('.01'), rounding=ROUND_HALF_UP)
    @property
    def base_amount(self): return (self.amount * Decimal(self.fx_rate)).quantize(Decimal('.01'), rounding=ROUND_HALF_UP)
    class Meta:
        constraints = [models.UniqueConstraint(fields=['tenant', 'supplier', 'number', 'cost_item'], name='supplier_bill_line_unique'),
                       models.CheckConstraint(condition=Q(quantity__gt=0) & Q(unit_rate__gte=0) & Q(fx_rate__gt=0), name='bill_positive_values')]

class CustomerInvoice(TenantRow):
    customer = models.ForeignKey(Customer, on_delete=models.PROTECT, related_name='invoices')
    number = models.CharField(max_length=40)
    currency = models.CharField(max_length=3, validators=[currency_validator])
    fx_rate = models.DecimalField(max_digits=16, decimal_places=8, default=1, validators=[MinValueValidator(Decimal('.00000001'))])
    invoice_date = models.DateField(default=timezone.localdate)
    due_date = models.DateField()
    status = models.CharField(max_length=20, default='Draft', choices=[(s, s) for s in ['Draft', 'Approved', 'Issued', 'Partially Paid', 'Paid']])
    company_name = models.CharField(max_length=160)
    company_trn = models.CharField(max_length=40, blank=True)
    company_address = models.TextField(blank=True)
    customer_name = models.CharField(max_length=160)
    customer_trn = models.CharField(max_length=40, blank=True)
    billing_address = models.TextField(blank=True)
    subtotal = money()
    tax_total = money()
    total = money()
    amount_paid = money()
    @property
    def balance(self): return self.total - self.amount_paid
    @property
    def display_status(self):
        if self.status in ('Issued', 'Partially Paid') and self.due_date < timezone.localdate(): return 'Overdue'
        return self.status
    class Meta:
        constraints = [models.UniqueConstraint(fields=['tenant', 'number'], name='invoice_tenant_number'),
                       models.CheckConstraint(condition=Q(total__gte=0) & Q(amount_paid__gte=0) & Q(amount_paid__lte=models.F('total')), name='invoice_valid_payment')]
    def __str__(self): return self.number

class InvoiceItem(TenantRow):
    invoice = models.ForeignKey(CustomerInvoice, on_delete=models.PROTECT, related_name='items')
    cost_item = models.OneToOneField(CostSheetItem, on_delete=models.PROTECT, related_name='invoice_item')
    job = models.ForeignKey(Job, on_delete=models.PROTECT)
    description = models.CharField(max_length=160)
    quantity = models.DecimalField(max_digits=14, decimal_places=3)
    unit_rate = money()
    tax_rate = models.DecimalField(max_digits=5, decimal_places=2)
    tax_exemption = models.CharField(max_length=160, blank=True)
    net = money()
    tax = money()

class Receipt(TenantRow):
    invoice = models.ForeignKey(CustomerInvoice, on_delete=models.PROTECT, related_name='receipts')
    reference = models.CharField(max_length=80)
    amount = money(validators=[MinValueValidator(Decimal('.01'))])
    received_on = models.DateField(default=timezone.localdate)
    class Meta:
        constraints = [models.UniqueConstraint(fields=['tenant', 'reference'], name='receipt_tenant_reference'),
                       models.CheckConstraint(condition=Q(amount__gt=0), name='receipt_positive')]

class JournalEntry(TenantRow):
    posting_transaction = models.BigIntegerField(default=0, editable=False)
    source_key = models.CharField(max_length=160)
    description = models.CharField(max_length=240)
    posted_on = models.DateField(default=timezone.localdate)
    job = models.ForeignKey(Job, null=True, blank=True, on_delete=models.PROTECT)
    class Meta:
        constraints = [models.UniqueConstraint(fields=['tenant', 'source_key'], name='journal_source_once')]
    def save(self, *args, **kwargs):
        if not self._state.adding: raise ValidationError('Posted journals are immutable; use a reversal.')
        return super().save(*args, **kwargs)
    def delete(self, *args, **kwargs): raise ValidationError('Posted journals cannot be deleted.')

class JournalLine(models.Model):
    entry = models.ForeignKey(JournalEntry, on_delete=models.PROTECT, related_name='lines')
    account = models.CharField(max_length=40, choices=[(s, s) for s in ['1000 Bank', '1100 Receivables', '2000 Accrued costs', '2100 Payables', '2200 VAT payable', '4000 Freight revenue', '5000 Direct costs']])
    debit = money()
    credit = money()
    class Meta:
        constraints = [models.CheckConstraint(condition=(Q(debit__gt=0, credit=0) | Q(credit__gt=0, debit=0)), name='journal_one_positive_side')]
    def save(self, *args, **kwargs): raise ValidationError('Use the journal posting service.')
    def delete(self, *args, **kwargs): raise ValidationError('Posted journals cannot be deleted.')

class AuditEvent(TenantRow):
    action = models.CharField(max_length=80)
    object_type = models.CharField(max_length=60)
    object_id = models.CharField(max_length=80)
    detail = models.TextField(blank=True)
