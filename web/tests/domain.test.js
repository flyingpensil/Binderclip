import test from 'node:test';
import assert from 'node:assert/strict';
import {scaled, decimal, money, balance, lineAmount, permitted, csv, validateConfig, escapeHTML} from '../domain.js';

test('money stays exact above JavaScript safe integer and rounds half away from zero',()=>{
  assert.equal(money('9007199254740993.015'),'9,007,199,254,740,993.02');
  assert.equal(decimal(scaled('-1.005')),'-1.01');
  assert.equal(balance({total:'1680.00',paid:'600.01'}),'1079.99');
  assert.equal(lineAmount({quantity:'1.125',unit_rate:'10.00'}),'11.25');
  assert.throws(()=>scaled('1e10'));
});
test('exports require an export grant and CSV blocks spreadsheet formulas',()=>{
  const grant={path:'customers.ledger.view',action:'X',scope:'branch',can_export:false};
  assert.equal(permitted([grant],grant.path,'X'),false);
  assert.equal(permitted([{...grant,can_export:true}],grant.path,'X'),true);
  assert.equal(permitted([{...grant,scope:'none',can_export:true}],grant.path,'X'),false);
  assert.match(csv([[' =HYPERLINK("bad")']]),/"' =HYPERLINK/);
  assert.equal(escapeHTML('<script>"&'), '&lt;script&gt;&quot;&amp;');
});
test('website config rejects service credentials and unrelated endpoints',()=>{
  const cfg={url:'https://project.supabase.co',publishableKey:'sb_publishable_example'};
  assert.equal(validateConfig(cfg).url,cfg.url);
  for(const value of [{...cfg,publishableKey:'sb_secret_no'},{...cfg,publishableKey:'eyJhbGciOi'},{...cfg,url:'https://supabase.co.evil.test'}, {...cfg,url:'http://project.supabase.co'}, {...cfg,url:'https://project.supabase.co/path'}])assert.throws(()=>validateConfig(value));
});
