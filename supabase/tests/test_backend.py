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

    def test_task_gate_blocks_and_then_allows_booking(self):
        _,_,job,_=self.fixtures()
        task=self.workflow('task.add',{'job_id':job,'title':'Verify cargo','due_on':'2026-10-27','required_before':'Booked'})['id']
        self.denied(lambda:self.command('job.book',{'id':job}))
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

if __name__ == '__main__': unittest.main(verbosity=2)
