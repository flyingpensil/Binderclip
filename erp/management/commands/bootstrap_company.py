from django.core.management.base import BaseCommand
from django.core.validators import validate_email
from django.db import transaction
from erp.bootstrap import bootstrap

class Command(BaseCommand):
    help = 'Provision a company and its first Google SSO administrator (no email is sent).'
    def add_arguments(self, parser):
        parser.add_argument('--name', required=True)
        parser.add_argument('--email', required=True)
        parser.add_argument('--currency', default='AED')
        parser.add_argument('--branch', default='Dubai')
    @transaction.atomic
    def handle(self, *args, **options):
        validate_email(options['email'])
        member = bootstrap(options['name'], options['email'], options['currency'], options['branch'])
        member.tenant.full_clean()
        self.stdout.write(self.style.SUCCESS(f'Company provisioned: {member.tenant.name} ({member.tenant_id}). Sign in with {member.user.email}.'))
