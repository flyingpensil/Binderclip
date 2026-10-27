from urllib.parse import urlsplit
from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from erp.models import Membership

class Command(BaseCommand):
    help = 'Print safe Google setup information and validate login readiness without exposing secrets.'
    def add_arguments(self, parser): parser.add_argument('--strict', action='store_true')
    def handle(self, *args, **options):
        callback = settings.GOOGLE_REDIRECT_URI
        parts = urlsplit(callback)
        self.stdout.write(f'Authorized redirect URI: {callback}')
        self.stdout.write(f'Authorized JavaScript origin: {parts.scheme}://{parts.netloc}')
        checks = {
            'Google client ID': bool(settings.GOOGLE_CLIENT_ID),
            'Google client secret': bool(settings.GOOGLE_CLIENT_SECRET),
            'Initial administrator membership': Membership.objects.filter(user__email__iexact=settings.INITIAL_ADMIN_EMAIL, user__is_active=True, active=True).exists(),
            'Demo login disabled': not settings.DEMO_LOGIN,
            'HTTPS callback (or local development)': parts.scheme == 'https' or (settings.DEBUG and parts.hostname in ('localhost', '127.0.0.1')),
        }
        for label, ready in checks.items(): self.stdout.write(f'{label}: {"ready" if ready else "needs configuration"}')
        if options['strict'] and not all(checks.values()): raise CommandError('Login setup is incomplete; resolve the entries above.')
