import hashlib
import secrets
import time
import uuid
from urllib.parse import urlencode
import requests
from google.auth.transport.requests import Request
from google.oauth2 import id_token
from django.conf import settings
from django.contrib import messages
from django.contrib.auth import get_user_model, login, logout
from django.core.exceptions import PermissionDenied
from django.db import transaction
from django.shortcuts import redirect, render
from django.views.decorators.http import require_POST
from .models import GoogleIdentity, Membership

def login_page(request):
    if request.user.is_authenticated and request.membership: return redirect('dashboard')
    return render(request, 'login.html', {'google_enabled': bool(settings.GOOGLE_CLIENT_ID), 'demo_enabled': settings.DEMO_LOGIN})

def google_start(request):
    if not settings.GOOGLE_CLIENT_ID or not settings.GOOGLE_CLIENT_SECRET:
        messages.error(request, 'Google sign-in has not been configured.'); return redirect('login')
    state = secrets.token_urlsafe(32); nonce = secrets.token_urlsafe(32)
    request.session['oauth'] = {'state': state, 'nonce': nonce, 'time': time.time()}
    query = urlencode({'client_id': settings.GOOGLE_CLIENT_ID, 'redirect_uri': settings.GOOGLE_REDIRECT_URI,
                       'response_type': 'code', 'scope': 'openid email profile', 'state': state, 'nonce': nonce,
                       'prompt': 'select_account'})
    return redirect('https://accounts.google.com/o/oauth2/v2/auth?' + query)

def google_callback(request):
    oauth = request.session.pop('oauth', {})
    if not oauth or not secrets.compare_digest(oauth.get('state', ''), request.GET.get('state', '')) or time.time() - oauth.get('time', 0) > 600:
        raise PermissionDenied('Sign-in expired or state validation failed.')
    if not request.GET.get('code'):
        messages.error(request, 'Google sign-in was cancelled.'); return redirect('login')
    try:
        response = requests.post('https://oauth2.googleapis.com/token', timeout=15, data={
            'client_id': settings.GOOGLE_CLIENT_ID, 'client_secret': settings.GOOGLE_CLIENT_SECRET,
            'code': request.GET['code'], 'grant_type': 'authorization_code', 'redirect_uri': settings.GOOGLE_REDIRECT_URI})
        response.raise_for_status()
        claims = id_token.verify_oauth2_token(response.json()['id_token'], Request(), settings.GOOGLE_CLIENT_ID)
        if not claims.get('email_verified') or claims.get('nonce') != oauth['nonce']: raise ValueError('Unverified identity')
        email = claims['email'].lower()
        with transaction.atomic():
            identity = GoogleIdentity.objects.select_related('user').filter(subject=claims['sub']).first()
            if identity:
                user = identity.user
            else:
                # Only an exact, unambiguous pre-provisioned verified email may bind a new Google subject.
                users = list(get_user_model().objects.select_for_update().filter(email__iexact=email, is_active=True)[:2])
                if len(users) != 1: raise PermissionDenied('Ask your company administrator to invite your Google email.')
                user = users[0]
                if GoogleIdentity.objects.filter(user=user).exists(): raise PermissionDenied('A different Google identity is already bound to this account.')
                GoogleIdentity.objects.create(user=user, subject=claims['sub'])
            if not user.is_active or not Membership.objects.filter(user=user, active=True).exists(): raise PermissionDenied('No active company membership.')
        login(request, user, backend='django.contrib.auth.backends.ModelBackend')
        return redirect('dashboard')
    except (requests.RequestException, ValueError, KeyError):
        messages.error(request, 'Google sign-in could not be verified. Please try again.')
        return redirect('login')

@require_POST
def demo_login(request):
    if not settings.DEMO_LOGIN: raise PermissionDenied('Local demo login is disabled.')
    user = get_user_model().objects.filter(username='demo@binderclip.local', is_active=True).first()
    if not user: raise PermissionDenied('Run seed_demo first.')
    login(request, user, backend='django.contrib.auth.backends.ModelBackend')
    return redirect('dashboard')

@require_POST
def logout_view(request):
    logout(request)
    return redirect('login')

@require_POST
def switch_company(request):
    if not request.user.is_authenticated: return redirect('login')
    try: tenant_id = uuid.UUID(request.POST.get('tenant_id', ''))
    except (ValueError, TypeError, AttributeError): raise PermissionDenied('Invalid company.')
    membership = Membership.objects.filter(user=request.user, tenant_id=tenant_id, active=True).first()
    if not membership: raise PermissionDenied('Company access denied.')
    request.session['tenant_id'] = str(membership.tenant_id)
    return redirect('dashboard')
