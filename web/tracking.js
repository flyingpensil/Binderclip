import {escapeHTML as h} from './domain.js';
let companyTimezone='Asia/Dubai';
export const setTrackingTimezone=value=>{companyTimezone=value;};
const date=value=>{if(!value)return 'Not recorded before tracking';const parsed=new Date(value);return Number.isNaN(parsed.valueOf())?'Not recorded':new Intl.DateTimeFormat('en-GB',{timeZone:companyTimezone,dateStyle:'medium',timeStyle:'short'}).format(parsed)+(companyTimezone==='Asia/Dubai'?' GST':' '+companyTimezone);};
export function tracking(row={}){return `<details class="record-tracking"><summary>Entry history</summary><dl><dt>Created by</dt><dd>${h(row.created_by_name||(row.created_by?'Earlier company member':'Not recorded before tracking'))}</dd><dt>Created date</dt><dd>${h(date(row.created_at))}</dd><dt>Updated by</dt><dd>${h(row.updated_by_name||(row.updated_at?'Earlier company member':'No update recorded'))}</dd><dt>Updated date</dt><dd>${h(row.updated_at?date(row.updated_at):'No update recorded')}</dd></dl></details>`;}
