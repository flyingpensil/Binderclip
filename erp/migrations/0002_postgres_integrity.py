"""Defense in depth on PostgreSQL; SQLite remains a local, single-user preview."""
from django.db import migrations

def install(apps, schema_editor):
    if schema_editor.connection.vendor != 'postgresql': return
    schema_editor.execute('''
    CREATE FUNCTION binderclip_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'Posted journals and audit events are immutable'; END $$;
    CREATE TRIGGER journal_entry_immutable BEFORE UPDATE OR DELETE ON erp_journalentry FOR EACH ROW EXECUTE FUNCTION binderclip_immutable();
    CREATE TRIGGER journal_line_immutable BEFORE UPDATE OR DELETE ON erp_journalline FOR EACH ROW EXECUTE FUNCTION binderclip_immutable();
    CREATE TRIGGER audit_immutable BEFORE UPDATE OR DELETE ON erp_auditevent FOR EACH ROW EXECUTE FUNCTION binderclip_immutable();
    CREATE FUNCTION binderclip_balanced() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE target uuid; n integer; d numeric; c numeric;
    BEGIN
      IF TG_TABLE_NAME = 'erp_journalentry' THEN target := NEW.id; ELSE target := NEW.entry_id; END IF;
      SELECT count(*), coalesce(sum(debit),0), coalesce(sum(credit),0) INTO n,d,c FROM erp_journalline WHERE entry_id = target;
      IF n < 2 OR d <> c THEN RAISE EXCEPTION 'Journal % must have balanced debit and credit lines', target; END IF;
      RETURN NEW;
    END $$;
    CREATE CONSTRAINT TRIGGER balanced_entry AFTER INSERT ON erp_journalentry DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION binderclip_balanced();
    CREATE CONSTRAINT TRIGGER balanced_lines AFTER INSERT ON erp_journalline DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION binderclip_balanced();
    CREATE FUNCTION binderclip_same_tenant() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE related_tenant uuid; related_id text;
    BEGIN
      related_id := to_jsonb(NEW)->>TG_ARGV[1];
      IF related_id IS NOT NULL THEN
        EXECUTE format('SELECT tenant_id FROM %I WHERE id = $1::uuid', TG_ARGV[0]) INTO related_tenant USING related_id;
        IF related_tenant IS DISTINCT FROM NEW.tenant_id THEN RAISE EXCEPTION 'Cross-company relationship is forbidden'; END IF;
      END IF;
      RETURN NEW;
    END $$;
    CREATE FUNCTION binderclip_membership_role_tenant() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF (SELECT tenant_id FROM erp_membership WHERE id = NEW.membership_id) IS DISTINCT FROM
         (SELECT tenant_id FROM erp_role WHERE id = NEW.role_id) THEN RAISE EXCEPTION 'Cross-company role assignment is forbidden'; END IF;
      RETURN NEW;
    END $$;
    CREATE TRIGGER membership_roles_tenant BEFORE INSERT OR UPDATE ON erp_membership_roles FOR EACH ROW EXECUTE FUNCTION binderclip_membership_role_tenant();
    ''')
    for model in apps.get_app_config('erp').get_models():
        fields = {f.name for f in model._meta.fields}
        if 'tenant' not in fields: continue
        for field in model._meta.fields:
            related = getattr(field, 'related_model', None)
            if related and any(f.name == 'tenant' for f in related._meta.fields):
                table = model._meta.db_table; related_table = related._meta.db_table; column = field.column
                schema_editor.execute(f'CREATE TRIGGER "tenant_{column}" BEFORE INSERT OR UPDATE ON "{table}" FOR EACH ROW EXECUTE FUNCTION binderclip_same_tenant(\'{related_table}\', \'{column}\');')

def uninstall(apps, schema_editor):
    if schema_editor.connection.vendor != 'postgresql': return
    for function in ['binderclip_immutable', 'binderclip_balanced', 'binderclip_same_tenant', 'binderclip_membership_role_tenant']:
        schema_editor.execute(f'DROP FUNCTION IF EXISTS {function}() CASCADE')

class Migration(migrations.Migration):
    dependencies = [('erp', '0001_initial')]
    operations = [migrations.RunPython(install, uninstall)]
