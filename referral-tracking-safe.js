(()=>{
  'use strict';
  if(window.__mxReferralTrackingInstalled)return;
  window.__mxReferralTrackingInstalled=true;

  const REF_PATTERN=/^[0-9a-f]{20}$/i;
  const OMLIG_URL='https://www.omlig.com/mx-business-card/';
  const codeCache=new Map();

  const currentCard=()=>{
    try{return typeof state!=='undefined'?state.publicCard:null}catch{return null}
  };

  async function referralCodeFor(card){
    if(!card?.id)return '';
    const embedded=String(card.referral_code||'').trim().toLowerCase();
    if(REF_PATTERN.test(embedded))return embedded;
    if(codeCache.has(card.id))return codeCache.get(card.id)||'';
    try{
      if(typeof db==='undefined')return '';
      const {data,error}=await db.from('digital_cards').select('referral_code').eq('id',card.id).eq('status','published').maybeSingle();
      if(error)return '';
      const code=String(data?.referral_code||'').trim().toLowerCase();
      codeCache.set(card.id,REF_PATTERN.test(code)?code:'');
      return REF_PATTERN.test(code)?code:'';
    }catch{return ''}
  }

  async function apply(){
    const card=currentCard();
    const note=document.querySelector('.public-note');
    if(!card||!note)return;
    const code=await referralCodeFor(card);
    const url=new URL(OMLIG_URL);
    if(code){
      url.searchParams.set('ref',code);
      url.searchParams.set('utm_source','mx_business_card');
      url.searchParams.set('utm_medium','referral');
    }
    let link=note.querySelector(':scope > a[data-mx-referral-link]');
    if(!link){
      note.textContent='';
      link=document.createElement('a');
      link.dataset.mxReferralLink='1';
      link.textContent='MX Business Card';
      link.target='_blank';
      link.rel='noopener noreferrer';
      link.style.cssText='color:inherit;text-decoration:none;';
      link.addEventListener('click',()=>{
        try{if(typeof trackPublicClick==='function')trackPublicClick('referral_click')}catch{}
      });
      note.appendChild(link);
    }
    if(link.href!==url.href)link.href=url.href;
  }

  void apply();
  let scheduled=false;
  new MutationObserver(()=>{
    if(scheduled)return;
    scheduled=true;
    requestAnimationFrame(()=>{scheduled=false;void apply();});
  }).observe(document.documentElement,{childList:true,subtree:true});
})();
