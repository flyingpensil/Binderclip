from django.core.management import call_command
from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings
from erp.models import Job, Customer, Supplier, PriceList, CustomerInvoice, Role

@override_settings(DEBUG=True, SECURE_SSL_REDIRECT=False, STORAGES={'staticfiles': {'BACKEND': 'django.contrib.staticfiles.storage.StaticFilesStorage'}})
class ScreenTests(TestCase):
    @classmethod
    def setUpTestData(cls): call_command('seed_demo', verbosity=0)
    def setUp(self): self.client.force_login(get_user_model().objects.get(username='demo@binderclip.local'))
    def test_all_workspace_screens_render(self):
        job = Job.objects.filter(status='Draft').first(); invoice = CustomerInvoice.objects.first()
        paths = ['/', '/jobs/', '/customers/', '/suppliers/', '/invoices/', '/rates/', '/journal/', '/roles/', '/roles/new/', '/members/new/',
                 '/jobs/new/', '/customers/new/', '/suppliers/new/', '/rates/new/',
                 f'/jobs/{job.id}/', f'/jobs/{job.id}/edit/', f'/jobs/{job.id}/line/', f'/jobs/{job.id}/bill/',
                 f'/invoices/{invoice.id}/', f'/invoices/{invoice.id}/print/', f'/invoices/{invoice.id}/receipt/',
                 f'/ledger/customers/{Customer.objects.first().id}/', f'/ledger/suppliers/{Supplier.objects.first().id}/',
                 f'/rates/{PriceList.objects.first().id}/', f'/roles/{Role.objects.first().id}/']
        for path in paths:
            with self.subTest(path=path): self.assertEqual(self.client.get(path).status_code, 200)
    def test_filter_and_csv_endpoints(self):
        self.assertEqual(self.client.get('/jobs/?q=Shanghai&status=In+transit').status_code, 200)
        response = self.client.get('/journal/?export=csv')
        self.assertEqual(response.status_code, 200); self.assertIn('text/csv', response['Content-Type'])
    def test_demo_seed_is_idempotent(self):
        call_command('seed_demo', verbosity=0)
        self.assertEqual(Job.objects.count(), 8)
