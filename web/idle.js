export const IDLE_LIMIT=2*60*60*1000;
export function createIdleSession({storage,now=()=>Date.now(),onTimeout,onActivity,interval=setInterval,clear=clearInterval}){
 let active=false,last=0,lastSent=0,timer=null;const key='binderclip.lastActivity';
 function expire(){if(!active)return false;active=false;if(timer!==null)clear(timer);storage.removeItem(key);onTimeout();return false;}
 function check(){if(!active)return true;if(now()-last>=IDLE_LIMIT)return expire();return true;}
 function activity(){if(!active||!check())return;last=now();storage.setItem(key,String(last));if(now()-lastSent>=60000){lastSent=now();Promise.resolve(onActivity()).catch(()=>{});}}
 return {start(){if(timer!==null)clear(timer);last=Number(storage.getItem(key))||now();lastSent=0;active=true;if(check())timer=interval(check,15000);},stop(){active=false;if(timer!==null)clear(timer);timer=null;storage.removeItem(key);},check,activity};
}
