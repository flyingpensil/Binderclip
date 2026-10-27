from functools import wraps
from django.core.exceptions import PermissionDenied
from django.db.models import Q
from django.shortcuts import redirect
from .models import Grant, Membership

# Application -> Window -> Process -> Action. Report scope belongs to each grant.
CATALOG = {
    'overview.dashboard.view': 'R',
    'customers.list.manage': 'CRU', 'customers.ledger.view': 'RX',
    'suppliers.list.manage': 'CRU', 'suppliers.ledger.view': 'RX',
    'jobs.list.manage': 'CRU', 'jobs.detail.status': 'U',
    'costs.detail.manage': 'CR', 'costs.detail.approve': 'U',
    'costs.detail.book': 'U', 'costs.detail.match': 'C',
    'costs.detail.variance': 'U', 'costs.detail.lock': 'U', 'costs.detail.unlock': 'U',
    'invoicing.list.manage': 'R', 'invoicing.detail.generate': 'C',
    'invoicing.detail.approve': 'U', 'invoicing.detail.issue': 'U',
    'invoicing.detail.receipt': 'C', 'invoicing.detail.print': 'X',
    'masters.rates.manage': 'CRU', 'settings.roles.manage': 'CRUD',
    'settings.members.manage': 'CRU', 'reports.journal.view': 'RX',
}

class TenantMiddleware:
    def __init__(self, get_response): self.get_response = get_response
    def __call__(self, request):
        request.membership = None
        if request.user.is_authenticated:
            memberships = Membership.objects.filter(user=request.user, active=True).select_related('tenant')
            selected = request.session.get('tenant_id')
            request.membership = memberships.filter(tenant_id=selected).first() if selected else memberships.order_by('id').first()
            if request.membership:
                request.session['tenant_id'] = str(request.membership.tenant_id)
        return self.get_response(request)

def grants(member, path, action):
    if not member or not member.active: return Grant.objects.none()
    app, window, process = path.split('.')
    qs = Grant.objects.filter(role__membership=member, role__tenant=member.tenant,
                              permission__application=app, permission__window=window,
                              permission__process=process, permission__action=action).exclude(scope='none')
    return qs.filter(can_export=True) if action == 'X' else qs

def scope_filter(member, path, action='R'):
    condition = Q(pk__in=[])
    for grant in grants(member, path, action):
        if grant.scope == 'global': return Q(tenant=member.tenant)
        if grant.scope == 'branch': condition |= Q(branch=member.branch)
        if grant.scope == 'self': condition |= Q(created_by=member.user)
    return Q(tenant=member.tenant) & condition

def scoped(model, member, path, action='R'):
    return model.objects.filter(scope_filter(member, path, action))

def scoped_memberships(member):
    condition = Q(pk__in=[])
    for grant in grants(member, 'settings.members.manage', 'R'):
        if grant.scope == 'global': return Membership.objects.filter(tenant=member.tenant)
        if grant.scope == 'branch': condition |= Q(branch=member.branch)
        if grant.scope == 'self': condition |= Q(user=member.user)
    return Membership.objects.filter(tenant=member.tenant).filter(condition)

def require(member, path, action, obj=None):
    if not grants(member, path, action).exists(): raise PermissionDenied('Your role does not allow this action.')
    if obj is not None and not scoped(type(obj), member, path, action).filter(pk=obj.pk).exists():
        raise PermissionDenied('This record is outside your permitted company or report scope.')

def access(path, action='R'):
    def decorator(view):
        @wraps(view)
        def wrapped(request, *args, **kwargs):
            if not request.user.is_authenticated: return redirect('login')
            require(request.membership, path, action)
            return view(request, *args, **kwargs)
        return wrapped
    return decorator

def navigation(request):
    entries = [('Overview', 'dashboard', 'overview.dashboard.view', '◈'),
               ('Jobs', 'jobs', 'jobs.list.manage', '▦'),
               ('Customers', 'customers', 'customers.list.manage', '◎'),
               ('Suppliers', 'suppliers', 'suppliers.list.manage', '◇'),
               ('Invoices', 'invoices', 'invoicing.list.manage', '▤'),
               ('Rate cards', 'rates', 'masters.rates.manage', '▧'),
               ('General ledger', 'journal', 'reports.journal.view', '≡'),
               ('Users & access', 'roles', 'settings.roles.manage', '⚙')]
    member = getattr(request, 'membership', None)
    return {'nav_items': [(label, url, icon) for label, url, path, icon in entries if grants(member, path, 'R').exists()],
            'active_company': member.tenant if member else None,
            'company_choices': list(Membership.objects.filter(user=request.user, active=True).select_related('tenant')) if request.user.is_authenticated else []}
