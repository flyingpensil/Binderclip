from django import template
from erp.security import grants
register = template.Library()

@register.simple_tag(takes_context=True)
def allowed(context, path, action='R'):
    return grants(context['request'].membership, path, action).exists()

@register.filter
def money(value):
    if value is None: return '—'
    return f'{value:,.2f}'
