#!/usr/bin/env sh
set -eu
: "${DATABASE_URL:?Set DATABASE_URL from the private PostgreSQL addon}"
: "${SECRET_KEY:?Set a long random SECRET_KEY in the hosting secret store}"
: "${APP_BASE_URL:?Set APP_BASE_URL to the assigned HTTPS service origin}"
: "${INITIAL_ADMIN_EMAIL:?Set INITIAL_ADMIN_EMAIL to the first administrator Google email}"
if [ "${DEBUG:-false}" != "false" ] || [ "${DEMO_LOGIN:-false}" != "false" ]; then
    echo 'Hosted startup requires DEBUG=false and DEMO_LOGIN=false.' >&2
    exit 1
fi
# Use one service replica for the free client-evaluation deployment.
python manage.py migrate --noinput
python manage.py provision_admin --disable-demo
exec gunicorn binderclip.wsgi:application \
    --bind "0.0.0.0:${PORT:-8000}" \
    --workers "${WEB_CONCURRENCY:-1}" --threads 2 --timeout 60 --access-logfile -
