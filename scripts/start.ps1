param([int]$Port = 8001)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
if ($env:POSTGRES_DB) { throw 'This demo script only starts local SQLite. Use the manual PostgreSQL startup instructions for a configured database.' }
if (-not (Test-Path '.venv\Scripts\python.exe')) {
    python -m venv .venv
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the virtual environment.' }
    & .\.venv\Scripts\python -m pip install -r requirements.txt
    if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
}
$env:DEBUG = 'true'
$env:DEMO_LOGIN = 'true'
& .\.venv\Scripts\python manage.py migrate
if ($LASTEXITCODE -ne 0) { throw 'Database migration failed.' }
& .\.venv\Scripts\python manage.py seed_demo
if ($LASTEXITCODE -ne 0) { throw 'Demo seeding failed.' }
& .\.venv\Scripts\python -u manage.py runserver "127.0.0.1:$Port" --noreload
