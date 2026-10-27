from datetime import timedelta
from decimal import Decimal as D
from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils import timezone
from erp.bootstrap import bootstrap
from erp.models import Customer, Supplier, PriceList, Tariff, Role, Permission, Grant, Job, CostSheetItem, JobSupplierInvoice, Receipt
from erp.services import attrs, create_job, add_line, book_job, match_bill, approve_sheet, generate_invoice, transition_invoice, receive_payment, lock_sheet

class Command(BaseCommand):
    help = 'Create an isolated, realistic local demonstration workspace. Safe to rerun.'
    @transaction.atomic
    def handle(self, *args, **options):
        if not settings.DEBUG: raise CommandError('Demo data is only available with DEBUG=true.')
        if get_user_model().objects.filter(username='demo@binderclip.local').exists():
            self.stdout.write('Demo workspace already exists.'); return
        member = bootstrap('Binderclip Logistics', 'demo@binderclip.local')
        user = member.user; user.username = 'demo@binderclip.local'; user.first_name = 'Amina'; user.save()
        tenant = member.tenant; tenant.trn = '100987654300003'; tenant.address = 'Office 402, JAFZA One\nJebel Ali Free Zone, Dubai, UAE'; tenant.save()
        a = attrs(member); today = timezone.localdate()
        rates = PriceList.objects.create(**a, name='UAE standard tariff · 2026', currency='AED', is_default=True)
        for service, unit, buy, sell in [('Ocean freight', 'container', 6200, 8500), ('Customs clearance', 'declaration', 350, 550), ('Inland trucking', 'trip', 950, 1350), ('Air freight', 'kg', 18, 24)]:
            Tariff.objects.create(**a, price_list=rates, service=service, unit=unit, buy_rate=buy, sell_rate=sell)
        customers = []
        for i, (name, city) in enumerate([('Atlas Retail Group', 'Dubai'), ('Northstar Electronics', 'Abu Dhabi'), ('Meridian Trading LLC', 'Sharjah'), ('Verde Home & Living', 'Dubai'), ('Al Noor Industries', 'Dubai'), ('Summit Auto Parts', 'Ajman')], 1):
            customers.append(Customer.objects.create(**a, code=f'CUS-{i:03}', name=name, city=city, trn=f'10023456{i:07}', contact=['Sarah Ahmed', 'Daniel Chen', 'Omar Khalid'][i % 3], email=f'finance{i}@example.com', billing_address=f'{city}, United Arab Emirates', currency='AED', credit_limit=150000, price_list=rates))
        suppliers = []
        for i, (name, service) in enumerate([('Bluewater Shipping', 'Ocean Line'), ('Skybridge Cargo', 'Air Carrier'), ('Gulf Customs Services', 'Customs Broker'), ('Emirates Road Logistics', 'Trucker')], 1):
            suppliers.append(Supplier.objects.create(**a, code=f'SUP-{i:03}', name=name, service_type=service, contact='Operations desk', email=f'ops{i}@example.com', currency='AED', trn=f'10065432{i:07}'))
        for role_name, apps in [('Operations executive', ['overview', 'customers', 'suppliers', 'jobs', 'costs', 'masters']), ('Finance officer', ['overview', 'customers', 'suppliers', 'jobs', 'costs', 'invoicing', 'reports', 'masters']), ('Branch viewer', ['overview', 'customers', 'suppliers', 'jobs', 'costs', 'invoicing', 'reports', 'masters'])]:
            role = Role.objects.create(**a, name=role_name, description='Branch access with process-specific permissions.')
            for permission in Permission.objects.filter(application__in=apps):
                if role_name == 'Branch viewer' and permission.action != 'R': continue
                if permission.process in ('unlock', 'variance'): continue
                if role_name == 'Operations executive' and permission.process in ('approve', 'lock'): continue
                Grant.objects.create(role=role, permission=permission, scope='branch', can_export=role_name == 'Finance officer')
        movements = [
            ('Shanghai', 'Jebel Ali', 'Ocean', 'COSCO Universe', 6200, 8500, 'In transit'),
            ('Frankfurt', 'Dubai', 'Air', 'LH 630', 7800, 10400, 'Booked'),
            ('Jebel Ali', 'Riyadh', 'Road', 'UAE–KSA express', 2900, 4200, 'Delivered'),
            ('Singapore', 'Jebel Ali', 'Ocean', 'Maersk Elba', 5100, 6900, 'Draft'),
            ('Mumbai', 'Dubai', 'Air', 'EK 501', 4350, 6100, 'In transit'),
            ('Rotterdam', 'Jebel Ali', 'Ocean', 'MSC Isabella', 11400, 15800, 'Delivered'),
            ('Ningbo', 'Jebel Ali', 'Ocean', 'Ever Given', 8500, 11200, 'Closed'),
            ('Dubai', 'Muscat', 'Road', 'GCC linehaul', 1800, 2600, 'Draft'),
        ]
        for i, (pol, pod, mode, vessel, buy, sell, status) in enumerate(movements):
            job = create_job(member, Job(number=f'BC-26-{1048 + i}', customer=customers[i % len(customers)], pol=pol, pod=pod, mode=mode,
                vessel=vessel, voyage=f'V-{180+i}E', master_bl=f'MBL26{i+844109}', client_reference=f'PO-{4500+i}',
                shipper='Global export partners', consignee=customers[i % len(customers)].name,
                commodity='General cargo · commercial goods', packages=48+i*6, gross_weight=12400+i*250,
                volume=D('28.5')+i, booking_date=today-timedelta(days=i+2), milestone_date=today+timedelta(days=4+i)))
            service = f'{mode} freight'; supplier = suppliers[0 if mode == 'Ocean' else 1 if mode == 'Air' else 3]
            line = add_line(member, job.cost_sheet.id, CostSheetItem(side='BUY', service=service, supplier=supplier, quantity=1, unit_rate=buy, currency='AED', fx_rate=1))
            add_line(member, job.cost_sheet.id, CostSheetItem(side='SELL', service=service, quantity=1, unit_rate=sell, currency='AED', fx_rate=1, tax_rate=5))
            if status == 'Draft': continue
            book_job(member, job.cost_sheet.id)
            if i in (0, 2, 5, 6):
                match_bill(member, job.cost_sheet.id, JobSupplierInvoice(cost_item=line, supplier=supplier, number=f'BW-2026-{820+i}', due_date=today+timedelta(days=30), quantity=1, unit_rate=buy, currency='AED', fx_rate=1))
                approve_sheet(member, job.cost_sheet.id)
                invoice = generate_invoice(member, [str(job.cost_sheet.id)])
                transition_invoice(member, invoice.id, 'approve'); transition_invoice(member, invoice.id, 'issue')
                if i == 2: receive_payment(member, invoice.id, Receipt(reference='RCPT-DEMO-001', amount=1500))
                if i == 6:
                    receive_payment(member, invoice.id, Receipt(reference='RCPT-DEMO-002', amount=invoice.total))
                    lock_sheet(member, job.cost_sheet.id)
            if i == 4:
                match_bill(member, job.cost_sheet.id, JobSupplierInvoice(cost_item=line, supplier=supplier, number='SKY-9844', due_date=today+timedelta(days=20), quantity=1, unit_rate=4900, currency='AED', fx_rate=1))
            job.refresh_from_db(); job.status = status
            if status in ('Delivered', 'Closed'): job.delivery_date = today-timedelta(days=1); job.pod_reference = f'POD-{job.number}-SIGNED'
            job.save()
        self.stdout.write(self.style.SUCCESS('Demo ready: 8 jobs, 6 customers, 4 suppliers, 4 issued invoices, 1 variance to review.'))
