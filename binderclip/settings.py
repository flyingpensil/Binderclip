import os
from pathlib import Path
from django.core.exceptions import ImproperlyConfigured
from .config import app_origin, postgres_database

BASE_DIR = Path(__file__).resolve().parent.parent
DEBUG = os.getenv('DEBUG', 'false').lower() == 'true'
SECRET_KEY = os.getenv('SECRET_KEY', '')
if not SECRET_KEY:
    if not DEBUG:
        raise ImproperlyConfigured('Set SECRET_KEY (a long random secret) or DEBUG=true for local development.')
    SECRET_KEY = 'local-development-only-never-use-in-production'
ALLOWED_HOSTS = [host.strip() for host in os.getenv('ALLOWED_HOSTS', 'localhost,127.0.0.1,[::1]').split(',') if host.strip()]
RENDER_HOST = os.getenv('RENDER_EXTERNAL_HOSTNAME', '')
APP_BASE_URL = os.getenv('APP_BASE_URL', '') or (f'https://{RENDER_HOST}' if RENDER_HOST else '')
if APP_BASE_URL:
    APP_BASE_URL = app_origin(APP_BASE_URL, DEBUG)
    from urllib.parse import urlsplit
    ALLOWED_HOSTS.append(urlsplit(APP_BASE_URL).hostname)
if RENDER_HOST:
    ALLOWED_HOSTS.append(RENDER_HOST)
INSTALLED_APPS = [
    'django.contrib.auth', 'django.contrib.contenttypes', 'django.contrib.sessions',
    'django.contrib.messages', 'django.contrib.staticfiles', 'erp',
]
MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware', 'whitenoise.middleware.WhiteNoiseMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware', 'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware', 'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware', 'django.middleware.clickjacking.XFrameOptionsMiddleware',
    'erp.security.TenantMiddleware',
]
ROOT_URLCONF = 'binderclip.urls'
WSGI_APPLICATION = 'binderclip.wsgi.application'
TEMPLATES = [{'BACKEND': 'django.template.backends.django.DjangoTemplates', 'DIRS': [BASE_DIR / 'templates'], 'APP_DIRS': True,
              'OPTIONS': {'context_processors': ['django.template.context_processors.request', 'django.contrib.auth.context_processors.auth',
                                                'django.contrib.messages.context_processors.messages', 'erp.security.navigation']}}]
if os.getenv('DATABASE_URL'):
    DATABASES = {'default': postgres_database(os.environ['DATABASE_URL'])}
elif os.getenv('POSTGRES_DB'):
    DATABASES = {'default': {'ENGINE': 'django.db.backends.postgresql', 'NAME': os.environ['POSTGRES_DB'],
                            'USER': os.environ['POSTGRES_USER'], 'PASSWORD': os.environ['POSTGRES_PASSWORD'],
                            'HOST': os.getenv('POSTGRES_HOST', 'localhost'), 'PORT': os.getenv('POSTGRES_PORT', '5432'),
                            'CONN_MAX_AGE': 60}}
elif DEBUG or 'test' in __import__('sys').argv:
    DATABASES = {'default': {'ENGINE': 'django.db.backends.sqlite3', 'NAME': BASE_DIR / 'db.sqlite3'}}
else:
    raise ImproperlyConfigured('Production requires PostgreSQL configuration.')
AUTH_PASSWORD_VALIDATORS = [{'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator'},
                            {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'}]
LANGUAGE_CODE = 'en-us'
TIME_ZONE = 'Asia/Dubai'
USE_TZ = True
STATIC_URL = '/static/'
STATICFILES_DIRS = [BASE_DIR / 'static']
STATIC_ROOT = BASE_DIR / 'staticfiles'
STORAGES = {'default': {'BACKEND': 'django.core.files.storage.FileSystemStorage'},
            'staticfiles': {'BACKEND': 'whitenoise.storage.CompressedManifestStaticFilesStorage'}}
DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'
LOGIN_URL = '/login/'
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = 'Lax'
SESSION_COOKIE_AGE = 28800
SESSION_COOKIE_SECURE = not DEBUG
CSRF_COOKIE_SECURE = not DEBUG
SECURE_SSL_REDIRECT = not DEBUG
SECURE_HSTS_SECONDS = 31536000 if not DEBUG else 0
SECURE_HSTS_INCLUDE_SUBDOMAINS = not DEBUG
SECURE_HSTS_PRELOAD = not DEBUG
SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = 'DENY'
CSRF_TRUSTED_ORIGINS = list(filter(None, os.getenv('CSRF_TRUSTED_ORIGINS', '').split(',')))
if APP_BASE_URL:
    CSRF_TRUSTED_ORIGINS.append(APP_BASE_URL)
# Set only when an ingress strips untrusted forwarded headers.
if os.getenv('TRUST_PROXY', 'false').lower() == 'true':
    SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
GOOGLE_CLIENT_ID = os.getenv('GOOGLE_CLIENT_ID', '')
GOOGLE_CLIENT_SECRET = os.getenv('GOOGLE_CLIENT_SECRET', '')
GOOGLE_REDIRECT_URI = os.getenv('GOOGLE_REDIRECT_URI', '') or f'{APP_BASE_URL or "http://127.0.0.1:8001"}/auth/google/callback/'
DEMO_LOGIN = DEBUG and os.getenv('DEMO_LOGIN', 'false').lower() == 'true'
INITIAL_ADMIN_EMAIL = os.getenv('INITIAL_ADMIN_EMAIL', '')
INITIAL_ADMIN_NAME = os.getenv('INITIAL_ADMIN_NAME', 'Admin1')
INITIAL_ADMIN_USERNAME = os.getenv('INITIAL_ADMIN_USERNAME', 'Admin1')
INITIAL_COMPANY_NAME = os.getenv('INITIAL_COMPANY_NAME', 'Binderclip')
