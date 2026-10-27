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

def build(output=None):
    output = Path(output) if output else ROOT / 'pages-dist'
    output.mkdir(parents=True, exist_ok=True)
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
