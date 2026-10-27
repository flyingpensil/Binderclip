from datetime import timedelta
from decimal import Decimal as D
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import IntegrityError, transaction
from django.test import TestCase, override_settings
from django.utils import timezone
from erp.bootstrap import bootstrap
from erp.models import Customer, Supplier, Job, CostSheetItem, JobSupplierInvoice, CustomerInvoice, JournalEntry, Receipt, Grant
from erp import services as s

@override_settings(SECURE_SSL_REDIRECT=False)
class FinanceTests(TestCase):
    def setUp(self):
        self.member = bootstrap('Test Logistics', 'admin@example.com')
        self.a = s.attrs(self.member)
        self.customer = Customer.objects.create(**self.a, code='C1', name='Customer', currency='AED')
        self.supplier = Supplier.objects.create(**self.a, code='S1', name='Supplier', service_type='Ocean Line')
        self.job = s.create_job(self.member, Job(number='J1', customer=self.customer, pol='Shanghai', pod='Dubai'))
        self.buy = s.add_line(self.member, self.job.cost_sheet.id, CostSheetItem(side='BUY', service='Freight', supplier=self.supplier, quantity=D(2), unit_rate=D(500)))
        self.sell = s.add_line(self.member, self.job.cost_sheet.id, CostSheetItem(side='SELL', service='Freight', quantity=D(2), unit_rate=D(800), tax_rate=D(5)))

    def bill(self, quantity='2', rate='500', fx='1', currency='AED'):
        return JobSupplierInvoice(cost_item=self.buy, supplier=self.supplier, number='B1', quantity=D(quantity), unit_rate=D(rate), currency=currency, fx_rate=D(fx), due_date=timezone.localdate()+timedelta(days=30))

    def ready(self):
        s.book_job(self.member, self.job.cost_sheet.id)
        s.match_bill(self.member, self.job.cost_sheet.id, self.bill())
        s.approve_sheet(self.member, self.job.cost_sheet.id)
        return s.generate_invoice(self.member, [str(self.job.cost_sheet.id)])

    def assertBalanced(self):
        for entry in JournalEntry.objects.all():
            lines = list(entry.lines.all())
            self.assertGreaterEqual(len(lines), 2)
            self.assertEqual(sum(l.debit for l in lines), sum(l.credit for l in lines))

    def test_full_lifecycle_and_exact_posting(self):
        invoice = self.ready()
        self.assertEqual(invoice.total, D('1680'))
        self.assertEqual(JournalEntry.objects.count(), 2)  # draft invoice posts nothing
        s.transition_invoice(self.member, invoice.id, 'approve')
        s.transition_invoice(self.member, invoice.id, 'issue')
        s.receive_payment(self.member, invoice.id, Receipt(reference='R1', amount=D(600)))
        invoice.refresh_from_db(); self.assertEqual(invoice.status, 'Partially Paid'); self.assertEqual(invoice.balance, D(1080))
        s.receive_payment(self.member, invoice.id, Receipt(reference='R2', amount=D(1080)))
        invoice.refresh_from_db(); self.assertEqual(invoice.status, 'Paid')
        s.lock_sheet(self.member, self.job.cost_sheet.id)
        self.job.cost_sheet.refresh_from_db(); self.assertIsNotNone(self.job.cost_sheet.locked_at)
        self.assertBalanced()

    def test_duplicate_booking_rolls_back(self):
        s.book_job(self.member, self.job.cost_sheet.id)
        with self.assertRaises(ValidationError): s.book_job(self.member, self.job.cost_sheet.id)
        self.assertEqual(JournalEntry.objects.count(), 1)

    def test_variance_requires_supervisor_reason(self):
        s.book_job(self.member, self.job.cost_sheet.id)
        bill = s.match_bill(self.member, self.job.cost_sheet.id, self.bill(rate='600'))
        self.assertEqual(bill.status, 'Pending'); self.assertEqual(bill.variance, D(200))
        self.assertEqual(JournalEntry.objects.count(), 1)
        with self.assertRaises(ValidationError): s.approve_sheet(self.member, self.job.cost_sheet.id)
        with self.assertRaises(ValidationError): s.approve_variance(self.member, bill.id, ' ')
        s.approve_variance(self.member, bill.id, 'Carrier surcharge confirmed')
        bill.refresh_from_db(); self.assertEqual(bill.status, 'Matched')
        self.assertEqual(bill.approved_by, self.member.user)
        self.assertEqual(s.financials(self.job.cost_sheet)['margin'], D(400))
        self.assertBalanced()

    def test_quantity_and_price_variances_cannot_offset(self):
        s.book_job(self.member, self.job.cost_sheet.id)
        bill = s.match_bill(self.member, self.job.cost_sheet.id, self.bill(quantity='4', rate='250'))
        self.assertEqual(bill.variance, 0); self.assertEqual(bill.status, 'Pending')

    def test_within_tolerance_posts_actual_cost(self):
        s.book_job(self.member, self.job.cost_sheet.id)
        bill = s.match_bill(self.member, self.job.cost_sheet.id, self.bill(rate='510'))
        self.assertEqual(bill.status, 'Matched'); self.assertEqual(s.financials(self.job.cost_sheet)['actual'], D(1020))
        self.assertBalanced()

    def test_base_currency_fx_must_be_one(self):
        s.book_job(self.member, self.job.cost_sheet.id)
        with self.assertRaises(ValidationError): s.match_bill(self.member, self.job.cost_sheet.id, self.bill(fx='3.67'))

    def test_invoice_generation_is_once_per_charge(self):
        invoice = self.ready()
        with self.assertRaises(ValidationError): s.generate_invoice(self.member, [str(self.job.cost_sheet.id)])
        self.assertEqual(CustomerInvoice.objects.count(), 1)
        self.assertEqual(invoice.items.count(), 1)

    def test_invoice_needs_approval_and_cannot_issue_twice(self):
        invoice = self.ready()
        with self.assertRaises(ValidationError): s.transition_invoice(self.member, invoice.id, 'issue')
        s.transition_invoice(self.member, invoice.id, 'approve'); s.transition_invoice(self.member, invoice.id, 'issue')
        with self.assertRaises(ValidationError): s.transition_invoice(self.member, invoice.id, 'issue')
        self.assertEqual(JournalEntry.objects.filter(source_key=f'invoice:{invoice.id}').count(), 1)

    def test_no_overpayment_or_negative_payment(self):
        invoice = self.ready(); s.transition_invoice(self.member, invoice.id, 'approve'); s.transition_invoice(self.member, invoice.id, 'issue')
        for amount in ['-1', '0', '1680.01']:
            with self.assertRaises(ValidationError): s.receive_payment(self.member, invoice.id, Receipt(reference='bad', amount=D(amount)))
        self.assertEqual(Receipt.objects.count(), 0)

    def test_duplicate_receipt_does_not_double_pay(self):
        invoice = self.ready(); s.transition_invoice(self.member, invoice.id, 'approve'); s.transition_invoice(self.member, invoice.id, 'issue')
        s.receive_payment(self.member, invoice.id, Receipt(reference='once', amount=D(100)))
        with self.assertRaises(ValidationError): s.receive_payment(self.member, invoice.id, Receipt(reference='once', amount=D(100)))
        invoice.refresh_from_db(); self.assertEqual(invoice.amount_paid, D(100))

    def test_cannot_change_estimates_after_booking_or_lock(self):
        invoice = self.ready()
        with self.assertRaises(ValidationError): s.add_line(self.member, self.job.cost_sheet.id, CostSheetItem(side='SELL', service='Extra', quantity=1, unit_rate=1))
        with self.assertRaises(ValidationError): s.lock_sheet(self.member, self.job.cost_sheet.id)
        s.transition_invoice(self.member, invoice.id, 'approve'); s.transition_invoice(self.member, invoice.id, 'issue'); s.lock_sheet(self.member, self.job.cost_sheet.id)
        with self.assertRaises(ValidationError): s.approve_sheet(self.member, self.job.cost_sheet.id)

    def test_unlock_requires_process_grant(self):
        invoice = self.ready(); s.transition_invoice(self.member, invoice.id, 'approve'); s.transition_invoice(self.member, invoice.id, 'issue'); s.lock_sheet(self.member, self.job.cost_sheet.id)
        Grant.objects.filter(role__membership=self.member, permission__process='unlock').update(scope='none')
        with self.assertRaises(PermissionDenied): s.unlock_sheet(self.member, self.job.cost_sheet.id, 'Review')

    def test_supplier_and_cost_item_must_match(self):
        other = Supplier.objects.create(**self.a, code='S2', name='Another', service_type='Trucker')
        s.book_job(self.member, self.job.cost_sheet.id); bill = self.bill(); bill.supplier = other
        with self.assertRaises(ValidationError): s.match_bill(self.member, self.job.cost_sheet.id, bill)

    def test_cross_tenant_customer_rejected(self):
        other = bootstrap('Other company', 'other@example.com')
        with self.assertRaises(ValidationError): s.create_job(other, Job(number='J2', customer=self.customer, pol='A', pod='B'))

    def test_consolidation_rejects_mixed_customers(self):
        self.ready()
        other = Customer.objects.create(**self.a, code='C2', name='Other customer')
        job = s.create_job(self.member, Job(number='J2', customer=other, pol='A', pod='B'))
        job.cost_sheet.approved = True; job.cost_sheet.save()
        job.status = 'Booked'; job.save()
        with self.assertRaises(ValidationError): s.generate_invoice(self.member, [str(self.job.cost_sheet.id), str(job.cost_sheet.id)])

    def test_negative_journal_and_unbalanced_journal_rejected(self):
        for lines in [[('1000 Bank', 10, 0), ('1100 Receivables', 0, 9)], [('1000 Bank', -1, 0), ('1100 Receivables', 0, -1)]]:
            with self.assertRaises(ValidationError): s.post(self.member, 'bad', 'Invalid', lines)
        self.assertFalse(JournalEntry.objects.exists())

    def test_invoice_keeps_legal_identity_snapshot(self):
        invoice = self.ready(); self.customer.name = 'Changed name'; self.customer.save()
        invoice.refresh_from_db(); self.assertEqual(invoice.customer_name, 'Customer')

    def test_decimal_rounding(self):
        self.assertEqual(CostSheetItem(quantity=D('.5'), unit_rate=D('1.01')).amount, D('.51'))

    def test_closed_job_needs_locked_cost_sheet(self):
        self.client.force_login(self.member.user)
        self.job.status = 'Delivered'; self.job.save()
        self.client.post(f'/jobs/{self.job.id}/action/status/', {'status': 'Closed'})
        self.job.refresh_from_db(); self.assertEqual(self.job.status, 'Delivered')
