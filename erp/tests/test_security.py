from unittest.mock import Mock, patch
from django.contrib.auth import get_user_model
from django.core.exceptions import PermissionDenied
from django.test import TestCase, Client, override_settings
from erp.bootstrap import bootstrap
from erp.models import Customer, Membership, Grant, GoogleIdentity
from erp.services import attrs
from erp.security import scoped, require
from erp.views import safe_csv

@override_settings(SECURE_SSL_REDIRECT=False, STORAGES={'staticfiles': {'BACKEND': 'django.contrib.staticfiles.storage.StaticFilesStorage'}})
class SecurityTests(TestCase):
    def setUp(self):
        self.member = bootstrap('Company A', 'a@example.com')
        self.other = bootstrap('Company B', 'b@example.com')
        self.customer = Customer.objects.create(**attrs(self.member), code='A', name='Visible customer')
        self.hidden = Customer.objects.create(**attrs(self.other), code='B', name='Private other tenant')
        self.client.force_login(self.member.user)

    def test_tenant_isolation_even_global_grants(self):
        response = self.client.get('/customers/')
        self.assertContains(response, 'Visible customer'); self.assertNotContains(response, 'Private other tenant')
        self.assertEqual(self.client.get(f'/customers/{self.hidden.id}/edit/').status_code, 404)
        self.assertEqual(self.client.get(f'/ledger/customers/{self.hidden.id}/').status_code, 404)

    def test_self_scope(self):
        user = get_user_model().objects.create_user(username='colleague')
        Customer.objects.create(tenant=self.member.tenant, created_by=user, branch='Dubai', name='Colleague record', code='AC')
        Grant.objects.filter(role__membership=self.member, permission__application='customers', permission__action='R').update(scope='self')
        self.assertEqual(scoped(Customer, self.member, 'customers.list.manage').count(), 1)

    def test_branch_scope(self):
        Customer.objects.create(tenant=self.member.tenant, branch='Abu Dhabi', name='Other branch', code='AB')
        Grant.objects.filter(role__membership=self.member, permission__application='customers', permission__action='R').update(scope='branch')
        response = self.client.get('/customers/')
        self.assertContains(response, 'Visible customer'); self.assertNotContains(response, 'Other branch')

    def test_process_denied_even_with_read_access(self):
        Grant.objects.filter(role__membership=self.member, permission__application='customers', permission__action='U').update(scope='none')
        self.assertEqual(self.client.get('/customers/').status_code, 200)
        self.assertEqual(self.client.post(f'/customers/{self.customer.id}/edit/', {'name': 'Hack'}).status_code, 403)

    def test_report_view_does_not_imply_export(self):
        Grant.objects.filter(role__membership=self.member, permission__action='X').update(can_export=False)
        self.assertEqual(self.client.get(f'/ledger/customers/{self.customer.id}/').status_code, 200)
        self.assertEqual(self.client.get(f'/ledger/customers/{self.customer.id}/?export=csv').status_code, 403)

    def test_inactive_membership_denies_all(self):
        self.member.active = False; self.member.save()
        self.assertEqual(self.client.get('/customers/').status_code, 403)

    def test_anonymous_redirect_and_post_only_mutations(self):
        self.client.logout()
        self.assertEqual(self.client.get('/jobs/').status_code, 302)
        self.assertEqual(self.client.get('/logout/').status_code, 405)
        self.assertEqual(self.client.get('/login/demo/').status_code, 405)

    def test_csrf_protection(self):
        client = Client(enforce_csrf_checks=True); client.force_login(self.member.user)
        self.assertEqual(client.post('/customers/new/', {'name': 'Bad'}).status_code, 403)

    def test_foreign_key_choices_do_not_leak_other_company(self):
        response = self.client.get('/jobs/new/')
        self.assertContains(response, 'Visible customer'); self.assertNotContains(response, 'Private other tenant')

    def test_company_switch_requires_membership(self):
        self.assertEqual(self.client.post('/company/switch/', {'tenant_id': str(self.other.tenant_id)}).status_code, 403)
        self.assertEqual(self.client.post('/company/switch/', {'tenant_id': 'bad-uuid'}).status_code, 403)

    def test_company_switch_for_authorized_second_company(self):
        Membership.objects.create(user=self.member.user, tenant=self.other.tenant).roles.add(self.other.roles.first())
        self.assertEqual(self.client.post('/company/switch/', {'tenant_id': str(self.other.tenant_id)}).status_code, 302)
        response = self.client.get('/customers/')
        self.assertContains(response, 'Private other tenant'); self.assertNotContains(response, 'Visible customer')

    def test_export_formula_injection_is_neutralized(self):
        for value in ['=HYPERLINK("evil")', '+CMD', '-1+2', '@SUM(1)', ' \t=CMD']:
            self.assertTrue(safe_csv(value).startswith("'"))
        self.assertEqual(safe_csv('Safe name'), 'Safe name')

    def test_google_state_invalid(self):
        self.client.logout()
        self.assertEqual(self.client.get('/auth/google/callback/?state=wrong&code=x').status_code, 403)

    @override_settings(GOOGLE_CLIENT_ID='client', GOOGLE_CLIENT_SECRET='secret')
    @patch('erp.auth.id_token.verify_oauth2_token')
    @patch('erp.auth.requests.post')
    def test_google_verified_invited_identity_binds(self, post, verify):
        self.client.logout(); self.client.get('/auth/google/')
        state = self.client.session['oauth']
        post.return_value = Mock(json=lambda: {'id_token': 'token'})
        verify.return_value = {'sub': 'google-unique-sub', 'email': 'a@example.com', 'email_verified': True, 'nonce': state['nonce']}
        response = self.client.get('/auth/google/callback/', {'state': state['state'], 'code': 'code'})
        self.assertEqual(response.status_code, 302)
        self.assertEqual(GoogleIdentity.objects.get(subject='google-unique-sub').user, self.member.user)

    @override_settings(GOOGLE_CLIENT_ID='client', GOOGLE_CLIENT_SECRET='secret')
    @patch('erp.auth.id_token.verify_oauth2_token')
    @patch('erp.auth.requests.post')
    def test_google_uninvited_user_rejected(self, post, verify):
        self.client.logout(); self.client.get('/auth/google/'); state = self.client.session['oauth']
        post.return_value = Mock(json=lambda: {'id_token': 'token'})
        verify.return_value = {'sub': 'stranger', 'email': 'stranger@example.com', 'email_verified': True, 'nonce': state['nonce']}
        self.assertEqual(self.client.get('/auth/google/callback/', {'state': state['state'], 'code': 'x'}).status_code, 403)
        self.assertFalse(GoogleIdentity.objects.filter(subject='stranger').exists())
