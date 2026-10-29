import {escapeHTML as h} from './domain.js';
import {wildcardMatch} from './search.js';
export function multiPicker(name,label,options,selected=[]){return `<details class="multi-picker" data-multi-picker><summary id="field-${h(name)}">${h(label)} <span data-selection-count>${selected.length?`${selected.length} selected`:'Choose options'}</span></summary><div class="picker-popup"><input type="search" class="picker-search" aria-label="Search ${h(label)}" placeholder="Search… use * or ?" autocomplete="off"><div class="picker-options">${options.map(o=>`<label class="picker-option"><input type="checkbox" name="${h(name)}" value="${h(o.id)}" ${selected.includes(o.id)?'checked':''}>${h(o.name)}</label>`).join('')}</div><p class="picker-empty" hidden>No matching options.</p></div></details>`;}
export function enhancePickers(root){
 for(const select of root.querySelectorAll('select:not([data-enhanced])')){
  if(!select.hasAttribute('data-searchable')&&select.options.length<10)continue;
  select.dataset.enhanced='true';const details=document.createElement('details');details.className='select-picker';
  const summary=document.createElement('summary');summary.textContent=select.selectedOptions[0]?.textContent||'Choose an option';
  const popup=document.createElement('div');popup.className='picker-popup';const search=document.createElement('input');search.type='search';search.className='picker-search';search.placeholder='Search… use * or ?';search.setAttribute('aria-label','Search '+(select.labels?.[0]?.textContent||select.name||'options'));
  select.before(details);details.append(summary,popup);popup.append(search,select);select.size=Math.min(7,Math.max(2,select.options.length));
  search.addEventListener('input',()=>{for(const option of select.options)option.hidden=!wildcardMatch(option.textContent,search.value);});
  select.addEventListener('change',()=>{summary.textContent=select.selectedOptions[0]?.textContent||'Choose an option';details.open=false;});
  select.addEventListener('invalid',()=>{details.open=true;});
  details.addEventListener('toggle',()=>{summary.textContent=select.selectedOptions[0]?.textContent||'Choose an option';if(details.open){search.value='';for(const option of select.options)option.hidden=false;search.focus();}});
 }
}
document.addEventListener('input',event=>{if(!event.target.matches('[data-multi-picker] .picker-search'))return;const picker=event.target.closest('[data-multi-picker]');let matches=0;for(const option of picker.querySelectorAll('.picker-option')){option.hidden=!wildcardMatch(option.textContent,event.target.value);if(!option.hidden)matches++;}picker.querySelector('.picker-empty').hidden=matches>0;});
document.addEventListener('change',event=>{const picker=event.target.closest('[data-multi-picker]');if(picker)picker.querySelector('[data-selection-count]').textContent=`${picker.querySelectorAll('input[type=checkbox]:checked').length} selected`;});

document.addEventListener('click',event=>{for(const picker of document.querySelectorAll('.multi-picker[open],.select-picker[open]'))if(!picker.contains(event.target))picker.open=false;});
document.addEventListener('keydown',event=>{if(event.key!=='Escape')return;const picker=event.target.closest('.multi-picker[open],.select-picker[open]');if(picker){event.preventDefault();picker.open=false;picker.querySelector('summary').focus();}});
