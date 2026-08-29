(()=>{
  'use strict';
  if(window.__mxReferralTrackingInstalled)return;
  window.__mxReferralTrackingInstalled=true;

  const REF_PATTERN=/^[0-9a-f]{20}$/i;
  const OMLIG_URL='https://www.omlig.com/mx-business-card/';

  const currentCard=()=>{
    try{return typeof state!=='undefined'?state.publicCard:null}catch{return null}
  };

  const apply=()=>{
    const card=currentCard();
    const note=document.querySelector('.public-note');
    if(!card||!note)return;
    const code=String(card.referral_code||'').trim().toLowerCase();
    const url=new URL(OMLIG_URL);
    if(REF_PATTERN.test(code)){
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
        if(typeof trackPublicClick==='function')trackPublicClick('referral_click');
      });
      note.appendChild(link);
    }
    if(link.href!==url.href)link.href=url.href;
  };

  apply();
  let scheduled=false;
  new MutationObserver(()=>{
    if(scheduled)return;
    scheduled=true;
    requestAnimationFrame(()=>{scheduled=false;apply();});
  }).observe(document.documentElement,{childList:true,subtree:true});
})();
