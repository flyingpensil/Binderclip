param([int]$Port = 8002)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
if (-not (Test-Path '.venv\Scripts\python.exe')) { throw 'Create the Python virtual environment first; see README.md.' }
& .\.venv\Scripts\python scripts/build_pages.py
if ($LASTEXITCODE -ne 0) { throw 'Public workspace build failed.' }
Write-Host "Binderclip Supabase workspace: http://127.0.0.1:$Port/"
Write-Host 'This is the same app as GitHub Pages. It uses the configured Supabase project and never seeds demo accounting data.'
Write-Host "Google sign-in requires http://127.0.0.1:$Port/ in Supabase Authentication > URL Configuration > Redirect URLs."
& .\.venv\Scripts\python -u -m http.server $Port --bind 127.0.0.1 --directory pages-dist
