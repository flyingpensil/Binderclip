from django import forms
from .models import Customer, Supplier, Job, CostSheetItem, JobSupplierInvoice, PriceList, Tariff, Role, Receipt
from .security import scoped

class TenantForm(forms.ModelForm):
    def __init__(self, *args, member, **kwargs):
        super().__init__(*args, **kwargs)
        self.member = member
        self.instance.tenant = member.tenant
        for name, field in self.fields.items():
            if isinstance(field, forms.ModelChoiceField):
                paths = {'customer': 'customers.list.manage', 'supplier': 'suppliers.list.manage',
                         'price_list': 'masters.rates.manage', 'tariff': 'masters.rates.manage'}
                if name in paths:
                    field.queryset = scoped(field.queryset.model, member, paths[name])
                else: field.queryset = field.queryset.filter(tenant=member.tenant)
            if isinstance(field, forms.DateField): field.widget = forms.DateInput(attrs={'type': 'date'})
            if isinstance(field.widget, forms.Textarea): field.widget.attrs['rows'] = 3

class CustomerForm(TenantForm):
    class Meta:
        model = Customer
        fields = ['code', 'name', 'trn', 'contact', 'email', 'phone', 'city', 'billing_address', 'shipping_address', 'currency', 'credit_limit', 'credit_days', 'payment_terms', 'price_list']

class SupplierForm(TenantForm):
    class Meta:
        model = Supplier
        fields = ['code', 'name', 'service_type', 'trn', 'contact', 'email', 'phone', 'bank_details', 'currency', 'payment_terms', 'credit_days']

class JobForm(TenantForm):
    class Meta:
        model = Job
        exclude = ['id', 'tenant', 'branch', 'created_by', 'created_at', 'status']

class CostItemForm(TenantForm):
    class Meta:
        model = CostSheetItem
        fields = ['side', 'service', 'supplier', 'tariff', 'quantity', 'unit_rate', 'currency', 'fx_rate', 'tax_rate', 'tax_exemption']

class BillForm(TenantForm):
    class Meta:
        model = JobSupplierInvoice
        fields = ['cost_item', 'supplier', 'number', 'invoice_date', 'due_date', 'quantity', 'unit_rate', 'currency', 'fx_rate']
    def __init__(self, *args, sheet, **kwargs):
        super().__init__(*args, **kwargs)
        self.instance.job = sheet.job
        self.fields['cost_item'].queryset = sheet.items.filter(side='BUY', accrued=True, supplier_invoice__isnull=True)
        self.fields['cost_item'].label_from_instance = lambda item: f'{item.service} · {item.currency} {item.amount}'

class PriceListForm(TenantForm):
    class Meta:
        model = PriceList
        fields = ['name', 'currency', 'valid_from', 'valid_until', 'is_default']

class TariffForm(TenantForm):
    class Meta:
        model = Tariff
        fields = ['price_list', 'service', 'unit', 'route', 'buy_rate', 'sell_rate']

class RoleForm(TenantForm):
    class Meta:
        model = Role
        fields = ['name', 'description']

class ReceiptForm(TenantForm):
    class Meta:
        model = Receipt
        fields = ['reference', 'amount', 'received_on']

class MemberForm(forms.Form):
    email = forms.EmailField()
    name = forms.CharField(max_length=150)
    branch = forms.CharField(max_length=80, initial='Dubai')
    roles = forms.ModelMultipleChoiceField(queryset=Role.objects.none(), widget=forms.CheckboxSelectMultiple)
    def __init__(self, *args, member, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields['roles'].queryset = Role.objects.filter(tenant=member.tenant)
