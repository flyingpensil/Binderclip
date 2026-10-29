import {scaled,decimal,lineAmount} from './domain.js';
const round=(a,b)=>a<0n?-((-a+b/2n)/b):(a+b/2n)/b;
export function invoiceTotals(lines,discount='0',adjustment='0'){
 const amounts=lines.map(l=>scaled(lineAmount(l))),gross=amounts.reduce((a,b)=>a+b,0n),d=scaled(discount||'0'),a=scaled(adjustment||'0');
 if(d<0n||d>gross||gross-d+a<0n||(gross===0n&&a!==0n))throw new Error('Check discount and adjustment. The invoice total cannot be negative.');
 let running=0n,lastD=0n,lastA=0n,tax=0n;
 const rows=lines.map((l,i)=>{running+=amounts[i];const cumD=gross?round(d*running,gross):0n,cumA=gross?(a<0n?round(a*(running-cumD),gross-d):round(a*running,gross)):0n,net=amounts[i]-(cumD-lastD)+(cumA-lastA);lastD=cumD;lastA=cumA;const rate=scaled(l.tax_rate||'0');if(rate<0n||rate>10000n)throw new Error('VAT must be between 0 and 100 percent.');const vat=round(net*rate,10000n);tax+=vat;return {net:decimal(net),tax:decimal(vat)};});
 const beforeTax=lines.reduce((sum,l,i)=>sum+round(amounts[i]*scaled(l.tax_rate||'0'),10000n),0n);
 return {gross:decimal(gross),beforeTotal:decimal(gross+beforeTax),discount:decimal(d),adjustment:decimal(a),net:decimal(gross-d+a),tax:decimal(tax),total:decimal(gross-d+a+tax),rows};
}
