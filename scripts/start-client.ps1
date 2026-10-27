param([int]$Port = 8001)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
if ($env:POSTGRES_DB -or $env:DATABASE_URL) { throw 'This local script only uses SQLite. Deploy the configured PostgreSQL application with the Render launch guide.' }
if (-not (Test-Path '.venv\Scripts\python.exe')) { throw 'Install the Python environment and requirements first. See README.md.' }
$env:DEBUG = 'true'
$env:DEMO_LOGIN = 'false'
$env:INITIAL_ADMIN_EMAIL = 'inventory.choco@gmail.com'
$env:INITIAL_ADMIN_NAME = 'Admin1'
$env:INITIAL_ADMIN_USERNAME = 'Admin1'
$env:INITIAL_COMPANY_NAME = 'Binderclip'
& .\.venv\Scripts\python manage.py migrate
if ($LASTEXITCODE -ne 0) { throw 'Database migration failed.' }
& .\.venv\Scripts\python manage.py provision_admin --disable-demo
if ($LASTEXITCODE -ne 0) { throw 'Account provisioning failed.' }
& .\.venv\Scripts\python manage.py check_login
if ($LASTEXITCODE -ne 0) { throw 'Login configuration check failed.' }
& .\.venv\Scripts\python -u manage.py runserver "127.0.0.1:$Port" --noreload
