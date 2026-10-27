from django.urls import path
from erp import auth, views

urlpatterns = [
    path('health/', views.health, name='health'),
    path('login/', auth.login_page, name='login'), path('login/demo/', auth.demo_login, name='demo-login'),
    path('logout/', auth.logout_view, name='logout'), path('company/switch/', auth.switch_company, name='switch-company'),
    path('auth/google/', auth.google_start, name='google-start'), path('auth/google/callback/', auth.google_callback, name='google-callback'),
    path('', views.dashboard, name='dashboard'),
    path('jobs/<uuid:pk>/', views.job_detail, name='job-detail'),
    path('jobs/<uuid:pk>/line/', views.cost_line, name='cost-line'),
    path('jobs/<uuid:pk>/bill/', views.supplier_bill, name='supplier-bill'),
    path('jobs/<uuid:pk>/action/<str:action>/', views.job_action, name='job-action'),
    path('invoices/', views.invoices, name='invoices'), path('invoices/consolidate/', views.consolidate, name='consolidate'),
    path('invoices/<uuid:pk>/', views.invoice_detail, name='invoice-detail'),
    path('invoices/<uuid:pk>/print/', views.invoice_print, name='invoice-print'),
    path('invoices/<uuid:pk>/action/<str:action>/', views.invoice_action, name='invoice-action'),
    path('invoices/<uuid:pk>/receipt/', views.receipt, name='receipt'),
    path('rates/<uuid:pk>/', views.rate_detail, name='rate-detail'),
    path('ledger/<str:kind>/<uuid:pk>/', views.ledger, name='ledger'),
    path('journal/', views.journal, name='journal'),
    path('roles/', views.roles, name='roles'), path('roles/new/', views.role_create, name='role-create'),
    path('roles/<uuid:pk>/', views.role_detail, name='role-detail'), path('members/new/', views.member_create, name='member-create'),
]
for kind in views.ENTITY:
    urlpatterns += [path(f'{kind}/', views.entity_list, {'kind': kind}, name=kind),
                    path(f'{kind}/new/', views.entity_form, {'kind': kind}, name=f'{kind}-create'),
                    path(f'{kind}/<uuid:pk>/edit/', views.entity_form, {'kind': kind}, name=f'{kind}-edit')]
