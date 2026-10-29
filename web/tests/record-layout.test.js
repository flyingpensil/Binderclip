import test from 'node:test';
import assert from 'node:assert/strict';
import {JSDOM} from 'jsdom';
import {arrangeRecord} from '../record-layout.js';

test('document header and item tabs retain forms, actions and selection after saving',()=>{
 const dom=new JSDOM('<main id="screen"></main>'),old=globalThis.document;globalThis.document=dom.window.document;
 try{
  const root=document.getElementById('screen'),markup='<details class="record-tracking"><summary>Entry history</summary></details><div class="page-heading"><h1>JOB-1</h1><button data-do="edit-job">Edit job</button></div><section class="panel"><h2>Shipment details</h2><form id="status-form"><input name="status" value="Delivered"></form></section><section class="panel"><h2>Job cost sheet</h2><button data-do="approve">Approve</button></section><section class="panel"><h2>Attachments</h2><button data-do="attachment-upload">Upload</button></section>';
  root.innerHTML=markup;const form=document.getElementById('status-form'),snapshot={row:{number:'JOB-1',status:'Booked',customer:{name:'Customer'},data:{client_reference:'PO-1'}}};
  arrangeRecord(root,{page:'job',id:'1',company:'c',snapshot});assert.equal(root.querySelector('.record-header h1').textContent,'JOB-1');assert.match(root.querySelector('.record-facts').textContent,/PO-1/);assert.equal(document.getElementById('status-form'),form);
  const tab=label=>[...root.querySelectorAll('[role=tab]')].find(x=>x.textContent===label);
  assert.equal(tab('Details').getAttribute('aria-selected'),'true');tab('Attachments').click();assert.equal(tab('Attachments').getAttribute('aria-selected'),'true');assert.equal(root.querySelector('[data-do=attachment-upload]').closest('[role=tabpanel]').hidden,false);assert.equal(form.closest('[role=tabpanel]').hidden,true);
  root.innerHTML=markup;arrangeRecord(root,{page:'job',id:'1',company:'c',snapshot});assert.equal(tab('Attachments').getAttribute('aria-selected'),'true');assert.equal(root.querySelectorAll('[role=tabpanel]:not([hidden])').length,1);
  tab('Attachments').dispatchEvent(new dom.window.KeyboardEvent('keydown',{key:'Home',bubbles:true}));assert.equal(tab('Details').getAttribute('aria-selected'),'true');assert.equal(document.activeElement,tab('Details'));
  root.innerHTML=markup;arrangeRecord(root,{page:'job',id:'2',company:'c',snapshot});assert.equal(tab('Details').getAttribute('aria-selected'),'true');
 }finally{globalThis.document=old;dom.window.close();}
});
test('invoice preview remains intact and payment controls have their own tab',()=>{
 const dom=new JSDOM('<main><div class="page-heading"><h1>INV-1</h1></div><section class="panel invoice-paper"><h2>Legal company</h2><table><tr><td>Freight</td></tr></table></section><section class="panel"><h2>Payments</h2><button>Record payment</button></section></main>'),old=globalThis.document;globalThis.document=dom.window.document;
 try{const root=document.querySelector('main');arrangeRecord(root,{page:'invoice',id:'1',company:'c',snapshot:{row:{number:'INV-1',currency:'AED',total:'105',paid:'0',snapshot:{customer:{name:'Client'}}}}});assert.ok(root.querySelector('.invoice-paper table'));assert.match(root.querySelector('.record-chips').textContent,/105.00/);assert.deepEqual([...root.querySelectorAll('[role=tab]')].map(x=>x.textContent),['Invoice','Payments']);}finally{globalThis.document=old;dom.window.close();}
});
