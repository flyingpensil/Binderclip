import test from 'node:test';
import assert from 'node:assert/strict';
import {operatingFields,suggestOperatingSettings,salesTaxDefaults} from '../company-settings.js';
test('country presets propose defaults without asserting VAT registration',()=>{
 const form={elements:Object.fromEntries(Object.entries({country_code:'ae',tax_status:'Unconfirmed',currency:'USD',timezone:'UTC',default_vat_rate:'0',default_tax_reason:''}).map(([k,value])=>[k,{value}]))};
 suggestOperatingSettings(form);assert.equal(form.elements.currency.value,'AED');assert.equal(form.elements.tax_status.value,'Unconfirmed');
 form.elements.tax_status.value='VAT registered';suggestOperatingSettings(form);assert.equal(form.elements.default_vat_rate.value,'5');
 form.elements.tax_status.value='Not VAT registered';suggestOperatingSettings(form);assert.equal(form.elements.default_vat_rate.value,'0');assert.equal(form.elements.default_tax_reason.value,'Company not VAT registered');
});
test('posted-company settings lock currency and timezone and defaults are explicit',()=>{
 const fields=operatingFields([{key:'name'},{key:'trn'}],{financial_settings_locked:true});
 assert.equal(fields.find(f=>f.key==='currency').readOnly,true);assert.equal(fields.find(f=>f.key==='timezone').readOnly,true);
 assert.deepEqual(salesTaxDefaults({default_vat_rate:'0',default_tax_reason:'Reviewed exemption'}),{tax_rate:'0',exemption:'Reviewed exemption'});
});
