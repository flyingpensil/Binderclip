import test from 'node:test';
import assert from 'node:assert/strict';
import {JSDOM} from 'jsdom';
import {createIdleSession,IDLE_LIMIT} from '../idle.js';
import {wildcardMatch} from '../search.js';

test('idle expiry uses human activity, survives reload and cannot be revived after expiry',()=>{
 let time=1000,expired=0,heartbeats=0,tick;const values=new Map();
 const storage={getItem:k=>values.get(k),setItem:(k,v)=>values.set(k,v),removeItem:k=>values.delete(k)};
 const options={storage,now:()=>time,onTimeout:()=>expired++,onActivity:()=>heartbeats++,interval:fn=>(tick=fn,1),clear:()=>{}};
 const first=createIdleSession(options);first.start();time+=IDLE_LIMIT-1;tick();assert.equal(expired,0);
 first.activity();assert.equal(heartbeats,1);time+=IDLE_LIMIT-1;tick();assert.equal(expired,0);
 const reloaded=createIdleSession(options);time+=1;reloaded.start();assert.equal(expired,1);
 reloaded.activity();assert.equal(heartbeats,1);assert.equal(values.size,0);
});
test('wildcards support partial, case insensitive, single character and SQL notation',()=>{
 for(const query of ['ocean','O*car','O?ean','%carrier','O_ean','*',''])assert.equal(wildcardMatch('Ocean Carrier',query),true,query);
 for(const query of ['Air*','[Ocean]','O??n'])assert.equal(wildcardMatch('Ocean Carrier',query),false,query);
});
test('supplier picker searches and preserves several selected suppliers in FormData',async()=>{
 const dom=new JSDOM('<form></form>');const previous=globalThis.document;globalThis.document=dom.window.document;
 try{const {multiPicker}=await import('../pickers.js');document.querySelector('form').innerHTML=multiPicker('suppliers','Suppliers',[{id:'a',name:'Ocean Carrier'},{id:'b',name:'Customs Broker'}],['a']);
 const search=document.querySelector('[type=search]');search.value='C*Broker';search.dispatchEvent(new dom.window.Event('input',{bubbles:true}));
 const enter=new dom.window.KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true});search.dispatchEvent(enter);assert.equal(enter.defaultPrevented,true);
 assert.equal(document.querySelector('.picker-option').hidden,true);const box=document.querySelector('[value=b]');box.checked=true;box.dispatchEvent(new dom.window.Event('change',{bubbles:true}));
 assert.deepEqual(new dom.window.FormData(document.querySelector('form')).getAll('suppliers'),['a','b']);assert.equal(document.querySelector('[data-selection-count]').textContent,'2 selected');
 }finally{globalThis.document=previous;dom.window.close();}
});
