import test from 'node:test';
import assert from 'node:assert/strict';
import {invoiceTotals} from '../invoice-math.js';
test('discount plus negative adjustment cannot create negative service lines',()=>{
 const t=invoiceTotals([{quantity:'1',unit_rate:'.01',tax_rate:'100'},{quantity:'1',unit_rate:'.01',tax_rate:'0'}],'.01','-.01');
 assert.deepEqual(t.rows,[{net:'0.00',tax:'0.00'},{net:'0.00',tax:'0.00'}]);assert.equal(t.total,'0.00');
});
test('mixed VAT invoice allocates discounts and adjustments exactly',()=>{
 const t=invoiceTotals([{quantity:'2',unit_rate:'800',tax_rate:'5'},{quantity:'1',unit_rate:'100',tax_rate:'0'}],'170','0');
 assert.equal(t.net,'1530.00');assert.equal(t.tax,'72.00');assert.equal(t.total,'1602.00');
 const a=invoiceTotals([{quantity:'2',unit_rate:'600',tax_rate:'5'},{quantity:'1',unit_rate:'300',tax_rate:'5'}],'100','20');
 assert.equal(a.total,'1491.00');assert.equal(a.tax,'71.00');
});
test('fractional discount cents are allocated once and invalid totals rejected',()=>{
 const t=invoiceTotals([{quantity:'1',unit_rate:'.01',tax_rate:'0'},{quantity:'1',unit_rate:'.01',tax_rate:'0'},{quantity:'1',unit_rate:'.01',tax_rate:'0'}],'.01');
 assert.equal(t.total,'0.02');assert.deepEqual(t.rows.map(r=>r.net),['0.01','0.00','0.01']);
 assert.throws(()=>invoiceTotals([{quantity:'1',unit_rate:'10',tax_rate:'5'}],'11'));
 assert.throws(()=>invoiceTotals([{quantity:'1',unit_rate:'10',tax_rate:'101'}]));
});
