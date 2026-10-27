import test from 'node:test';
import assert from 'node:assert/strict';
import {JSDOM} from 'jsdom';
import {createNavigation} from '../navigation.js';
import {tracking} from '../tracking.js';

test('menu groups start collapsed, toggle accessibly and search restores manual state',()=>{
 const dom=new JSDOM('<nav></nav>',{url:'https://example.test/'}),target=dom.window.document.querySelector('nav');
 const nav=createNavigation(target,[['Overview','overview','view','◈'],['Global search','search','view','⌕'],['Jobs','jobs','jobs','▦'],['Forbidden','secret','secret','!']],[['Workspace',['overview','search']],['Operations',['jobs','secret']]],row=>row[2]!=='secret');
 const [workspace,operations]=target.querySelectorAll('.nav-group');
 assert.ok([...target.querySelectorAll('button')].every(b=>b.getAttribute('aria-expanded')==='false'));
 assert.ok(workspace.querySelector('.nav-group-body').hasAttribute('inert'));
 assert.equal(target.querySelector('[href="#secret"]'),null);
 workspace.querySelector('button').click();assert.equal(workspace.querySelector('button').getAttribute('aria-expanded'),'true');
 assert.equal(workspace.querySelector('.nav-group-body').hasAttribute('inert'),false);
 nav.search('jobs');assert.equal(workspace.hidden,true);assert.equal(operations.hidden,false);assert.equal(operations.querySelector('button').getAttribute('aria-expanded'),'true');
 nav.search('no such option');assert.equal(target.querySelector('.nav-no-results').hidden,false);
 nav.search('');assert.equal(workspace.hidden,false);assert.equal(workspace.querySelector('button').getAttribute('aria-expanded'),'true');assert.equal(operations.querySelector('button').getAttribute('aria-expanded'),'false');
 nav.active('job');assert.equal(target.querySelector('[href="#jobs"]').getAttribute('aria-current'),'page');
 assert.equal(operations.querySelector('button').getAttribute('aria-expanded'),'false');
});

test('entry tracking uses escaped names and Dubai time without inventing historical updates',()=>{
 const html=tracking({created_by_name:'<script>attack</script>',created_at:'2026-10-27T09:30:00Z',updated_by_name:'Manager',updated_at:'2026-10-27T10:45:00Z'});
 assert.ok(!html.includes('<script>'));assert.match(html,/13:30 GST/);assert.match(html,/14:45 GST/);
 assert.match(tracking({}),/Not recorded before tracking/);assert.match(tracking({}),/No update recorded/);
});
