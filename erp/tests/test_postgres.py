from unittest import skipUnless
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from django.core.exceptions import ValidationError
from django.db import close_old_connections, connections
from django.db import connection, transaction, DatabaseError
from django.test import TransactionTestCase
from erp.bootstrap import bootstrap
from erp.models import JournalEntry, JournalLine, Customer, Job, Membership, Supplier, CostSheetItem
from erp.services import attrs, post, create_job, add_line, book_job

@skipUnless(connection.vendor == 'postgresql', 'PostgreSQL integrity and concurrency require the PostgreSQL CI service.')
class PostgresIntegrityTests(TransactionTestCase):
    def setUp(self): self.member = bootstrap('Database controls', 'postgres@example.com')

    def test_unbalanced_direct_insert_fails_at_commit(self):
        with self.assertRaises(DatabaseError), transaction.atomic():
            entry = JournalEntry.objects.create(**attrs(self.member), source_key='invalid', description='Unbalanced')
            JournalLine.objects.bulk_create([JournalLine(entry=entry, account='1000 Bank', debit=10, credit=0)])
        self.assertFalse(JournalEntry.objects.filter(source_key='invalid').exists())

    def test_raw_journal_changes_rejected(self):
        entry = post(self.member, 'valid', 'Posting', [('1000 Bank', 10, 0), ('1100 Receivables', 0, 10)])
        with self.assertRaises(DatabaseError), transaction.atomic():
            JournalEntry.objects.filter(pk=entry.pk).update(description='Tamper')
        with self.assertRaises(DatabaseError), transaction.atomic():
            JournalLine.objects.filter(entry=entry).update(debit=5)

    def test_cannot_append_to_committed_journal(self):
        entry = post(self.member, 'valid', 'Posting', [('1000 Bank', 10, 0), ('1100 Receivables', 0, 10)])
        with self.assertRaises(DatabaseError), transaction.atomic():
            JournalLine.objects.bulk_create([JournalLine(entry=entry, account='1000 Bank', debit=10, credit=0), JournalLine(entry=entry, account='1100 Receivables', debit=0, credit=10)])

    def test_raw_cross_tenant_foreign_key_rejected(self):
        other = bootstrap('Other company', 'other-postgres@example.com')
        customer = Customer.objects.create(**attrs(self.member), code='C', name='Our customer')
        with self.assertRaises(DatabaseError), transaction.atomic():
            Job.objects.create(**attrs(other), number='evil', customer=customer, pol='A', pod='B')

    def test_raw_cross_tenant_role_assignment_rejected(self):
        other = bootstrap('Other company', 'other-postgres@example.com')
        with self.assertRaises(DatabaseError), transaction.atomic(): self.member.roles.add(other.roles.first())

    def test_concurrent_booking_posts_accrual_only_once(self):
        customer = Customer.objects.create(**attrs(self.member), code='C', name='Customer')
        supplier = Supplier.objects.create(**attrs(self.member), code='S', name='Carrier', service_type='Ocean Line')
        job = create_job(self.member, Job(number='CONCURRENT', customer=customer, pol='A', pod='B'))
        add_line(self.member, job.cost_sheet.id, CostSheetItem(side='BUY', service='Freight', supplier=supplier, quantity=1, unit_rate=100))
        add_line(self.member, job.cost_sheet.id, CostSheetItem(side='SELL', service='Freight', quantity=1, unit_rate=150))
        barrier = Barrier(2)
        def worker():
            close_old_connections()
            try:
                member = Membership.objects.select_related('tenant', 'user').get(pk=self.member.pk)
                barrier.wait(timeout=10)
                try:
                    book_job(member, job.cost_sheet.id)
                    return 'posted'
                except ValidationError: return 'rejected'
            finally: connections.close_all()
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: worker(), range(2)))
        self.assertCountEqual(results, ['posted', 'rejected'])
        self.assertEqual(JournalEntry.objects.filter(job=job).count(), 1)
