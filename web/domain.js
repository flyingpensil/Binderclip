export const escapeHTML = value => String(value ?? '').replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));
export function scaled(value, places=2) {
  const text=String(value ?? '0').trim().replace(/^(-?)\./,(_,sign)=>sign+'0.');
  if(!/^-?\d+(\.\d+)?$/.test(text)) throw new Error('Invalid decimal');
  const negative=text.startsWith('-'), [whole,fraction='']=(negative?text.slice(1):text).split('.');
  const digits=(fraction+'0'.repeat(places)).slice(0,places);
  let result=BigInt(whole)*10n**BigInt(places)+BigInt(digits||'0');
  if(Number(fraction[places]||0)>=5) result+=1n;
  return negative?-result:result;
}
export function decimal(value, places=2) {
  const negative=value<0n, absolute=negative?-value:value, base=10n**BigInt(places);
  return `${negative?'-':''}${absolute/base}.${String(absolute%base).padStart(places,'0')}`;
}
export function money(value) {
  const text=decimal(scaled(value)),[whole,fraction]=text.split('.');
  return `${whole.replace(/\B(?=(\d{3})+(?!\d))/g,',')}.${fraction}`;
}
export const balance = invoice => decimal(scaled(invoice.total)-scaled(invoice.paid));
export function lineAmount(line) {
  const product=scaled(line.quantity,3)*scaled(line.unit_rate,2);
  return decimal((product+500n)/1000n);
}
export const businessDate=(date=new Date(),timeZone='Asia/Dubai')=>date.toLocaleDateString('en-CA',{timeZone});
export function recordDate(value,timeZone='Asia/Dubai'){const text=String(value||'');if(text.length<=10)return text;const date=new Date(text);return Number.isNaN(date.getTime())?text.slice(0,10):businessDate(date,timeZone);}
export function displayStatus(invoice,today=businessDate()) {
  return ['Issued','Partially Paid'].includes(invoice.status)&&invoice.due_date<today?'Overdue':invoice.status;
}
export function permitted(grants,path,action='R') {
  return grants.some(grant=>grant.path===path&&grant.action===action&&grant.scope!=='none'&&(action!=='X'||grant.can_export));
}
export function csvCell(value) {
  let text=String(value ?? '');
  if(/^[\s]*[=+\-@\t\r\n]/.test(text)) text="'"+text;
  return `"${text.replace(/"/g,'""')}"`;
}
export const csv = rows => '\ufeff'+rows.map(row=>row.map(csvCell).join(',')).join('\r\n');
export function validateConfig(value) {
  const url=new URL(value.url);
  if(url.protocol!=='https:'||url.username||url.password||url.pathname!=='/'||url.search||url.hash||!url.hostname.endsWith('.supabase.co')) throw new Error('Invalid Supabase project URL');
  const key=String(value.publishableKey||'');
  if(!/^sb_publishable_[A-Za-z0-9_-]+$/.test(key)) throw new Error('Only a Supabase publishable key belongs in the website configuration');
  return {url:url.origin,publishableKey:key,features:{freight:value.features?.freight===true,costSheets:value.features?.costSheets===true,documentService:value.features?.documentService===true,recordAttachments:value.features?.recordAttachments===true}};
}
