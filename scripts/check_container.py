"""CI-only smoke check for an isolated container and disposable database."""
import os
import re
import sys
from pathlib import Path
import requests
import django

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'binderclip.settings')
django.setup()
from django.contrib.auth import get_user_model
from erp.models import Job, Membership

def main():
    # This must run only against the disposable CI container described in ci.yml.
    user = get_user_model().objects.get(username='Admin1', is_active=True)
    assert user.email == 'inventory.choco@gmail.com'
    assert not user.has_usable_password()
    assert Membership.objects.filter(user=user, active=True).count() == 1
    assert Job.objects.count() == 0
    headers = {'X-Forwarded-Proto': 'https'}
    response = requests.get('http://127.0.0.1:8000/login/', headers=headers, timeout=10)
    assert response.status_code == 200
    assert 'Explore the local demo' not in response.text
    css = re.search(r'href="(/static/app\.[^"/]+\.css)"', response.text)
    assert css, 'Production login must reference a versioned CSS asset.'
    asset = requests.get('http://127.0.0.1:8000' + css.group(1), headers=headers, timeout=10)
    assert asset.status_code == 200
    print('Container passed: Admin1 only, no sample jobs, no demo button, versioned CSS served.')

if __name__ == '__main__': main()
