export const countrySuggestions=[['AE','United Arab Emirates'],['OM','Oman'],['SA','Saudi Arabia'],['QA','Qatar'],['BH','Bahrain'],['KW','Kuwait'],['IN','India'],['PK','Pakistan'],['CN','China'],['SG','Singapore'],['GB','United Kingdom'],['US','United States'],['DE','Germany'],['NL','Netherlands']].map(([value,label])=>({value,label}));
export const timezoneOptions=[...new Set(['UTC','Asia/Dubai',...(Intl.supportedValuesOf?.('timeZone')||[])])].map(value=>({id:value,name:value}));
export const salesTaxDefaults=company=>({tax_rate:String(company.default_vat_rate??5),exemption:company.default_tax_reason||''});
export function operatingFields(fields,company){const locked=company.financial_settings_locked===true;return [
 ...fields.slice(0,1),
 {key:'country_code',label:'Country of registration (2-letter code)',type:'text',pattern:'[A-Z]{2}',suggestions:countrySuggestions,help:'Choose a country suggestion or enter its two-letter code, e.g. AE for United Arab Emirates.'},
 {key:'currency',label:'Accounting currency',type:'text',required:true,readOnly:locked,help:locked?'Locked because financial documents exist. Customer and supplier currencies can still differ.':'Current amounts use two decimal places. Confirm currency compatibility before entering financial documents.'},
 {key:'timezone',label:'Company timezone',type:locked?'text':'select',required:true,readOnly:locked,options:timezoneOptions,help:locked?'Locked to preserve historical posting dates.':'Used for business dates, report cutoffs and entry history.'},
 {key:'tax_status',label:'VAT registration status',type:'select',required:true,options:['Unconfirmed','VAT registered','Not VAT registered'],help:'Save a confirmed status only after checking it with the client. Country presets suggest defaults; they do not verify registration.'},
 ...fields.slice(1),
 {key:'default_vat_rate',label:'Default sales VAT %',type:'number',required:true,min:'0',max:'100',step:'.01',help:'Used for new customer charges and quotation lines. Each service still needs its own correct tax treatment.'},
 {key:'default_tax_reason',label:'Default zero-tax reason',type:'text',help:'Required when a VAT-registered company chooses a default rate of 0%. Not-registered status supplies its own reason.'}
 ];}
export function suggestOperatingSettings(form,locked=false){const country=form.elements.country_code.value.trim().toUpperCase(),status=form.elements.tax_status.value;form.elements.country_code.value=country;
 form.elements.country_code.required=status!=='Unconfirmed';if(form.elements.trn)form.elements.trn.required=status==='VAT registered';form.elements.default_vat_rate.readOnly=status==='Not VAT registered';form.elements.default_tax_reason.readOnly=status==='Not VAT registered';
 if(country==='AE'){
  if(!locked){form.elements.currency.value='AED';form.elements.timezone.value='Asia/Dubai';}
  if(status==='VAT registered'){form.elements.default_vat_rate.value='5';form.elements.default_tax_reason.value='';}
 }
 if(status==='Not VAT registered'){form.elements.default_vat_rate.value='0';form.elements.default_tax_reason.value='Company not VAT registered';}
}
