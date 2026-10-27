from django.db import migrations, models

def install(apps, schema_editor):
    if schema_editor.connection.vendor != 'postgresql': return
    schema_editor.execute('''
    CREATE FUNCTION binderclip_posting_transaction() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN NEW.posting_transaction := txid_current(); RETURN NEW; END $$;
    CREATE TRIGGER journal_transaction BEFORE INSERT ON erp_journalentry FOR EACH ROW EXECUTE FUNCTION binderclip_posting_transaction();
    CREATE FUNCTION binderclip_line_insert() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF (SELECT posting_transaction FROM erp_journalentry WHERE id=NEW.entry_id) IS DISTINCT FROM txid_current() THEN
        RAISE EXCEPTION 'Cannot append lines to a previously committed journal';
      END IF;
      RETURN NEW;
    END $$;
    CREATE TRIGGER journal_line_insert BEFORE INSERT ON erp_journalline FOR EACH ROW EXECUTE FUNCTION binderclip_line_insert();
    CREATE FUNCTION binderclip_tenant_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF OLD.tenant_id IS DISTINCT FROM NEW.tenant_id THEN RAISE EXCEPTION 'Cannot move existing records between companies'; END IF;
      RETURN NEW;
    END $$;
    ''')
    for model in apps.get_app_config('erp').get_models():
        if any(f.name == 'tenant' for f in model._meta.fields):
            schema_editor.execute(f'CREATE TRIGGER tenant_immutable BEFORE UPDATE ON "{model._meta.db_table}" FOR EACH ROW EXECUTE FUNCTION binderclip_tenant_immutable();')

def uninstall(apps, schema_editor):
    if schema_editor.connection.vendor != 'postgresql': return
    for function in ['binderclip_posting_transaction', 'binderclip_line_insert', 'binderclip_tenant_immutable']:
        schema_editor.execute(f'DROP FUNCTION IF EXISTS {function}() CASCADE')

class Migration(migrations.Migration):
    dependencies = [('erp', '0002_postgres_integrity')]
    operations = [migrations.AddField(model_name='journalentry', name='posting_transaction', field=models.BigIntegerField(default=0, editable=False)), migrations.RunPython(install, uninstall)]
