import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from scripts.build_pages import build

class PackagingTests(unittest.TestCase):
    def test_static_workspace_contains_only_explicit_public_assets(self):
        config={'enabled':True,'url':'https://example.supabase.co','publishableKey':'sb_publishable_test','secret':'must never ship'}
        with TemporaryDirectory() as temp:
            build(temp,config)
            root=Path(temp)
            self.assertEqual(json.loads((root/'config.json').read_text()), {k:config[k] for k in ('url','publishableKey')})
            self.assertEqual({p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()}, {
                '.nojekyll','index.html','config.json','assets/app.js','assets/domain.js','assets/fields.js',
                'assets/freight.js','assets/costsheet.js','assets/currencies.js','assets/billing.js','assets/navigation.js','assets/tracking.js','assets/practical.js','assets/invoice-math.js','assets/search.js','assets/pickers.js','assets/idle.js','assets/exchange.js','assets/company-settings.js','assets/workspace.css','assets/app.css','assets/favicon.svg',
                'vendor/supabase-2.117.3.js','vendor/supabase-LICENSE.txt'})
            html=(root/'index.html').read_text(encoding='utf-8')
            self.assertNotIn('__CSP__',html)
            self.assertIn("connect-src 'self' https://example.supabase.co",html)

    def test_secret_keys_and_credential_urls_cannot_be_published(self):
        for url,key in [('https://a.supabase.co','sb_secret_bad'),('https://user:password@a.supabase.co','sb_publishable_test'),('https://a.supabase.co.evil.test','sb_publishable_test')]:
            with self.subTest(url=url), TemporaryDirectory() as temp, self.assertRaises(ValueError):
                build(temp,{'enabled':True,'url':url,'publishableKey':key})
