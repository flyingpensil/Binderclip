"""Package only public portal assets. No ERP source, user data or credentials."""
import json
import os
import shutil
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent

def validate_app_url(value):
    if not value: return ''
    parts = urlsplit(value)
    if parts.scheme != 'https' or not parts.hostname or parts.username or parts.password or parts.path not in ('', '/') or parts.query or parts.fragment:
        raise ValueError('BINDERCLIP_APP_URL must be an HTTPS origin without credentials or a path.')
    return f'{parts.scheme}://{parts.netloc}'

def build(output=None, config=None):
    output = Path(output) if output else ROOT / 'pages-dist'
    output.mkdir(parents=True, exist_ok=True)
    config_file = ROOT / 'supabase-config.json'
    if config is None:
        config = json.loads(config_file.read_text(encoding='utf-8')) if config_file.exists() else {}
    if config.get('enabled'):
        origin = validate_app_url(config.get('url', ''))
        import re
        if not re.fullmatch(r'https://[a-z0-9]+\.supabase\.co', origin):
            raise ValueError('Expected a Supabase project HTTPS origin.')
        key = config.get('publishableKey', '')
        if not re.fullmatch(r'sb_publishable_[A-Za-z0-9_-]+', key):
            raise ValueError('Only a public Supabase publishable key may be packaged.')
        assets = output / 'assets'
        assets.mkdir(exist_ok=True)
        for name in ('app.js', 'domain.js', 'fields.js', 'freight.js', 'costsheet.js', 'currencies.js', 'billing.js', 'navigation.js', 'tracking.js', 'practical.js', 'invoice-math.js', 'search.js', 'pickers.js', 'idle.js', 'exchange.js', 'company-settings.js', 'workspace.css'):
            shutil.copyfile(ROOT / 'web' / name, assets / name)
        for name in ('app.css', 'favicon.svg'):
            shutil.copyfile(ROOT / 'static' / name, assets / name)
        shutil.copytree(ROOT / 'web/vendor', output / 'vendor', dirs_exist_ok=True)
        csp = f"default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' {origin}; img-src 'self' data:; base-uri 'none'; object-src 'none'; frame-src 'none'; form-action 'self'"
        html = (ROOT / 'web/index.html').read_text(encoding='utf-8').replace('__CSP__', csp)
        (output / 'index.html').write_text(html, encoding='utf-8')
        public_config = {'url': origin, 'publishableKey': key}
        features = {name: True for name in ('freight', 'costSheets', 'documentService') if config.get('features', {}).get(name) is True}
        if features:
            public_config['features'] = features
        (output / 'config.json').write_text(json.dumps(public_config), encoding='utf-8')
        (output / '.nojekyll').touch()
        print('Binderclip Supabase workspace built with public configuration only.')
        return
    (output / 'static').mkdir(exist_ok=True)
    shutil.copyfile(ROOT / 'index.html', output / 'index.html')
    for name in ('portal.css', 'portal.js', 'favicon.svg'):
        shutil.copyfile(ROOT / 'static' / name, output / 'static' / name)
    committed = json.loads((ROOT / 'deployment.json').read_text(encoding='utf-8'))
    app_url = validate_app_url(os.getenv('BINDERCLIP_APP_URL', '').strip() or committed.get('appUrl', '').strip())
    (output / 'deployment.json').write_text(json.dumps({'appUrl': app_url}, indent=2), encoding='utf-8')
    (output / '.nojekyll').touch()
    print(f'Public portal built. Workspace URL {"configured" if app_url else "awaiting deployment"}.')

if __name__ == '__main__': build()
