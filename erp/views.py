import csv
import hashlib
from decimal import Decimal
from django.contrib import messages
from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError, PermissionDenied
from django.db import transaction
from django.db.models import Q, Sum
from django.http import HttpResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.utils import timezone
from django.utils.dateparse import parse_date
from django.views.decorators.http import require_POST
from . import forms, services
from .models import (Customer, Supplier, Job, CostSheet, CostSheetItem, JobSupplierInvoice, CustomerInvoice,
                     PriceList, Tariff, Role, Permission, Grant, Membership, JournalEntry, AuditEvent)
from .security import access, scoped, scoped_memberships, require, grants, scope_filter, CATALOG

def find(qs, query, fields):
    if not query: return qs
    condition = Q()
    for field in fields: condition |= Q(**{field + '__icontains': query})
    return qs.filter(condition)

def dated(qs, request, field):
    for key, lookup in [('from', 'gte'), ('to', 'lte')]:
        value = request.GET.get(key, '')
        try: day = parse_date(value) if value else None
        except ValueError: day = None
        if value and not day: messages.error(request, f'Invalid {key} date. Use YYYY-MM-DD.')
        if day: qs = qs.filter(**{f'{field}__{lookup}': day})
    return qs

def show_errors(request, exc):
    messages.error(request, ' '.join(exc.messages))

@access('overview.dashboard.view')
def dashboard(request):
    member = request.membership
    # Dashboard access does not confer access to the underlying operational modules.
    jobs = scoped(Job, member, 'jobs.list.manage').filter(scope_filter(member, 'overview.dashboard.view')).select_related('customer', 'cost_sheet')
    invoices = scoped(CustomerInvoice, member, 'invoicing.list.manage').filter(scope_filter(member, 'overview.dashboard.view'))
    base_invoices = invoices.filter(currency=member.tenant.base_currency)
    open_ar = sum((i.balance for i in base_invoices.exclude(status__in=['Draft', 'Approved', 'Paid'])), Decimal(0))
    cards = [(job, services.financials(job.cost_sheet)) for job in jobs.order_by('-created_at')[:6]]
    return render(request, 'dashboard.html', {'job_count': jobs.exclude(status__in=['Closed', 'Cancelled']).count(),
        'customer_count': scoped(Customer, member, 'customers.list.manage').filter(scope_filter(member, 'overview.dashboard.view')).count(), 'open_ar': open_ar,
        'pending_count': scoped(JobSupplierInvoice, member, 'costs.detail.manage').filter(scope_filter(member, 'overview.dashboard.view'), status='Pending').count(),
        'recent_jobs': cards, 'invoices': invoices.order_by('-created_at')[:4],
        'today': timezone.localdate(), 'page': 'dashboard'})

ENTITY = {
    'customers': (Customer, forms.CustomerForm, 'customers.list.manage', ['name', 'code', 'trn', 'contact', 'city']),
    'suppliers': (Supplier, forms.SupplierForm, 'suppliers.list.manage', ['name', 'code', 'service_type', 'trn']),
    'jobs': (Job, forms.JobForm, 'jobs.list.manage', ['number', 'customer__name', 'vessel', 'bayan_number', 'master_bl', 'house_bl', 'client_reference']),
    'rates': (PriceList, forms.PriceListForm, 'masters.rates.manage', ['name', 'currency']),
}

def entity_list(request, kind):
    model, form_class, path, fields = ENTITY[kind]
    if not request.user.is_authenticated: return redirect('login')
    require(request.membership, path, 'R')
    query = request.GET.get('q', '').strip()
    rows = find(scoped(model, request.membership, path), query, fields).order_by('-created_at')
    if kind == 'jobs':
        rows = rows.select_related('customer', 'cost_sheet')
        rows = dated(rows, request, 'booking_date')
        if request.GET.get('status'): rows = rows.filter(status=request.GET['status'])
        if request.GET.get('mode'): rows = rows.filter(mode=request.GET['mode'])
    return render(request, 'list.html', {'rows': rows[:200], 'total': rows.count(), 'kind': kind, 'page': kind,
        'title': {'rates': 'Rate cards'}.get(kind, kind.title()), 'query': query,
        'can_create': grants(request.membership, path, 'C').exists(), 'statuses': Job.STATUSES, 'modes': Job.MODES})

def entity_form(request, kind, pk=None):
    model, form_class, path, _ = ENTITY[kind]
    if not request.user.is_authenticated: return redirect('login')
    member = request.membership; action = 'U' if pk else 'C'; require(member, path, action)
    obj = get_object_or_404(scoped(model, member, path, action), pk=pk) if pk else None
    form = form_class(request.POST or None, instance=obj, member=member)
    if request.method == 'POST' and form.is_valid():
        try:
            with transaction.atomic():
                if kind == 'jobs' and obj:
                    sheet = CostSheet.objects.select_for_update().get(job=obj)
                    if sheet.locked_at or sheet.job.status != 'Draft': raise ValidationError('Job details are editable only while the job is a draft.')
                item = form.save(commit=False)
                if not obj:
                    item.branch = member.branch; item.created_by = member.user
                if kind == 'jobs' and not obj: services.create_job(member, item)
                else:
                    item.full_clean(); item.save(); services.audit(member, f'{kind}.saved', item)
            messages.success(request, f'{kind.title().rstrip("s")} saved.')
            return redirect('job-detail', pk=item.pk) if kind == 'jobs' else redirect(kind)
        except ValidationError as exc: form.add_error(None, exc)
    return render(request, 'form.html', {'form': form, 'title': f'{"Edit" if pk else "New"} {"rate card" if kind == "rates" else kind.rstrip("s")}', 'page': kind, 'back': kind})

@access('jobs.list.manage')
def job_detail(request, pk):
    job = get_object_or_404(scoped(Job, request.membership, 'jobs.list.manage'), pk=pk)
    sheet = job.cost_sheet
    require(request.membership, 'costs.detail.manage', 'R', sheet)
    return render(request, 'job.html', {'job': job, 'sheet': sheet, 'items': sheet.items.select_related('supplier', 'supplier_invoice'),
        'figures': services.financials(sheet), 'bills': job.supplier_invoices.select_related('supplier'),
        'page': 'jobs', 'job_invoices': scoped(CustomerInvoice, request.membership, 'invoicing.list.manage').filter(items__job=job).distinct(),
        'events': AuditEvent.objects.filter(tenant=request.membership.tenant, object_id__in=[str(job.id), str(sheet.id)]).order_by('-created_at')[:12]})

@access('costs.detail.manage', 'C')
def cost_line(request, pk):
    sheet = get_object_or_404(scoped(CostSheet, request.membership, 'costs.detail.manage', 'C'), job_id=pk)
    today = timezone.localdate()
    tariffs = scoped(Tariff, request.membership, 'masters.rates.manage').filter(price_list__valid_from__lte=today).filter(Q(price_list__valid_until__isnull=True) | Q(price_list__valid_until__gte=today)).select_related('price_list')
    if sheet.job.customer.price_list_id:
        tariffs = tariffs.filter(price_list_id=sheet.job.customer.price_list_id)
    else: tariffs = tariffs.filter(price_list__is_default=True)
    initial = {}
    if request.method == 'GET' and request.GET.get('tariff'):
        tariff = get_object_or_404(tariffs, pk=request.GET['tariff'])
        side = 'BUY' if request.GET.get('side') == 'BUY' else 'SELL'
        initial = {'tariff': tariff, 'service': tariff.service, 'side': side, 'quantity': 1,
                   'unit_rate': tariff.buy_rate if side == 'BUY' else tariff.sell_rate,
                   'currency': tariff.price_list.currency, 'fx_rate': 1 if tariff.price_list.currency == request.membership.tenant.base_currency else None}
    form = forms.CostItemForm(request.POST or None, member=request.membership, initial=initial)
    if request.method == 'POST' and form.is_valid():
        try:
            services.add_line(request.membership, sheet.id, form.save(commit=False))
            messages.success(request, 'Cost line added.'); return redirect('job-detail', pk=pk)
        except ValidationError as exc: form.add_error(None, exc)
    return render(request, 'form.html', {'form': form, 'title': 'Add cost sheet line', 'page': 'jobs', 'job_back': pk, 'tariff_suggestions': tariffs})

@access('costs.detail.match', 'C')
def supplier_bill(request, pk):
    sheet = get_object_or_404(scoped(CostSheet, request.membership, 'costs.detail.match', 'C'), job_id=pk)
    form = forms.BillForm(request.POST or None, member=request.membership, sheet=sheet)
    if request.method == 'POST' and form.is_valid():
        try:
            bill = services.match_bill(request.membership, sheet.id, form.save(commit=False))
            messages.success(request, f'Bill recorded: {bill.status}.'); return redirect('job-detail', pk=pk)
        except ValidationError as exc: form.add_error(None, exc)
    return render(request, 'form.html', {'form': form, 'title': 'Match supplier invoice', 'page': 'jobs', 'job_back': pk})

@require_POST
@access('jobs.list.manage')
def job_action(request, pk, action):
    job = get_object_or_404(scoped(Job, request.membership, 'jobs.list.manage'), pk=pk)
    member = request.membership
    try:
        operations = {'book': lambda: services.book_job(member, job.cost_sheet.id),
            'approve': lambda: services.approve_sheet(member, job.cost_sheet.id),
            'lock': lambda: services.lock_sheet(member, job.cost_sheet.id),
            'unlock': lambda: services.unlock_sheet(member, job.cost_sheet.id, request.POST.get('reason', ''))}
        if action == 'invoice':
            invoice = services.generate_invoice(member, [str(job.cost_sheet.id)])
            return redirect('invoice-detail', pk=invoice.id)
        elif action == 'variance':
            bill = get_object_or_404(JobSupplierInvoice, pk=request.POST.get('bill_id'), job=job, tenant=member.tenant)
            services.approve_variance(member, bill.id, request.POST.get('reason', ''))
        elif action == 'status':
            require(member, 'jobs.detail.status', 'U', job)
            with transaction.atomic():
                sheet = CostSheet.objects.select_for_update().get(job=job)
                job = Job.objects.select_for_update().get(pk=job.pk)
                status = request.POST.get('status')
                transitions = {'Draft': ['Cancelled'], 'Booked': ['In transit'], 'In transit': ['Delivered'], 'Delivered': ['Closed']}
                if status not in transitions.get(job.status, []): raise ValidationError('Invalid job status transition.')
                if status == 'Closed' and not sheet.locked_at: raise ValidationError('Lock the cost sheet before closing the job.')
                job.status = status; job.save(update_fields=['status']); services.audit(member, 'job.status_changed', job, status)
        elif action in operations: operations[action]()
        else: raise ValidationError('Unknown action.')
        messages.success(request, 'Job updated.')
    except ValidationError as exc: show_errors(request, exc)
    return redirect('job-detail', pk=pk)

@access('invoicing.list.manage')
def invoices(request):
    rows = find(scoped(CustomerInvoice, request.membership, 'invoicing.list.manage'), request.GET.get('q', ''), ['number', 'customer_name', 'items__job__number']).distinct()
    rows = dated(rows, request, 'invoice_date')
    status = request.GET.get('status')
    if status == 'Overdue': rows = rows.filter(status__in=['Issued', 'Partially Paid'], due_date__lt=timezone.localdate())
    elif status: rows = rows.filter(status=status)
    return render(request, 'invoices.html', {'rows': rows.order_by('-created_at')[:200], 'page': 'invoices',
        'sheets': scoped(CostSheet, request.membership, 'invoicing.detail.generate', 'C').filter(approved=True, items__side='SELL', items__invoice_item__isnull=True).select_related('job__customer').distinct(),
        'statuses': ['Draft', 'Approved', 'Issued', 'Partially Paid', 'Paid', 'Overdue']})

@require_POST
@access('invoicing.detail.generate', 'C')
def consolidate(request):
    try:
        invoice = services.generate_invoice(request.membership, request.POST.getlist('sheets'))
        return redirect('invoice-detail', pk=invoice.id)
    except (ValidationError, ValueError) as exc:
        messages.error(request, ' '.join(exc.messages) if isinstance(exc, ValidationError) else 'Invalid cost sheet selection.')
        return redirect('invoices')

@access('invoicing.list.manage')
def invoice_detail(request, pk):
    invoice = get_object_or_404(scoped(CustomerInvoice, request.membership, 'invoicing.list.manage'), pk=pk)
    return render(request, 'invoice.html', {'invoice': invoice, 'page': 'invoices', 'items': invoice.items.select_related('job')})

@access('invoicing.detail.print', 'X')
def invoice_print(request, pk):
    invoice = get_object_or_404(scoped(CustomerInvoice, request.membership, 'invoicing.detail.print', 'X'), pk=pk)
    return render(request, 'print.html', {'invoice': invoice, 'items': invoice.items.select_related('job')})

@require_POST
@access('invoicing.list.manage')
def invoice_action(request, pk, action):
    invoice = get_object_or_404(scoped(CustomerInvoice, request.membership, 'invoicing.list.manage'), pk=pk)
    if action not in ('approve', 'issue'): raise PermissionDenied('Unknown action.')
    try:
        services.transition_invoice(request.membership, invoice.id, action); messages.success(request, 'Invoice updated.')
    except ValidationError as exc: show_errors(request, exc)
    return redirect('invoice-detail', pk=pk)

@access('invoicing.detail.receipt', 'C')
def receipt(request, pk):
    invoice = get_object_or_404(scoped(CustomerInvoice, request.membership, 'invoicing.detail.receipt', 'C'), pk=pk)
    form = forms.ReceiptForm(request.POST or None, member=request.membership)
    form.instance.invoice = invoice
    if request.method == 'POST' and form.is_valid():
        try:
            services.receive_payment(request.membership, pk, form.save(commit=False))
            messages.success(request, 'Payment recorded.'); return redirect('invoice-detail', pk=pk)
        except ValidationError as exc: form.add_error(None, exc)
    return render(request, 'form.html', {'form': form, 'title': f'Record payment · {invoice.number} ({invoice.currency})', 'page': 'invoices', 'back': 'invoices'})

def safe_csv(value):
    text = str(value)
    return "'" + text if text.lstrip().startswith(('=', '+', '-', '@', '\t', '\r', '\n')) else text

def csv_response(name, headers, rows):
    response = HttpResponse(content_type='text/csv; charset=utf-8')
    response['Content-Disposition'] = f'attachment; filename="{name}.csv"'
    response.write('\ufeff')
    writer = csv.writer(response); writer.writerow(headers)
    for row in rows: writer.writerow([safe_csv(value) for value in row])
    return response

def ledger(request, kind, pk):
    if kind not in ('customers', 'suppliers'): raise PermissionDenied()
    if not request.user.is_authenticated: return redirect('login')
    path = f'{kind}.ledger.view'; require(request.membership, path, 'R')
    party_model = Customer if kind == 'customers' else Supplier
    party = get_object_or_404(scoped(party_model, request.membership, path), pk=pk)
    query = request.GET.get('q', '')
    model = CustomerInvoice if kind == 'customers' else JobSupplierInvoice
    rows = scoped(model, request.membership, path).filter(**{'customer' if kind == 'customers' else 'supplier': party})
    rows = find(rows, query, ['number', 'items__job__number'] if kind == 'customers' else ['number', 'job__number']).distinct()
    rows = dated(rows, request, 'invoice_date')
    if request.GET.get('status'):
        status = request.GET['status']
        if status == 'Overdue' and kind == 'customers': rows = rows.filter(status__in=['Issued', 'Partially Paid'], due_date__lt=timezone.localdate())
        else: rows = rows.filter(status=status)
    if request.GET.get('export'):
        require(request.membership, path, 'X', party)
        rows = rows.filter(scope_filter(request.membership, path, 'X'))
        return csv_response('ledger', ['Invoice', 'Date', 'Currency', 'Amount', 'Status'], [(i.number, i.invoice_date, i.currency, i.total if kind == 'customers' else i.amount, i.display_status if kind == 'customers' else i.status) for i in rows])
    jobs = scoped(Job, request.membership, 'jobs.list.manage')
    if kind == 'customers': jobs = jobs.filter(customer=party)
    else: jobs = jobs.filter(cost_sheet__items__supplier=party).distinct()
    commitments = scoped(CostSheetItem, request.membership, path).filter(supplier=party, side='BUY').select_related('sheet__job', 'supplier_invoice') if kind == 'suppliers' else []
    return render(request, 'ledger.html', {'party': party, 'kind': kind, 'page': kind, 'rows': rows.order_by('-created_at')[:200], 'jobs': jobs[:50], 'commitments': commitments, 'query': query,
        'statuses': ['Draft', 'Approved', 'Issued', 'Partially Paid', 'Paid', 'Overdue'] if kind == 'customers' else ['Pending', 'Matched']})

@access('masters.rates.manage')
def rate_detail(request, pk):
    rate = get_object_or_404(scoped(PriceList, request.membership, 'masters.rates.manage'), pk=pk)
    form = forms.TariffForm(request.POST or None, member=request.membership, initial={'price_list': rate})
    form.fields['price_list'].queryset = PriceList.objects.filter(pk=rate.id)
    if request.method == 'POST':
        require(request.membership, 'masters.rates.manage', 'C', rate)
        if form.is_valid():
            item = form.save(commit=False); item.branch = request.membership.branch; item.created_by = request.user
            item.full_clean(); item.save(); services.audit(request.membership, 'tariff.created', item)
            messages.success(request, 'Tariff added.'); return redirect('rate-detail', pk=pk)
    return render(request, 'rates.html', {'rate': rate, 'tariffs': rate.tariffs.filter(scope_filter(request.membership, 'masters.rates.manage')), 'form': form, 'page': 'rates'})

@access('reports.journal.view')
def journal(request):
    entries = scoped(JournalEntry, request.membership, 'reports.journal.view').prefetch_related('lines').order_by('-created_at')
    entries = dated(find(entries, request.GET.get('q', ''), ['description', 'source_key', 'job__number']), request, 'posted_on')
    if request.GET.get('export'):
        require(request.membership, 'reports.journal.view', 'X')
        entries = entries.filter(scope_filter(request.membership, 'reports.journal.view', 'X'))
        return csv_response('journal', ['Date', 'Reference', 'Account', 'Debit', 'Credit'], [(e.posted_on, e.source_key, line.account, line.debit, line.credit) for e in entries for line in e.lines.all()])
    lines = [line for entry in entries for line in entry.lines.all()]
    return render(request, 'journal.html', {'entries': entries[:200], 'page': 'journal', 'debits': sum((l.debit for l in lines), Decimal(0)), 'credits': sum((l.credit for l in lines), Decimal(0))})

@access('settings.roles.manage')
def roles(request):
    return render(request, 'roles.html', {'roles': scoped(Role, request.membership, 'settings.roles.manage'),
        'members': scoped_memberships(request.membership).select_related('user').prefetch_related('roles'), 'page': 'roles'})

@access('settings.roles.manage', 'C')
def role_create(request):
    form = forms.RoleForm(request.POST or None, member=request.membership)
    if request.method == 'POST' and form.is_valid():
        role = form.save(commit=False); role.branch = request.membership.branch; role.created_by = request.user
        role.save(); services.audit(request.membership, 'role.created', role)
        return redirect('role-detail', pk=role.id)
    return render(request, 'form.html', {'form': form, 'title': 'Create role', 'page': 'roles', 'back': 'roles'})

@access('settings.roles.manage')
def role_detail(request, pk):
    role = get_object_or_404(scoped(Role, request.membership, 'settings.roles.manage'), pk=pk)
    permissions = Permission.objects.order_by('application', 'window', 'process', 'action')
    if request.method == 'POST':
        require(request.membership, 'settings.roles.manage', 'U', role)
        # A role administrator is a company security administrator. This is deliberately an elevated permission.
        with transaction.atomic():
            Role.objects.select_for_update().get(pk=role.pk)
            for permission in permissions:
                scope = request.POST.get(f'scope_{permission.pk}', 'none')
                if scope not in ('none', 'self', 'branch', 'global'): raise PermissionDenied('Invalid grant scope.')
                Grant.objects.update_or_create(role=role, permission=permission, defaults={'scope': scope, 'can_export': request.POST.get(f'export_{permission.pk}') == 'on'})
            services.audit(request.membership, 'role.permissions_changed', role)
        messages.success(request, 'Permission matrix updated.'); return redirect('role-detail', pk=pk)
    existing = {g.permission_id: g for g in role.grants.all()}
    return render(request, 'role.html', {'role': role, 'matrix': [(p, existing.get(p.pk)) for p in permissions], 'scopes': ['none', 'self', 'branch', 'global'], 'page': 'roles'})

@access('settings.members.manage', 'C')
def member_create(request):
    if not grants(request.membership, 'settings.members.manage', 'C').filter(scope='global').exists():
        raise PermissionDenied('Assigning company membership requires a global company-administration grant.')
    form = forms.MemberForm(request.POST or None, member=request.membership)
    if request.method == 'POST' and form.is_valid():
        with transaction.atomic():
            email = form.cleaned_data['email'].lower()
            users = list(get_user_model().objects.filter(email__iexact=email)[:2])
            if len(users) > 1: form.add_error('email', 'This email has ambiguous accounts. Contact the operator.')
            else:
                user = users[0] if users else get_user_model().objects.create_user(username='u_' + hashlib.sha256(email.encode()).hexdigest()[:40], email=email, first_name=form.cleaned_data['name'])
                existing = Membership.objects.filter(user=user, tenant=request.membership.tenant).first()
                if existing and not grants(request.membership, 'settings.members.manage', 'U').filter(scope='global').exists():
                    raise PermissionDenied('Updating membership requires the company user-update permission.')
                member, _ = Membership.objects.get_or_create(user=user, tenant=request.membership.tenant)
                member.branch = form.cleaned_data['branch']; member.active = True; member.save()
                member.roles.set(form.cleaned_data['roles'])
                services.audit(request.membership, 'membership.assigned', member, email)
                messages.success(request, 'Google email provisioned. The user can now sign in.'); return redirect('roles')
    return render(request, 'form.html', {'form': form, 'title': 'Assign a user to this company', 'page': 'roles', 'back': 'roles'})

def health(request): return HttpResponse('ok', content_type='text/plain')
