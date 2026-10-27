import hashlib
from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError
from .models import Tenant, Membership, Role, Permission, Grant
from .security import CATALOG

def permission_catalog():
    for path, actions in CATALOG.items():
        application, window, process = path.split('.')
        for action in actions:
            Permission.objects.get_or_create(application=application, window=window, process=process, action=action)

def bootstrap(name, email, currency='AED', branch='Dubai'):
    permission_catalog()
    users = list(get_user_model().objects.filter(email__iexact=email)[:2])
    if len(users) > 1: raise ValidationError('Ambiguous email: more than one account exists.')
    user = users[0] if users else get_user_model().objects.create_user(username='u_' + hashlib.sha256(email.lower().encode()).hexdigest()[:40], email=email.lower(), first_name=email.split('@')[0].title())
    tenant = Tenant.objects.create(name=name, base_currency=currency)
    member = Membership.objects.create(tenant=tenant, user=user, branch=branch)
    role = Role.objects.create(tenant=tenant, name='Company administrator', description='Full company access, including security administration.', branch=branch, created_by=user)
    for permission in Permission.objects.all(): Grant.objects.create(role=role, permission=permission, scope='global', can_export=True)
    member.roles.add(role)
    return member
