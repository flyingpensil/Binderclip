// Substring search with * / % (any text) and ? / _ (one character).
// Greedy wildcard matching avoids constructing regular expressions from user input.
export function wildcardMatch(value,query=''){
 const text=String(value??'').toLowerCase(),pattern='*'+String(query).trim().toLowerCase().replaceAll('%','*').replaceAll('_','?')+'*';
 let i=0,j=0,star=-1,mark=0;
 while(i<text.length){if(pattern[j]==='?'||pattern[j]===text[i]){i++;j++;}else if(pattern[j]==='*'){star=j++;mark=i;}else if(star>=0){j=star+1;i=++mark;}else return false;}
 while(pattern[j]==='*')j++;return j===pattern.length;
}
