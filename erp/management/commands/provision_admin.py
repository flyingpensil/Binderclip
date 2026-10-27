"""Idempotent initial live-company provisioning. Never inserts sample transactions."""
from django.conf import settings
from django.contrib.auth import get_user_model
from django.contrib.auth.validators import UnicodeUsernameValidator
from django.core.exceptions import ValidationError
from django.core.management.base import BaseCommand, CommandError
from django.core.validators import validate_email
from django.db import transaction
from erp.bootstrap import bootstrap, permission_catalog
from erp.models import Membership, Tenant, Role, Permission, Grant
from erp.services import audit

PRESETS = {
    'Operations': {'overview', 'customers', 'suppliers', 'jobs', 'costs', 'masters'},
    'Finance': {'overview', 'customers', 'suppliers', 'jobs', 'costs', 'invoicing', 'masters', 'reports'},
    'Read-only': {'overview', 'customers', 'suppliers', 'jobs', 'costs', 'invoicing', 'masters', 'reports'},
}

class Command(BaseCommand):
    help = 'Provision the initial Google-only administrator, without sample data or resetting existing access.'
    def add_arguments(self, parser):
        parser.add_argument('--email', default=settings.INITIAL_ADMIN_EMAIL)
        parser.add_argument('--name', default=settings.INITIAL_ADMIN_NAME)
        parser.add_argument('--username', default=settings.INITIAL_ADMIN_USERNAME)
        parser.add_argument('--company', default=settings.INITIAL_COMPANY_NAME)
        parser.add_argument('--disable-demo', action='store_true')

    @transaction.atomic
    def handle(self, *args, **options):
        email = options['email'].strip().lower()
        try:
            validate_email(email)
            UnicodeUsernameValidator()(options['username'])
        except ValidationError as exc: raise CommandError('A valid INITIAL_ADMIN_EMAIL and INITIAL_ADMIN_USERNAME are required.') from exc
        if not options['name'].strip() or not options['company'].strip(): raise CommandError('Administrator and company names are required.')
        permission_catalog()
        User = get_user_model()
        users = list(User.objects.select_for_update().filter(email__iexact=email)[:2])
        if len(users) > 1: raise CommandError('This email matches multiple accounts. Resolve the ambiguity before provisioning.')
        user = users[0] if users else None
        memberships = list(Membership.objects.filter(user=user, tenant__name=options['company']).select_related('tenant', 'user')) if user else []
        if len(memberships) > 1: raise CommandError('Multiple matching companies exist; resolve them before provisioning.')
        if memberships:
            member = memberships[0]
            self.stdout.write('Initial administrator already provisioned; existing account, roles and activation state preserved.')
        else:
            if Tenant.objects.filter(name=options['company']).exists(): raise CommandError('This company already exists. Assign this user through its administrator instead.')
            collision = User.objects.filter(username__iexact=options['username'])
            if user: collision = collision.exclude(pk=user.pk)
            if collision.exists(): raise CommandError('The requested administrator username is already in use.')
            if user and not user.is_active: raise CommandError('The existing account is inactive. Provisioning cannot silently reactivate it.')
            member = bootstrap(options['company'], email)
            user = member.user
            if not users:
                user.username = options['username']; user.first_name = options['name']; user.set_unusable_password()
                user.full_clean(); user.save()
            for name, applications in PRESETS.items():
                role = Role.objects.create(tenant=member.tenant, branch=member.branch, created_by=user,
                                           name=name, description=f'{name} access within the assigned branch.')
                for permission in Permission.objects.filter(application__in=applications):
                    if name == 'Read-only' and permission.action != 'R': continue
                    if permission.process in ('variance', 'unlock'): continue
                    if name == 'Operations' and (permission.process in ('approve', 'lock') or permission.action == 'X'): continue
                    Grant.objects.create(role=role, permission=permission, scope='branch', can_export=name == 'Finance')
            audit(member, 'workspace.provisioned', member.tenant, f'Initial administrator: {email}')
            self.stdout.write(self.style.SUCCESS(f'Provisioned {options["name"]} ({email}) for {member.tenant.name}. Google sign-in only.'))
        if options['disable_demo']:
            demos = User.objects.filter(username='demo@binderclip.local', email='demo@binderclip.local')
            Membership.objects.filter(user__in=demos).update(active=False)
            demos.update(is_active=False)
            self.stdout.write('Local demo access disabled. Historical records retained.')
