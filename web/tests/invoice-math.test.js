import test from 'node:test';
import assert from 'node:assert/strict';
import {invoiceTotals} from '../invoice-math.js';
test('discount plus negative adjustment cannot create negative service lines',()=>{
 const t=invoiceTotals([{quantity:'1',unit_rate:'.01',tax_rate:'100'},{quantity:'1',unit_rate:'.01',tax_rate:'0'}],'.01','-.01');
 assert.deepEqual(t.rows,[{net:'0.00',tax:'0.00'},{net:'0.00',tax:'0.00'}]);assert.equal(t.total,'0.00');
});
test('small-cent discounts and negative adjustments conserve value without credit lines',()=>{
 const cents=value=>(value/100).toFixed(2);
 for(let first=1;first<=5;first++)for(let second=1;second<=5;second++)for(let discount=0;discount<=first+second;discount++)for(let reduction=0;reduction<=first+second-discount;reduction++){
  const t=invoiceTotals([{quantity:'1',unit_rate:cents(first),tax_rate:'5'},{quantity:'1',unit_rate:cents(second),tax_rate:'0'}],cents(discount),cents(-reduction));
  assert.equal(t.net,cents(first+second-discount-reduction));assert.ok(t.rows.every(row=>!row.net.startsWith('-')&&!row.tax.startsWith('-')));
 }
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
