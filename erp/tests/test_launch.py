from contextlib import redirect_stdout
from io import StringIO
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch
from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.exceptions import ImproperlyConfigured
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import SimpleTestCase, TestCase, override_settings
from binderclip.config import app_origin, postgres_database
from erp.bootstrap import bootstrap
from erp.models import Customer, Supplier, Job, CustomerInvoice, Membership, Grant, Role, Tenant
from scripts.build_pages import build, validate_app_url

class DeploymentConfigTests(SimpleTestCase):
    def test_render_database_url_and_encoded_password(self):
        config = postgres_database('postgresql://user:p%40ss%3Aword@internal-host:5432/binderclip')
        self.assertEqual(config['PASSWORD'], 'p@ss:word')
        self.assertEqual(config['HOST'], 'internal-host')
        self.assertEqual(config['OPTIONS']['sslmode'], 'require')

    def test_non_postgres_and_incomplete_urls_fail_closed(self):
        for url in ['sqlite:///db.sqlite3', 'https://user:password@host/db', 'postgres://user@host/', 'postgres://user@host:wrong/db']:
            with self.subTest(url=url), self.assertRaises(ImproperlyConfigured): postgres_database(url)

    def test_app_origin_rejects_insecure_remote_urls_and_credentials(self):
        for url in ['http://app.example.com', 'https://user:secret@example.com', 'https://app.example.com/login/', 'https://app.example.com/?secret=oops']:
            with self.subTest(url=url), self.assertRaises(ImproperlyConfigured): app_origin(url)
        self.assertEqual(app_origin('https://binderclip-client.onrender.com/'), 'https://binderclip-client.onrender.com')
        self.assertEqual(app_origin('http://127.0.0.1:8001', debug=True), 'http://127.0.0.1:8001')

    def test_pages_package_only_contains_public_assets(self):
        with TemporaryDirectory() as temp, patch.dict('os.environ', {'BINDERCLIP_APP_URL': 'https://client.onrender.com'}), redirect_stdout(StringIO()):
            build(temp, config={'enabled': False})
            names = sorted(str(p.relative_to(temp)).replace('\\', '/') for p in Path(temp).rglob('*') if p.is_file())
            self.assertEqual(names, ['.nojekyll', 'deployment.json', 'index.html', 'static/favicon.svg', 'static/portal.css', 'static/portal.js'])
            self.assertEqual(json.loads((Path(temp) / 'deployment.json').read_text())['appUrl'], 'https://client.onrender.com')

    def test_pages_url_cannot_embed_credentials_or_scripts(self):
        for url in ['javascript:alert(1)', 'http://localhost:8001', 'https://user:secret@host.test', 'https://host.test/?token=abc']:
            with self.subTest(url=url), self.assertRaises(ValueError): validate_app_url(url)

@override_settings(DEBUG=True, DEMO_LOGIN=False, INITIAL_ADMIN_EMAIL='inventory.choco@gmail.com', INITIAL_ADMIN_NAME='Admin1', INITIAL_ADMIN_USERNAME='Admin1', INITIAL_COMPANY_NAME='Binderclip', SECURE_SSL_REDIRECT=False,
                   STORAGES={'staticfiles': {'BACKEND': 'django.contrib.staticfiles.storage.StaticFilesStorage'}})
class LiveLaunchTests(TestCase):
    def provision(self, **kwargs): call_command('provision_admin', disable_demo=True, stdout=StringIO(), **kwargs)

    def test_only_admin1_is_active_and_no_sample_transactions_added(self):
        demo = bootstrap('Sample only', 'demo@binderclip.local')
        demo.user.username = 'demo@binderclip.local'; demo.user.save()
        self.provision()
        self.assertEqual(list(get_user_model().objects.filter(is_active=True).values_list('username', 'email')), [('Admin1', 'inventory.choco@gmail.com')])
        self.assertFalse(Membership.objects.get(pk=demo.pk).active)
        user = get_user_model().objects.get(username='Admin1')
        self.assertEqual(user.first_name, 'Admin1'); self.assertFalse(user.has_usable_password())
        for model in [Customer, Supplier, Job, CustomerInvoice]: self.assertEqual(model.objects.count(), 0)
        self.assertEqual(Role.objects.filter(tenant__name='Binderclip').count(), 4)

    def test_redeploy_preserves_existing_account_state_and_roles(self):
        self.provision()
        user = get_user_model().objects.get(username='Admin1')
        user.first_name = 'Changed by owner'; user.save()
        member = Membership.objects.get(user=user)
        grant = Grant.objects.filter(role__membership=member).first(); grant.scope = 'none'; grant.save()
        self.provision()
        user.refresh_from_db(); grant.refresh_from_db()
        self.assertEqual(Tenant.objects.count(), 1)
        self.assertEqual(user.first_name, 'Changed by owner'); self.assertEqual(grant.scope, 'none')

    def test_existing_company_cannot_be_silently_taken_over(self):
        bootstrap('Binderclip', 'someone-else@example.com')
        with self.assertRaises(CommandError): self.provision()
        self.assertFalse(get_user_model().objects.filter(email='inventory.choco@gmail.com').exists())

    def test_google_credentials_both_required_and_demo_disabled(self):
        with override_settings(GOOGLE_CLIENT_ID='id', GOOGLE_CLIENT_SECRET=''):
            response = self.client.get('/login/')
            self.assertNotContains(response, 'Continue with Google')
            self.assertNotContains(response, 'Explore the local demo')
        with override_settings(GOOGLE_CLIENT_ID='id', GOOGLE_CLIENT_SECRET='secret'):
            self.assertContains(self.client.get('/login/'), 'Continue with Google')
        self.assertEqual(self.client.post('/login/demo/').status_code, 403)

    def test_add_client_user_and_enforce_assigned_read_only_role(self):
        self.provision()
        admin = get_user_model().objects.get(username='Admin1'); self.client.force_login(admin)
        role = Role.objects.get(name='Read-only')
        response = self.client.post('/members/new/', {'email': 'client@example.com', 'name': 'Client user', 'branch': 'Dubai', 'roles': [str(role.pk)]})
        self.assertRedirects(response, '/roles/')
        client = get_user_model().objects.get(email='client@example.com')
        self.assertFalse(client.has_usable_password())
        self.assertTrue(Membership.objects.get(user=client).roles.filter(pk=role.pk).exists())
        self.client.force_login(client)
        self.assertEqual(self.client.get('/jobs/').status_code, 200)
        self.assertEqual(self.client.get('/jobs/new/').status_code, 403)
        self.assertEqual(self.client.get('/members/new/').status_code, 403)

    def test_login_readiness_check_returns_no_secrets(self):
        self.provision(); output = StringIO()
        with override_settings(GOOGLE_CLIENT_ID='client-id', GOOGLE_CLIENT_SECRET='super-secret'):
            call_command('check_login', strict=True, stdout=output)
        self.assertNotIn('super-secret', output.getvalue())
        self.assertNotIn('client-id', output.getvalue())
        self.assertIn('Initial administrator membership: ready', output.getvalue())
