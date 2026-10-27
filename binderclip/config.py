"""Small, tested helpers for host-provided connection strings and app origins."""
from urllib.parse import parse_qs, unquote, urlsplit
from django.core.exceptions import ImproperlyConfigured

def postgres_database(url):
    try:
        parts = urlsplit(url)
        port = parts.port or 5432
    except ValueError as exc:
        raise ImproperlyConfigured('DATABASE_URL has an invalid host or port.') from exc
    if parts.scheme not in ('postgres', 'postgresql') or not parts.hostname or not parts.username or not parts.path.strip('/') or parts.fragment:
        raise ImproperlyConfigured('DATABASE_URL must be a PostgreSQL connection URL with a host, user and database.')
    query = parse_qs(parts.query)
    if set(query) - {'sslmode', 'connect_timeout'}:
        raise ImproperlyConfigured('DATABASE_URL supports only sslmode and connect_timeout query parameters.')
    sslmode = query.get('sslmode', ['require'])[-1]
    if sslmode not in ('disable', 'allow', 'prefer', 'require', 'verify-ca', 'verify-full'):
        raise ImproperlyConfigured('DATABASE_URL has an invalid sslmode.')
    return {'ENGINE': 'django.db.backends.postgresql', 'NAME': unquote(parts.path[1:]),
            'USER': unquote(parts.username), 'PASSWORD': unquote(parts.password or ''),
            'HOST': parts.hostname, 'PORT': str(port), 'CONN_MAX_AGE': 60,
            'CONN_HEALTH_CHECKS': True,
            'OPTIONS': {'sslmode': sslmode, 'connect_timeout': int(query.get('connect_timeout', ['10'])[-1])}}

def app_origin(url, debug=False):
    parts = urlsplit(url)
    local = parts.hostname in ('localhost', '127.0.0.1', '::1')
    if (parts.scheme != 'https' and not (debug and local and parts.scheme == 'http')) or not parts.hostname or parts.username or parts.password or parts.path not in ('', '/') or parts.query or parts.fragment:
        raise ImproperlyConfigured('APP_BASE_URL must be an HTTPS origin, such as https://your-app.onrender.com.')
    return f'{parts.scheme}://{parts.netloc}'
