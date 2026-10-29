"""Run only against a disposable PostgreSQL CI database, never a real Supabase project."""
import os
import json
from pathlib import Path
import unittest
import uuid
import psycopg
from psycopg.types.json import Jsonb

ROOT = Path(__file__).resolve().parents[2]
ADMIN = uuid.UUID('11111111-1111-4111-8111-111111111111')
SESSION = uuid.UUID('22222222-2222-4222-8222-222222222222')

class BackendTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        dsn = os.environ['SUPABASE_TEST_DSN']
        cls.conn = psycopg.connect(dsn, autocommit=True)
        # This role/schema shim models the Supabase API boundary, not Google's token exchange.
        cls.conn.execute('''
          create role anon nologin;create role authenticated nologin;
          create schema auth;
          create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz,banned_until timestamptz);
          create table auth.identities(id uuid primary key default gen_random_uuid(),user_id uuid references auth.users,provider text);
          create table auth.sessions(id uuid primary key,user_id uuid references auth.users,not_after timestamptz);
          create function auth.jwt() returns jsonb language sql stable as $f$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$f$;
          create function auth.uid() returns uuid language sql stable as $f$select nullif(auth.jwt()->>'sub','')::uuid$f$;
          create schema storage;
          create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
          create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,metadata jsonb,unique(bucket_id,name));
          alter table storage.objects enable row level security;
          grant usage on schema storage to authenticated;
          grant select,insert on storage.objects to authenticated;
        ''', prepare=False)
        for file in sorted((ROOT / 'supabase/migrations').glob('*.sql')):
            cls.conn.execute(file.read_text(encoding='utf-8'), prepare=False)
        cls.conn.execute('insert into auth.users values(%s,%s,now(),null)', (ADMIN,'inventory.choco@gmail.com'))
        cls.conn.execute("insert into auth.identities(user_id,provider) values(%s,'google')", (ADMIN,))
        cls.conn.execute('insert into auth.sessions values(%s,%s,null)',(SESSION,ADMIN))
        cls.tenant = cls.conn.execute('select id from binderclip.companies').fetchone()[0]

    @classmethod
    def tearDownClass(cls): cls.conn.close()
    def setUp(self):
        self.conn.execute('begin')
        self.conn.execute("select set_config('request.jwt.claims',%s,true)",(json.dumps({'sub':str(ADMIN),'session_id':str(SESSION)}),))
        self.conn.execute('set local role authenticated')
        self.conn.execute('select public.bc_session()')
    def tearDown(self):
        try:
            if self.conn.info.transaction_status == psycopg.pq.TransactionStatus.INTRANS:
                self.client();self.conn.execute('set constraints all immediate')
        finally:
            self.conn.execute('rollback')
            self.conn.execute('reset role')
    def command(self,action,data=None,tenant=None):
        return self.conn.execute('select public.bc_command(%s,%s,%s)',(tenant or self.tenant,action,Jsonb(data or {}))).fetchone()[0]
    def read(self,kind,id=None,action='R'):
        return self.conn.execute('select public.bc_read(%s,%s,%s,%s,%s)',(self.tenant,kind,id,'',action)).fetchone()[0]
    def workflow(self,action,data=None):
        return self.conn.execute('select public.bc_workflow(%s,%s,%s)',(self.tenant,action,Jsonb(data or {}))).fetchone()[0]
    def workspace(self,kind,id=None,query='',action='R'):
        return self.conn.execute('select public.bc_workspace(%s,%s,%s,%s,%s)',(self.tenant,kind,id,query,action)).fetchone()[0]
    def report(self,kind,action='R'):
        return self.conn.execute('select public.bc_report(%s,%s,current_date,null,null,%s)',(self.tenant,kind,action)).fetchone()[0]
    def costsheet(self,action,data=None):
        return self.conn.execute('select public.bc_costsheet(%s,%s,%s)',(self.tenant,action,Jsonb(data or {}))).fetchone()[0]
    def practical(self,action,data=None):
        return self.conn.execute('select public.bc_practical(%s,%s,%s)',(self.tenant,action,Jsonb(data or {}))).fetchone()[0]
    def rates(self,action='list',data=None):
        return self.conn.execute('select public.bc_rates(%s,%s,%s)',(self.tenant,action,Jsonb(data or {}))).fetchone()[0]
    def owner(self): self.conn.execute('reset role')
    def client(self): self.conn.execute('set local role authenticated')
    def denied(self,fn):
        with self.assertRaises(psycopg.Error), self.conn.transaction(): fn()
    def fixtures(self):
        customer=self.command('master.save',{'kind':'customers','code':'C1','name':'Customer','currency':'AED','data':{'credit_days':'30'}})['id']
        supplier=self.command('master.save',{'kind':'suppliers','code':'S1','name':'Carrier','currency':'AED','data':{}})['id']
        job=self.command('job.save',{'number':'J1','customer_id':customer,'data':{'pol':'Shanghai','pod':'Jebel Ali','mode':'Ocean'}})['id']
        buy=self.command('cost.add',{'job_id':job,'side':'BUY','service':'Freight','supplier_id':supplier,'quantity':'2','unit_rate':'500','currency':'AED','fx_rate':'1'})['id']
        self.command('cost.add',{'job_id':job,'side':'SELL','service':'Freight','quantity':'2','unit_rate':'800','currency':'AED','fx_rate':'1','tax_rate':'5'})
        return customer,supplier,job,buy
    def bill(self,supplier,job,buy,quantity='2',rate='500'):
        return self.command('bill.match',{'job_id':job,'line_id':buy,'supplier_id':supplier,'number':'B1','invoice_date':'2026-10-27','due_date':'2026-11-27','quantity':quantity,'unit_rate':rate,'currency':'AED','fx_rate':'1'})['id']
    def ready(self):
        customer,supplier,job,buy=self.fixtures()
        self.command('job.book',{'id':job});self.bill(supplier,job,buy)
        self.command('cost.approve',{'id':job})
        invoice=self.command('invoice.generate',{'job_ids':[job]})['id']
        return job,invoice
    def issued(self):
        job,invoice=self.ready();self.command('invoice.approve',{'id':invoice});self.command('invoice.issue',{'id':invoice});return job,invoice

    def test_initial_identity_only_and_company_roles(self):
        session=self.conn.execute('select public.bc_session()').fetchone()[0]
        self.assertEqual(session['memberships'][0]['display_name'],'Admin1')
        self.assertEqual(len(self.read('members')),1);self.assertEqual(len(self.read('roles')),4)
        self.assertEqual(self.read('jobs'),[])
        self.assertEqual(self.read('overview')['active_jobs'],'0')

    def test_deferred_journal_check_runs_as_private_trigger_not_browser_role(self):
        _,_,job,purchases=self.practical_fixture()
        self.practical('costsheet.import',{'job_id':job,'invoice_ids':purchases})
        self.practical('costsheet.book_match',{'job_id':job})
        # Reproduce the previous production failure in this disposable transaction.
        self.owner();self.conn.execute('alter function binderclip.balance() security invoker');self.client()
        self.denied(lambda:self.conn.execute('set constraints all immediate'))
        self.owner();self.conn.execute('alter function binderclip.balance() security definer');self.client()
        self.conn.execute('set constraints all immediate')
        self.assertEqual(self.read('job',job)['status'],'Booked')
        self.denied(lambda:self.conn.execute('select * from binderclip.journal_lines'))

    def practical_fixture(self):
        customer=self.command('master.save',{'kind':'customers','name':'Practical customer','currency':'AED','data':{'default_fx_rate':'1','nature_of_business':'Manufacturing','trn':'100000000000001','crn':'CRN-001'}})['id']
        suppliers=[self.command('master.save',{'kind':'suppliers','name':name,'currency':'AED'})['id'] for name in ['Ocean carrier','Customs broker']]
        job=self.command('job.save',{'customer_id':customer,'data':{'pol':'Shanghai','transshipment_port':'Singapore','pod':'Jebel Ali','activity_code':'SEA-I','supplier_ids':suppliers,'client_reference':'PO-100','container_numbers':'MSCU1234567'}})['id']
        purchases=[]
        for idx,supplier in enumerate(suppliers):
            purchases.append(self.practical('purchase.save',{'job_id':job,'supplier_id':supplier,'reference':'VENDOR-'+str(idx),'invoice_date':'2026-10-27','due_date':'2026-11-27','currency':'AED','fx_rate':'1','lines':[{'description':['Ocean freight','Clearance'][idx],'comments':'Source service','unit':'container' if idx==0 else 'shipment','quantity':'2' if idx==0 else '1','unit_rate':'500' if idx==0 else '200','tax_rate':'5'}]})['id'])
        return customer,suppliers,job,purchases

    def test_practical_multi_supplier_to_statement_and_aging(self):
        customer,suppliers,job,purchases=self.practical_fixture()
        self.assertEqual(len(self.practical('purchases',{'job_id':job})),2)
        self.practical('costsheet.import',{'job_id':job,'invoice_ids':purchases})
        self.denied(lambda:self.practical('costsheet.import',{'job_id':job,'invoice_ids':purchases}))
        self.assertEqual(len(self.read('job',job)['lines']),4)
        self.practical('costsheet.book_match',{'job_id':job})
        self.assertTrue(all(p['match_status']=='Matched' for p in self.practical('purchases',{'job_id':job})))
        self.command('cost.approve',{'id':job});invoice=self.command('invoice.generate',{'job_ids':[job]})['id']
        before=self.read('invoice',invoice)
        lines=[{'id':x['id'],'description':x['description'],'comments':'Client agreed','unit':'shipment','quantity':x['quantity'],'unit_rate':'600' if x['quantity']=='2.000' else '300','tax_rate':'5'} for x in before['items']]
        self.practical('invoice.save',{'id':invoice,'lines':lines,'discount':'100','adjustment':'20','reason':'Agreed billing'})
        inv=self.read('invoice',invoice);self.assertEqual(inv['subtotal'],'1420.00');self.assertEqual(inv['tax_total'],'71.00');self.assertEqual(inv['total'],'1491.00')
        self.assertEqual(self.costsheet('detail',{'job_id':job})['figures']['margin'],'220.00')
        self.command('invoice.approve',{'id':invoice});self.command('invoice.issue',{'id':invoice})
        self.command('invoice.receipt',{'id':invoice,'reference':'PRACTICAL-BANK','amount':'491','received_on':'2026-10-28'})
        statement=self.practical('statement',{'customer_id':customer})
        self.assertEqual(statement['totals'][0]['closing'],'1000.00');self.assertEqual(statement['totals'][0]['debit'],'1491.00');self.assertEqual(statement['totals'][0]['credit'],'491.00')
        self.assertEqual(self.practical('customer_aging',{'customer_id':customer})['rows'][0]['outstanding'],'1000.00')
        self.denied(lambda:self.practical('invoice.save',{'id':invoice,'lines':lines,'reason':'Forbidden rewrite'}))
        from decimal import Decimal
        tb=self.report('trial_balance')['rows'];self.assertEqual(sum(Decimal(x['debit']) for x in tb),sum(Decimal(x['credit']) for x in tb))
        self.assertEqual(next(x['balance'] for x in tb if x['account']=='1200 VAT recoverable'),'60.00')
        self.assertEqual(sum(Decimal(b['total']) for b in self.workspace('payables')),Decimal('1260.00'))

    def test_practical_document_duplicate_and_scope_checks(self):
        customer,suppliers,job,purchases=self.practical_fixture()
        self.denied(lambda:self.practical('costsheet.import',{'job_id':job,'invoice_ids':[purchases[0],purchases[0]]}))
        other=self.command('job.save',{'customer_id':customer,'data':{'pol':'Dubai','pod':'Tokyo'}})['id']
        self.denied(lambda:self.practical('costsheet.import',{'job_id':other,'invoice_ids':purchases}))
        self.denied(lambda:self.command('job.save',{'customer_id':customer,'data':{'pol':'Dubai','pod':'Tokyo','supplier_ids':[str(uuid.uuid4())]}}))
        customer_only=self.command('master.save',{'kind':'customers','name':'Currency only','currency':'AED','data':{'default_fx_rate':'2'}})['id']
        self.assertNotIn('default_fx_rate',self.read('customers',customer_only)[0]['data'])
        self.owner();self.conn.execute("update binderclip.grants set scope='none' where path='costs.detail.manage'");self.client()
        self.assertEqual(self.practical('purchases',{'job_id':job}),[])
        self.denied(lambda:self.practical('costsheet.import',{'job_id':job,'invoice_ids':purchases}))

    def test_draft_invoice_mixed_vat_allocation_and_additional_line(self):
        job,invoice=self.ready();original=self.read('invoice',invoice)
        lines=[{**x,'description':x['description'],'unit':'container','comments':'Freight'} for x in original['items']]
        lines.append({'job_id':job,'description':'Exempt service','unit':'shipment','quantity':'1','unit_rate':'100','tax_rate':'0','exemption':'Exempt service documentation'})
        self.practical('invoice.save',{'id':invoice,'lines':lines,'discount':'170','adjustment':'0','reason':'Prepare draft'})
        inv=self.read('invoice',invoice);self.assertEqual(inv['subtotal'],'1530.00');self.assertEqual(inv['tax_total'],'72.00');self.assertEqual(inv['total'],'1602.00')
        self.assertEqual(len(inv['items']),2)
        self.denied(lambda:self.practical('invoice.save',{'id':invoice,'lines':lines,'discount':'1800','reason':'Invalid discount'}))
        self.owner();self.denied(lambda:self.conn.execute('update binderclip.invoice_items set unit_rate=1 where invoice_id=%s',(invoice,)));self.client()

    def test_statement_requires_customer_and_export_permission(self):
        customer,_,_,_=self.practical_fixture()
        self.denied(lambda:self.practical('statement'))
        self.owner();self.conn.execute("update binderclip.grants set can_export=false where path='customers.ledger.view'");self.client()
        self.denied(lambda:self.practical('statement',{'customer_id':customer,'action':'X'}))
        self.assertEqual(self.practical('statement',{'customer_id':customer})['rows'],[])

    def test_invoice_revision_history_does_not_leak_restricted_billing_snapshot(self):
        job,invoice=self.ready()
        self.owner();self.conn.execute("update binderclip.invoices set snapshot=jsonb_set(snapshot,'{customer,data,billing_address}','\"Restricted billing address\"') where id=%s",(invoice,));self.client()
        lines=self.read('invoice',invoice)['items']
        self.practical('invoice.save',{'id':invoice,'lines':lines,'discount':'10','reason':'Revise draft charges'})
        self.owner();self.conn.execute("update binderclip.grants set scope='none' where path in('customers.list.manage','invoicing.list.manage')");self.client()
        self.assertNotIn('Restricted billing address',json.dumps(self.costsheet('detail',{'job_id':job})))

    def test_supplier_document_can_be_corrected_before_booking_only(self):
        _,_,job,purchases=self.practical_fixture()
        self.practical('costsheet.import',{'job_id':job,'invoice_ids':purchases})
        self.practical('purchase.unprepare',{'id':purchases[0],'reason':'Correct vendor amount'})
        self.assertEqual(len(self.read('job',job)['lines']),2)
        self.practical('costsheet.import',{'job_id':job,'invoice_ids':[purchases[0]]})
        self.assertEqual(len(self.read('job',job)['lines']),4)
        self.practical('costsheet.book_match',{'job_id':job})
        self.denied(lambda:self.practical('purchase.unprepare',{'id':purchases[0],'reason':'Cannot rewrite booked costs'}))

    def test_unselected_supplier_documents_block_booking_and_vat_settlement_is_complete(self):
        _,_,job,purchases=self.practical_fixture()
        self.practical('costsheet.import',{'job_id':job,'invoice_ids':[purchases[0]]})
        self.denied(lambda:self.practical('costsheet.book_match',{'job_id':job}))
        self.assertEqual(self.read('job',job)['status'],'Draft');self.assertEqual(self.read('journal'),[])
        self.practical('costsheet.import',{'job_id':job,'invoice_ids':[purchases[1]]});self.practical('costsheet.book_match',{'job_id':job})
        bill=self.workspace('payables')[0]
        self.workflow('supplier.pay',{'id':bill['id'],'reference':'COMPLETE-VAT-PAYMENT','amount':bill['total'],'paid_on':'2026-10-28'})
        self.assertEqual(next(b['paid'] for b in self.workspace('payables') if b['id']==bill['id']),bill['total'])
        self.denied(lambda:self.workflow('supplier.pay',{'id':bill['id'],'reference':'EXCESS','amount':'0.01','paid_on':'2026-10-28'}))

    def test_customer_reports_keep_currencies_separate(self):
        self.rates('save',{'from_currency':'USD','from_amount':'1','to_currency':'AED','to_amount':'3.6725'})
        job,invoice=self.issued();customer=self.read('invoice',invoice)['customer_id']
        supplier=self.read('suppliers')[0]['id']
        foreign=self.command('job.save',{'customer_id':customer,'data':{'pol':'Shanghai','pod':'Dubai'}})['id']
        buy=self.command('cost.add',{'job_id':foreign,'side':'BUY','service':'Freight','supplier_id':supplier,'quantity':'1','unit_rate':'10','currency':'AED','fx_rate':'1'})['id']
        self.command('cost.add',{'job_id':foreign,'side':'SELL','service':'Freight','quantity':'1','unit_rate':'10','currency':'USD','fx_rate':'3.6725','tax_rate':'5'})
        self.command('job.book',{'id':foreign});self.bill(supplier,foreign,buy,'1','10');self.command('cost.approve',{'id':foreign})
        foreign_invoice=self.command('invoice.generate',{'job_ids':[foreign]})['id'];self.command('invoice.approve',{'id':foreign_invoice});self.command('invoice.issue',{'id':foreign_invoice})
        totals={r['currency']:r['closing'] for r in self.practical('statement',{'customer_id':customer})['totals']}
        self.assertEqual(totals,{'AED':'1680.00','USD':'10.50'})
        self.assertEqual(len(self.practical('customer_aging',{'customer_id':customer,'currency':'USD'})['rows']),1)

    def test_shared_currency_pairs_reverse_and_base_cross_rates(self):
        first=self.rates('save',{'from_currency':'AED','from_amount':'1','to_currency':'USD','to_amount':'0.27'})['id']
        self.rates('save',{'from_currency':'OMR','from_amount':'1','to_currency':'AED','to_amount':'9.55'})
        def quote(a,b):return self.rates('quote',{'from_currency':a,'to_currency':b})['rate']
        self.assertEqual(quote('AED','USD'),'0.27000000');self.assertEqual(quote('USD','AED'),'3.70370370');self.assertEqual(quote('OMR','USD'),'2.57850000')
        self.denied(lambda:self.rates('save',{'from_currency':'USD','from_amount':'1','to_currency':'AED','to_amount':'4'}))
        self.denied(lambda:self.rates('save',{'from_currency':'EUR','from_amount':'0','to_currency':'AED','to_amount':'4'}))
        self.denied(lambda:quote('EUR','AED'))
        self.rates('save',{'id':first,'from_currency':'AED','from_amount':'1','to_currency':'USD','to_amount':'0.25'})
        self.assertEqual(quote('USD','AED'),'4.00000000')

    def test_shared_fx_defaults_and_source_document_rates_do_not_reprice(self):
        pair=self.rates('save',{'from_currency':'USD','from_amount':'1','to_currency':'AED','to_amount':'3.7'})['id']
        customer,supplier,job,_=self.fixtures()
        purchase=self.practical('purchase.save',{'job_id':job,'supplier_id':supplier,'reference':'FOREIGN','invoice_date':'2026-10-27','due_date':'2026-11-27','currency':'USD','fx_rate':'999','lines':[{'description':'Carrier','quantity':'1','unit_rate':'100','tax_rate':'0'}]})['id']
        self.assertEqual(self.practical('purchase',{'id':purchase})[0]['fx_rate'],'3.70000000')
        self.rates('save',{'id':pair,'from_currency':'USD','from_amount':'1','to_currency':'AED','to_amount':'3.8'})
        self.practical('costsheet.import',{'job_id':job,'invoice_ids':[purchase]})
        saved=self.practical('purchase',{'id':purchase})[0]['lines'][0]
        imported=next(l for l in self.read('job',job)['lines'] if l['id']==saved['buy_line_id'])
        self.assertEqual(imported['fx_rate'],'3.70000000')
        line=self.command('cost.add',{'job_id':job,'side':'SELL','service':'New FX','quantity':'1','unit_rate':'10','currency':'USD','fx_rate':'999','tax_rate':'5'})['id']
        self.assertEqual(next(l for l in self.read('job',job)['lines'] if l['id']==line)['fx_rate'],'3.80000000')

    def test_idle_activity_expires_server_side_and_cannot_be_revived(self):
        self.conn.execute('select public.bc_activity()')
        self.owner();self.conn.execute("update binderclip.session_activity set last_seen=now()-interval '121 minutes' where session_id=%s",(SESSION,));self.client()
        self.denied(lambda:self.read('customers'))
        self.denied(lambda:self.conn.execute('select public.bc_activity()'))
        self.owner();self.conn.execute("update binderclip.session_activity set last_seen=now()-interval '119 minutes' where session_id=%s",(SESSION,));self.client()
        self.conn.execute('select public.bc_activity()')
        self.assertEqual(self.read('customers'),[])

    def test_statement_opening_and_historical_aging_exclude_later_receipts(self):
        from datetime import timedelta
        job,invoice=self.issued();customer=self.read('invoice',invoice)['customer_id']
        today=self.conn.execute('select current_date').fetchone()[0]
        self.command('invoice.receipt',{'id':invoice,'reference':'AGED-RECEIPT','amount':'500','received_on':str(today-timedelta(days=2))})
        # Trusted CI fixture simulates records posted before this release. Never run
        # these fixture-only trigger settings against a client database.
        self.owner();self.conn.execute("set local session_replication_role='replica'")
        self.conn.execute('update binderclip.invoices set issued_at=now()-interval \'40 days\',invoice_date=current_date-45,due_date=current_date-10 where id=%s',(invoice,))
        self.conn.execute("update binderclip.journals set created_at=now()-interval '40 days' where source=%s",('invoice:'+invoice,))
        self.conn.execute("update binderclip.journals set created_at=now()-interval '2 days' where source like 'receipt:%'")
        self.conn.execute("set local session_replication_role='origin'");self.client()
        previous=self.practical('customer_aging',{'customer_id':customer,'as_of':str(today-timedelta(days=5))})
        self.assertEqual(previous['rows'][0]['outstanding'],'1680.00')
        current=self.practical('customer_aging',{'customer_id':customer})
        self.assertEqual(current['rows'][0]['outstanding'],'1180.00');self.assertEqual(current['rows'][0]['days_overdue'],'10')
        statement=self.practical('statement',{'customer_id':customer,'from':str(today-timedelta(days=5))})
        self.assertEqual(statement['totals'][0]['opening'],'1680.00');self.assertEqual(statement['totals'][0]['closing'],'1180.00')
        self.assertEqual(len(statement['rows']),1);self.assertEqual(statement['rows'][0]['balance'],'1180.00')

    def test_record_tracking_is_server_assigned_and_preserves_creator(self):
        customer=self.command('master.save',{'kind':'customers','name':'Tracked','created_by':str(uuid.uuid4()),'created_at':'1990-01-01','currency':'AED'})['id']
        before=self.read('customers',customer)[0]
        self.assertEqual(before['created_by'],str(ADMIN));self.assertEqual(before['created_by_name'],'Admin1')
        self.assertTrue(before['created_at']);self.assertFalse(before['created_at'].startswith('1990-'))
        self.assertIsNone(before['updated_at'])
        other=uuid.uuid4();session=uuid.uuid4()
        self.owner();self.conn.execute('insert into auth.users values(%s,%s,now(),null)',(other,'editor@example.test'))
        self.conn.execute("insert into auth.identities(user_id,provider) values(%s,'google')",(other,))
        self.conn.execute('insert into auth.sessions values(%s,%s,null)',(session,other))
        member=self.conn.execute("insert into binderclip.members(tenant_id,user_id,email,display_name) values(%s,%s,'editor@example.test','Operations editor') returning id",(self.tenant,other)).fetchone()[0]
        self.conn.execute("insert into binderclip.member_roles(tenant_id,member_id,role_id) select %s,%s,id from binderclip.roles where tenant_id=%s and name='Company administrator'",(self.tenant,member,self.tenant))
        self.conn.execute("select set_config('request.jwt.claims',%s,true)",(json.dumps({'sub':str(other),'session_id':str(session)}),));self.client()
        self.command('master.save',{'id':customer,'kind':'customers','name':'Updated','currency':'AED','created_at':'1990-01-01','updated_by':str(ADMIN)})
        after=self.read('customers',customer)[0]
        self.assertEqual(after['created_at'],before['created_at']);self.assertEqual(after['created_by'],str(ADMIN))
        self.assertEqual(after['updated_by'],str(other));self.assertEqual(after['updated_by_name'],'Operations editor')
        self.assertGreaterEqual(after['updated_at'],before['created_at'])
        self.denied(lambda:self.conn.execute('select binderclip.with_tracking(%s,%s)',(self.tenant,Jsonb(after))))

    def test_tracking_child_entries_and_financial_history(self):
        _,supplier,job,buy=self.fixtures()
        row=self.read('job',job)
        self.assertTrue(all(l['created_by_name']=='Admin1' and l['created_at'] for l in row['lines']))
        self.assertEqual(row['updated_by_name'],'Admin1')
        self.assertEqual(self.costsheet('list')[0]['created_by_name'],'Admin1')
        self.command('job.book',{'id':job});self.bill(supplier,job,buy)
        entries=self.read('journal');self.assertTrue(all(e['created_by_name']=='Admin1' for e in entries))
        self.owner()
        self.denied(lambda:self.conn.execute('update binderclip.journals set updated_at=now()'))
        self.client()

    def test_quote_editor_cannot_change_hidden_buy_lines(self):
        _,quote=self.quote_fixture();source=self.workspace('quote',quote)
        buy=next(l for l in source['lines'] if l['side']=='BUY')
        self.owner();self.conn.execute("update binderclip.grants set scope='none' where path='costs.detail.manage' and action='R'");self.client()
        self.denied(lambda:self.workflow('quote.line',{'id':quote,'line_id':buy['id'],'side':'SELL','service':'Changed hidden cost','quantity':'1','unit_rate':'1','tax_rate':'5'}))
        self.assertTrue(all(l['side']=='SELL' for l in self.workspace('quote',quote)['lines']))

    def test_all_private_tables_and_helpers_reject_direct_browser_access(self):
        self.owner()
        rows=self.conn.execute("select c.relname,c.relrowsecurity,has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE'),has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE') from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='binderclip' and c.relkind='r'").fetchall()
        for name,rls,authenticated,anonymous in rows:
            self.assertTrue(rls,name);self.assertFalse(authenticated,name);self.assertFalse(anonymous,name)
        self.client()
        self.denied(lambda:self.conn.execute('select * from binderclip.masters'))

    def test_all_financial_drilldowns(self):
        job,invoice=self.issued()
        detail=self.read('job',job)
        customer=detail['customer_id']
        supplier=next(line['supplier_id'] for line in detail['lines'] if line['side']=='BUY')
        self.assertEqual(len(self.read('customer_ledger',customer)),1)
        self.assertEqual(len(self.read('supplier_ledger',supplier)),1)
        self.assertEqual(len(self.read('commitments',supplier)),1)
        self.assertEqual(len(self.read('invoice_print',invoice,'X')['items']),1)
        self.assertEqual(self.read('overview')['receivables'],'1680.00')
        self.assertEqual(len(self.read('journal')),3)

    def test_job_labels_do_not_bypass_customer_directory_scope(self):
        customer,_,job,_=self.fixtures()
        self.owner()
        self.conn.execute("update binderclip.masters set data=data||'{\"credit_limit\":\"9999.99\"}'::jsonb where id=%s",(customer,))
        self.conn.execute("update binderclip.grants set scope='none' where path='customers.list.manage'")
        self.client()
        self.assertEqual(self.read('customers'),[])
        label=self.read('job',job)['customer']
        self.assertEqual(label['name'],'Customer')
        self.assertNotIn('data',label)

    def test_self_scope_commitments_and_branch_job_visibility(self):
        _,supplier,job,_=self.fixtures()
        self.owner()
        self.conn.execute("update binderclip.grants set scope='self' where path='suppliers.ledger.view'")
        self.conn.execute("update binderclip.grants set scope='branch' where path='jobs.list.manage'")
        self.client()
        self.assertEqual(len(self.read('commitments',supplier)),1)
        self.assertEqual(len(self.read('jobs')),1)
        self.owner();self.conn.execute("update binderclip.jobs set branch='Other branch' where id=%s",(job,));self.client()
        self.assertEqual(self.read('jobs'),[])
        self.denied(lambda:self.read('job',job))
    def test_full_accounting_lifecycle(self):
        job,invoice=self.issued()
        self.assertEqual(self.read('invoice',invoice)['total'],'1680.00')
        self.command('invoice.receipt',{'id':invoice,'reference':'R1','amount':'600','received_on':'2026-10-27'})
        self.assertEqual(self.read('invoice',invoice)['status'],'Partially Paid')
        self.command('invoice.receipt',{'id':invoice,'reference':'R2','amount':'1080','received_on':'2026-10-27'})
        self.assertEqual(self.read('invoice',invoice)['status'],'Paid')
        self.command('cost.lock',{'id':job});self.command('job.status',{'id':job,'status':'In transit'});self.command('job.status',{'id':job,'status':'Delivered'});self.command('job.status',{'id':job,'status':'Closed'})
        self.assertEqual(self.read('job',job)['status'],'Closed')
        for entry in self.read('journal'):
            from decimal import Decimal
            self.assertEqual(sum(Decimal(x['debit']) for x in entry['lines']),sum(Decimal(x['credit']) for x in entry['lines']))
        self.owner();self.conn.execute('set constraints all immediate')
    def test_duplicate_booking_and_billing_rejected(self):
        _,supplier,job,buy=self.fixtures();self.command('job.book',{'id':job})
        self.denied(lambda:self.command('job.book',{'id':job}))
        self.bill(supplier,job,buy);self.denied(lambda:self.bill(supplier,job,buy))
    def test_offsetting_quantity_and_price_variance_requires_approval(self):
        _,supplier,job,buy=self.fixtures();self.command('job.book',{'id':job})
        bill=self.bill(supplier,job,buy,quantity='4',rate='250')
        self.assertEqual(self.read('job',job)['bills'][0]['status'],'Pending')
        self.denied(lambda:self.command('cost.approve',{'id':job}))
        self.denied(lambda:self.command('bill.approve',{'id':bill,'reason':''}))
        self.command('bill.approve',{'id':bill,'reason':'Verified operational estimate correction'})
        self.assertEqual(self.read('job',job)['bills'][0]['status'],'Matched')
    def test_no_double_invoicing_or_double_issue(self):
        job,invoice=self.issued()
        self.denied(lambda:self.command('invoice.generate',{'job_ids':[job]}))
        self.denied(lambda:self.command('invoice.issue',{'id':invoice}))
    def test_no_overpayment_negative_payment_or_duplicate_receipt(self):
        _,invoice=self.issued()
        for amount in ('0','-1','1680.01'):
            self.denied(lambda:self.command('invoice.receipt',{'id':invoice,'reference':'bad','amount':amount,'received_on':'2026-10-27'}))
        self.command('invoice.receipt',{'id':invoice,'reference':'R1','amount':'100','received_on':'2026-10-27'})
        self.denied(lambda:self.command('invoice.receipt',{'id':invoice,'reference':'R1','amount':'100','received_on':'2026-10-27'}))
        self.assertEqual(self.read('invoice',invoice)['paid'],'100.00')
    def test_locked_job_cannot_be_modified_and_close_requires_lock(self):
        job,invoice=self.issued()
        self.command('job.status',{'id':job,'status':'In transit'});self.command('job.status',{'id':job,'status':'Delivered'})
        self.denied(lambda:self.command('job.status',{'id':job,'status':'Closed'}))
        self.command('cost.lock',{'id':job})
        self.denied(lambda:self.command('cost.add',{'job_id':job}))
        self.denied(lambda:self.command('cost.unlock',{'id':job,'reason':''}))
        self.command('cost.unlock',{'id':job,'reason':'Supervisor review'})
    def test_uninvited_google_account_cannot_access_company(self):
        self.owner();uid=uuid.uuid4();sid=uuid.uuid4()
        self.conn.execute('insert into auth.users values(%s,%s,now(),null)',(uid,'stranger@example.com'))
        self.conn.execute("insert into auth.identities(user_id,provider) values(%s,'google')",(uid,));self.conn.execute('insert into auth.sessions values(%s,%s,null)',(sid,uid))
        self.conn.execute("select set_config('request.jwt.claims',%s,true)",(__import__('json').dumps({'sub':str(uid),'session_id':str(sid)}),));self.client()
        self.denied(lambda:self.conn.execute('select public.bc_session()'))
        self.denied(lambda:self.read('jobs'))
    def test_anon_and_direct_table_access_denied(self):
        self.denied(lambda:self.conn.execute('select * from binderclip.members'))
        self.owner();self.conn.execute('set local role anon')
        self.denied(lambda:self.conn.execute('select public.bc_session()'))
        self.denied(lambda:self.conn.execute('select public.bc_command(%s,%s,%s)',(self.tenant,'company.save',Jsonb({}))))
    def test_revoked_session_and_membership_take_effect(self):
        self.owner();self.conn.execute('delete from auth.sessions where id=%s',(SESSION,));self.client()
        self.denied(lambda:self.read('jobs'))
    def test_cross_tenant_object_rejected(self):
        _,_,job,_=self.fixtures()
        self.denied(lambda:self.command('job.book',{'id':job},tenant=uuid.uuid4()))
    def test_member_creation_and_read_only_process_permissions(self):
        roles=self.read('roles');role=next(x for x in roles if x['name']=='Read-only')
        result=self.command('member.save',{'email':'client@example.com','display_name':'Client','branch':'Dubai','role_ids':[role['id']]})
        self.assertIn('id',result)
        self.denied(lambda:self.command('member.save',{'id':self.read('members')[0]['id'],'email':'inventory.choco@gmail.com','display_name':'No','role_ids':[role['id']]}))
        self.owner();uid=uuid.uuid4();sid=uuid.uuid4()
        self.conn.execute('insert into auth.users values(%s,%s,now(),null)',(uid,'client@example.com'));self.conn.execute("insert into auth.identities(user_id,provider) values(%s,'google')",(uid,));self.conn.execute('insert into auth.sessions values(%s,%s,null)',(sid,uid))
        self.conn.execute("select set_config('request.jwt.claims',%s,true)",(__import__('json').dumps({'sub':str(uid),'session_id':str(sid)}),));self.client();self.conn.execute('select public.bc_session()')
        self.assertEqual(self.read('jobs'),[])
        self.denied(lambda:self.command('job.save',{}));self.denied(lambda:self.read('members'))
    def test_report_read_does_not_allow_export(self):
        self.fixtures();self.owner();self.conn.execute("update binderclip.grants set can_export=false where action='X'");self.client()
        self.assertEqual(self.read('journal'),[])
        self.assertEqual(self.read('journal',action='X'),[])
        self.denied(lambda:self.read('invoice_print',uuid.uuid4()))
    def test_raw_journal_mutation_or_unbalanced_insert_rejected(self):
        self.issued();self.owner()
        self.denied(lambda:self.conn.execute("update binderclip.journals set description='tamper'"))
        def unbalanced():
            e=self.conn.execute("insert into binderclip.journals(tenant_id,source,description,branch,created_by) values(%s,'invalid','invalid','Dubai',%s) returning id",(self.tenant,ADMIN)).fetchone()[0]
            self.conn.execute("insert into binderclip.journal_lines(entry_id,account,debit) values(%s,'1000 Bank',10)",(e,));self.conn.execute('set constraints all immediate')
        self.denied(unbalanced)

    def quote_fixture(self):
        customer,supplier,_,_=self.fixtures()
        enquiry=self.workflow('enquiry.save',{'customer_id':customer,'subject':'Ocean import','data':{'pol':'Shanghai','pod':'Jebel Ali','mode':'Ocean'}})['id']
        quote=self.workflow('quote.save',{'customer_id':customer,'enquiry_id':enquiry,'currency':'AED','fx_rate':'1','valid_until':'2099-01-01','data':{'pol':'Shanghai','pod':'Jebel Ali','mode':'Ocean'}})['id']
        for side,rate in [('BUY','500'),('SELL','800')]:
            self.workflow('quote.line',{'id':quote,'side':side,'service':'Freight','supplier_id':supplier if side=='BUY' else None,'quantity':'2','unit_rate':rate,'tax_rate':'5'})
        return enquiry,quote

    def test_enquiry_quote_to_job_exactly_once_with_cost_copy(self):
        enquiry,quote=self.quote_fixture()
        self.workflow('quote.approve',{'id':quote})
        self.denied(lambda:self.workflow('quote.line',{'id':quote}))
        job=self.workflow('quote.convert',{'id':quote,'job_number':'FROM-QUOTE'})['id']
        self.assertEqual(self.read('job',job)['figures']['margin'],'600.00')
        self.assertEqual(self.workspace('enquiries',enquiry)[0]['status'],'Confirmed')
        self.assertEqual(self.workspace('quote',quote)['job_id'],job)
        self.denied(lambda:self.workflow('quote.convert',{'id':quote,'job_number':'DUPLICATE'}))
        self.assertEqual(self.workspace('quote_print',quote)['lines'][0]['side'],'SELL')
        self.assertEqual(len(self.workspace('quote_print',quote)['lines']),1)

    def test_quote_expiry_and_conversion_permission(self):
        _,quote=self.quote_fixture()
        self.owner();self.conn.execute("update binderclip.quotations set valid_until='2000-01-01' where id=%s",(quote,));self.client()
        self.denied(lambda:self.workflow('quote.approve',{'id':quote}))
        self.owner();self.conn.execute("update binderclip.quotations set valid_until='2099-01-01' where id=%s",(quote,));self.client()
        self.workflow('quote.approve',{'id':quote})
        self.owner();self.conn.execute("update binderclip.grants set scope='none' where path='jobs.list.manage' and action='C'");self.client()
        self.denied(lambda:self.workflow('quote.convert',{'id':quote,'job_number':'DENIED'}))
        self.assertEqual(self.workspace('quote',quote)['status'],'Approved')

    def test_draft_quote_line_can_be_corrected_but_approval_freezes_it(self):
        _,quote=self.quote_fixture()
        line=next(l for l in self.workspace('quote',quote)['lines'] if l['side']=='SELL')
        payload={'id':quote,'line_id':line['id'],'side':'SELL','service':'Corrected freight','quantity':'2','unit_rate':'850','tax_rate':'5'}
        self.workflow('quote.line',payload)
        self.assertEqual(next(l for l in self.workspace('quote',quote)['lines'] if l['id']==line['id'])['unit_rate'],'850.00')
        self.workflow('quote.approve',{'id':quote})
        self.denied(lambda:self.workflow('quote.line',{**payload,'unit_rate':'1'}))

    def test_task_gate_blocks_and_then_allows_booking(self):
        _,_,job,_=self.fixtures()
        task=self.workflow('task.add',{'job_id':job,'title':'Verify cargo','due_on':'2026-10-27','required_before':'Booked'})['id']
        self.denied(lambda:self.command('job.book',{'id':job}))
        self.assertEqual(self.read('journal'),[])
        self.workflow('task.complete',{'id':task})
        self.denied(lambda:self.workflow('task.complete',{'id':task}))
        self.command('job.book',{'id':job})
        self.assertEqual(self.read('job',job)['status'],'Booked')

    def test_private_documents_require_actual_upload_and_enforce_stage(self):
        _,_,job,_=self.fixtures()
        self.workflow('document.require',{'job_id':job,'kind':'BL','required_before':'Booked'})
        doc=self.workflow('document.register',{'job_id':job,'kind':'BL','filename':'bl.pdf','mime':'application/pdf','bytes':'123'})['id']
        path=self.workspace('job_workspace',job)['documents'][0]['object_path']
        self.assertTrue(self.conn.execute("select public.bc_document_access(%s,'C')",(path,)).fetchone()[0])
        self.assertFalse(self.conn.execute("select public.bc_document_access(%s,'X')",(path,)).fetchone()[0])
        self.denied(lambda:self.conn.execute('select public.bc_document_finish(%s,%s)',(self.tenant,doc)))
        self.denied(lambda:self.command('job.book',{'id':job}))
        self.conn.execute("insert into storage.objects(bucket_id,name,metadata) values('binderclip-documents',%s,%s)",(path,Jsonb({'size':123,'mimetype':'application/pdf'})))
        self.conn.execute('select public.bc_document_finish(%s,%s)',(self.tenant,doc))
        self.assertFalse(self.conn.execute("select public.bc_document_access(%s,'C')",(path,)).fetchone()[0])
        self.assertTrue(self.conn.execute("select public.bc_document_access(%s,'X')",(path,)).fetchone()[0])
        self.command('job.book',{'id':job})
        self.owner();self.conn.execute("update binderclip.grants set can_export=false where path='operations.documents.manage'");self.client()
        self.assertEqual(self.conn.execute('select count(*) from storage.objects').fetchone()[0],0)
        self.denied(lambda:self.conn.execute("insert into storage.objects(bucket_id,name) values('binderclip-documents','wrong/tenant/path')"))

    def test_invalid_documents_and_cross_company_assignee_denied(self):
        _,_,job,_=self.fixtures()
        self.denied(lambda:self.workflow('document.register',{'job_id':job,'kind':'BL','filename':'bad.html','mime':'text/html','bytes':'10'}))
        self.denied(lambda:self.workflow('document.register',{'job_id':job,'kind':'BL','filename':'huge.pdf','mime':'application/pdf','bytes':'10485761'}))
        self.denied(lambda:self.workflow('task.add',{'job_id':job,'title':'Bad','due_on':'2026-10-27','assignee_id':str(uuid.uuid4())}))

    def test_supplier_payments_post_and_prevent_overpayment(self):
        _,supplier,job,buy=self.fixtures();self.command('job.book',{'id':job});bill=self.bill(supplier,job,buy)
        self.workflow('supplier.pay',{'id':bill,'reference':'SP1','amount':'400','paid_on':'2026-10-27'})
        self.assertEqual(self.report('payables')['rows'][0]['outstanding'],'600.00')
        self.denied(lambda:self.workflow('supplier.pay',{'id':bill,'reference':'SP1','amount':'1','paid_on':'2026-10-27'}))
        self.denied(lambda:self.workflow('supplier.pay',{'id':bill,'reference':'SP2','amount':'601','paid_on':'2026-10-27'}))
        self.workflow('supplier.pay',{'id':bill,'reference':'SP2','amount':'600','paid_on':'2026-10-27'})
        self.assertEqual(self.report('payables')['rows'],[])
        tb=self.report('trial_balance')['rows']
        from decimal import Decimal
        self.assertEqual(sum(Decimal(r['debit']) for r in tb),sum(Decimal(r['credit']) for r in tb))

    def test_finance_report_scope_and_universal_search(self):
        self.issued()
        self.assertEqual(self.report('receivables')['rows'][0]['outstanding'],'1680.00')
        self.assertEqual(len(self.workspace('search',query='Customer')['jobs']),1)
        self.owner();self.conn.execute("update binderclip.grants set scope='none' where path='customers.ledger.view'");self.client()
        self.assertEqual(self.report('receivables')['rows'],[])
        self.owner();self.conn.execute("update binderclip.grants set can_export=false where path='reports.finance.view'");self.client()
        self.denied(lambda:self.report('trial_balance','X'))
        self.denied(lambda:self.workspace('search',query='a'))

    def test_new_modules_require_explicit_role_grants(self):
        _,_,job,_=self.fixtures()
        self.owner();self.conn.execute("update binderclip.grants set scope='none' where path like 'operations.%' or path like 'sales.%'");self.client()
        self.assertEqual(self.workspace('tasks'),[])
        self.denied(lambda:self.workflow('event.add',{'job_id':job,'kind':'Note','title':'Forbidden'}))
        self.denied(lambda:self.workflow('enquiry.save',{}))

    def test_restricted_note_content_cannot_leak_through_job_audit(self):
        _,_,job,_=self.fixtures()
        self.workflow('event.add',{'job_id':job,'kind':'Note','title':'Confidential handling note','detail':'Restricted details'})
        self.owner();self.conn.execute("update binderclip.grants set scope='none' where path='operations.timeline.manage'");self.client()
        self.assertEqual(self.workspace('job_workspace',job)['events'],[])
        self.assertNotIn('Confidential handling note',json.dumps(self.read('job',job)))

    def test_costsheet_lists_exact_buy_sell_and_margin(self):
        _,_,job,_=self.fixtures()
        row=self.costsheet('detail',{'job_id':job})
        self.assertEqual(row['figures']['margin'],'600.00')
        self.assertEqual(row['figures']['margin_percent'],'37.50')
        self.assertEqual(row['buy_lines'],'1')
        self.assertEqual(row['has_invoices'],False)
        self.assertEqual(self.costsheet('list')[0]['sheet_status'],'Open')

    def test_costsheet_apply_quote_is_once_and_preserves_source(self):
        _,quote=self.quote_fixture();self.workflow('quote.approve',{'id':quote})
        source=self.workspace('quote',quote)
        job=self.command('job.save',{'number':'EMPTY-JOB','customer_id':source['customer_id'],'data':source['data']})['id']
        self.costsheet('apply',{'job_id':job,'quote_id':quote})
        self.assertEqual(len(self.read('job',job)['lines']),2)
        self.assertEqual(self.workspace('quote',quote),source)
        self.denied(lambda:self.costsheet('apply',{'job_id':job,'quote_id':quote}))

    def test_quote_copy_does_not_bypass_source_cost_visibility(self):
        self.owner();other=uuid.uuid4();other_session=uuid.uuid4()
        self.conn.execute('insert into auth.users values(%s,%s,now(),null)',(other,'other@example.com'))
        self.conn.execute("insert into auth.identities(user_id,provider) values(%s,'google')",(other,))
        self.conn.execute('insert into auth.sessions values(%s,%s,null)',(other_session,other))
        member=self.conn.execute("insert into binderclip.members(tenant_id,user_id,email,display_name) values(%s,%s,'other@example.com','Other operator') returning id",(self.tenant,other)).fetchone()[0]
        self.conn.execute("insert into binderclip.member_roles(tenant_id,member_id,role_id) select %s,%s,id from binderclip.roles where tenant_id=%s and name='Company administrator'",(self.tenant,member,self.tenant))
        self.conn.execute("select set_config('request.jwt.claims',%s,true)",(json.dumps({'sub':str(other),'session_id':str(other_session)}),));self.client()
        _,quote=self.quote_fixture();self.workflow('quote.approve',{'id':quote})
        source=self.workspace('quote',quote)
        self.owner();self.conn.execute("select set_config('request.jwt.claims',%s,true)",(json.dumps({'sub':str(ADMIN),'session_id':str(SESSION)}),));self.client()
        job=self.command('job.save',{'number':'SCOPED-JOB','customer_id':source['customer_id'],'data':source['data']})['id']
        self.owner();self.conn.execute("update binderclip.grants set scope='self' where path='costs.detail.manage' and action='R'");self.client()
        self.assertEqual(self.costsheet('quotes',{'job_id':job}),[])
        self.denied(lambda:self.costsheet('apply',{'job_id':job,'quote_id':quote}))
        self.denied(lambda:self.workflow('quote.convert',{'id':quote,'job_number':'LEAK'}))
        self.assertEqual(self.read('job',job)['lines'],[])

    def test_number_sequences_are_automatic_separate_and_immutable(self):
        customer,supplier,job,_=self.fixtures()
        self.assertEqual(self.read('customers',customer)[0]['code'],'CUS-000001')
        self.assertEqual(self.read('suppliers',supplier)[0]['code'],'SUP-000001')
        self.assertEqual(self.read('job',job)['number'],'JOB-000001')
        self.assertEqual(self.read('job',job)['costsheet_number'],'CS-000001')
        second=self.command('master.save',{'kind':'customers','name':'Second','currency':'USD','data':{}})['id']
        self.assertEqual(self.read('customers',second)[0]['code'],'CUS-000002')
        self.command('master.save',{'kind':'customers','id':customer,'code':'DO-NOT-RENUMBER','name':'Customer','currency':'AED','data':{}})
        self.assertEqual(self.read('customers',customer)[0]['code'],'CUS-000001')
        self.denied(lambda:self.conn.execute("select binderclip.next_number(%s,'customers')",(self.tenant,)))

    def test_automatic_invoice_and_external_supplier_reference_are_separate(self):
        job,invoice=self.ready()
        self.assertEqual(self.read('invoice',invoice)['number'],'INV-000001')
        bill=self.read('job',job)['bills'][0]
        self.assertEqual(bill['document_number'],'BIL-000001')
        self.assertEqual(bill['number'],'B1')
        self.command('invoice.approve',{'id':invoice});self.command('invoice.issue',{'id':invoice})
        self.command('invoice.receipt',{'id':invoice,'reference':'BANK-123','amount':'100','received_on':'2026-10-27'})
        receipt=self.read('invoice',invoice)['receipts'][0]
        self.assertEqual(receipt['document_number'],'REC-000001');self.assertEqual(receipt['reference'],'BANK-123')

    def test_job_addresses_survive_save_without_manual_number(self):
        customer=self.command('master.save',{'kind':'customers','name':'Address customer','currency':'JPY','data':{}})['id']
        data={'pol':'Tokyo','pod':'Dubai','shipper_address':'Tokyo warehouse, Japan','consignee_address':'Dubai warehouse, UAE'}
        job=self.command('job.save',{'customer_id':customer,'data':data})['id']
        self.assertEqual(self.read('job',job)['data'],data)
        self.assertEqual(self.read('customers',customer)[0]['currency'],'JPY')

    def test_invoice_queue_explains_readiness_and_excludes_billed_jobs(self):
        _,supplier,job,buy=self.fixtures()
        def queue():return self.conn.execute('select public.bc_billing(%s)',(self.tenant,)).fetchone()[0]
        self.assertFalse(queue()[0]['approved']);self.assertEqual(queue()[0]['status'],'Draft')
        self.command('job.book',{'id':job});self.bill(supplier,job,buy);self.command('cost.approve',{'id':job})
        self.assertEqual(queue()[0]['unbilled_count'],'1')
        self.command('invoice.generate',{'job_ids':[job]})
        self.assertEqual(queue()[0]['unbilled_count'],'0')

    def test_number_allocation_is_concurrent_and_does_not_truncate(self):
        from concurrent.futures import ThreadPoolExecutor
        with psycopg.connect(os.environ['SUPABASE_TEST_DSN'],autocommit=True) as owner:
            tenant=owner.execute("insert into binderclip.companies(name) values('Concurrent sequence test') returning id").fetchone()[0]
            try:
                def allocate(_):
                    with psycopg.connect(os.environ['SUPABASE_TEST_DSN'],autocommit=True) as worker:
                        return worker.execute("select binderclip.next_number(%s,'customers')",(tenant,)).fetchone()[0]
                with ThreadPoolExecutor(max_workers=4) as pool:numbers=list(pool.map(allocate,range(12)))
                self.assertEqual(len(set(numbers)),12);self.assertEqual(sorted(numbers)[-1],'CUS-000012')
                owner.execute("update binderclip.number_sequences set last_value=999999 where tenant_id=%s and kind='customers'",(tenant,))
                self.assertEqual(allocate(0),'CUS-1000000')
            finally:
                owner.execute('delete from binderclip.number_sequences where tenant_id=%s',(tenant,));owner.execute('delete from binderclip.companies where id=%s',(tenant,))

    def test_billing_creation_uses_existing_permissions_and_validates_dates(self):
        _,supplier,job,buy=self.fixtures()
        self.command('job.book',{'id':job});self.bill(supplier,job,buy);self.command('cost.approve',{'id':job})
        payload={'job_ids':[job],'invoice_date':'2026-10-27','due_date':'2026-11-26'}
        def create(data):return self.conn.execute('select public.bc_billing(%s,%s,%s)',(self.tenant,'invoice.create',Jsonb(data))).fetchone()[0]
        self.denied(lambda:create({**payload,'due_date':'2026-10-26'}))
        self.owner();self.conn.execute("update binderclip.grants set scope='none' where path='invoicing.detail.generate'");self.client()
        self.denied(lambda:create(payload))
        self.owner();self.conn.execute("update binderclip.grants set scope='global' where path='invoicing.detail.generate'");self.client()
        invoice=create(payload)['id']
        self.assertEqual(self.read('invoice',invoice)['number'],'INV-000001')
        self.assertEqual(self.read('invoice',invoice)['due_date'],'2026-11-26')
        self.denied(lambda:create(payload))

    def test_costsheet_correction_disapproval_and_invoice_freeze(self):
        _,supplier,job,buy=self.fixtures()
        sell=next(l for l in self.read('job',job)['lines'] if l['side']=='SELL')
        self.command('job.book',{'id':job});self.bill(supplier,job,buy)
        change={'job_id':job,'line_id':sell['id'],'service':'Freight','quantity':'2','unit_rate':'850','currency':'AED','fx_rate':'1','tax_rate':'5','reason':'Updated customer agreement'}
        self.denied(lambda:self.costsheet('line.save',{**change,'line_id':buy}))
        self.costsheet('line.save',change)
        self.assertEqual(self.costsheet('detail',{'job_id':job})['changes'][0]['reason'],'Updated customer agreement')
        self.assertNotIn('Updated customer agreement',json.dumps(self.read('job',job)))
        self.command('cost.approve',{'id':job})
        self.denied(lambda:self.costsheet('line.save',change))
        self.denied(lambda:self.costsheet('disapprove',{'job_id':job,'reason':''}))
        self.costsheet('disapprove',{'job_id':job,'reason':'Customer requested handling fee'})
        self.costsheet('line.save',{'job_id':job,'side':'SELL','service':'Handling','quantity':'1','unit_rate':'50','currency':'AED','fx_rate':'1','tax_rate':'5'})
        self.command('cost.approve',{'id':job})
        invoice=self.costsheet('invoice',{'job_id':job,'invoice_date':'2026-10-27','due_date':'2026-11-27'})['id']
        self.assertEqual(self.read('invoice',invoice)['total'],'1837.50')
        self.assertEqual(self.read('invoice',invoice)['due_date'],'2026-11-27')
        self.denied(lambda:self.costsheet('disapprove',{'job_id':job,'reason':'Too late'}))
        self.denied(lambda:self.costsheet('invoice',{'job_id':job}))

    def test_costsheet_print_and_corrections_require_own_process_grants(self):
        _,_,job,_=self.fixtures()
        self.owner();self.conn.execute("update binderclip.grants set can_export=false where path='costs.detail.print'");self.client()
        self.denied(lambda:self.costsheet('print',{'job_id':job}))
        self.assertTrue(self.costsheet('detail',{'job_id':job})['number'].startswith('JOB-'))
        self.owner();self.conn.execute("update binderclip.grants set scope='none' where path='costs.detail.manage' and action='U'");self.client()
        sell=next(l for l in self.read('job',job)['lines'] if l['side']=='SELL')
        self.denied(lambda:self.costsheet('line.save',{'job_id':job,'line_id':sell['id'],'service':'Denied','quantity':'1','unit_rate':'1','currency':'AED','fx_rate':'1','tax_rate':'5','reason':'No access'}))

if __name__ == '__main__': unittest.main(verbosity=2)
