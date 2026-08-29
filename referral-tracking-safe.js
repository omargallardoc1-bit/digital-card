(()=>{
  'use strict';
  if(window.__mxReferralTrackingInstalled)return;
  window.__mxReferralTrackingInstalled=true;

  const SUPABASE_URL='https://loovwrnifdimlwpfgjza.supabase.co';
  const SUPABASE_PUBLISHABLE_KEY='sb_publishable_eP8FFThBgpS4ox4tlP40Lg_8Y51C9sR';
  const OMLIG_URL='https://www.omlig.com/mx-business-card/';
  const REF_PATTERN=/^[0-9a-f]{20}$/i;
  let resolvedCard=null;

  function slugFromLocation(){
    try{return decodeURIComponent(location.pathname.replace(/^\/c\/?/,'')).split('/')[0]||''}catch{return ''}
  }

  async function resolveCard(){
    if(resolvedCard)return resolvedCard;
    const slug=slugFromLocation();
    if(!slug)return null;
    try{
      const url=new URL(SUPABASE_URL+'/rest/v1/digital_cards');
      url.searchParams.set('select','id,referral_code');
      url.searchParams.set('slug','eq.'+slug);
      url.searchParams.set('status','eq.published');
      url.searchParams.set('limit','1');
      const response=await fetch(url,{headers:{apikey:SUPABASE_PUBLISHABLE_KEY,Authorization:'Bearer '+SUPABASE_PUBLISHABLE_KEY}});
      if(!response.ok)return null;
      const rows=await response.json();
      const row=Array.isArray(rows)?rows[0]:null;
      const code=String(row?.referral_code||'').trim().toLowerCase();
      if(!row?.id||!REF_PATTERN.test(code))return null;
      resolvedCard={id:String(row.id),referral_code:code};
      return resolvedCard;
    }catch{return null}
  }

  async function sendReferralClick(cardId){
    try{
      await fetch(SUPABASE_URL+'/rest/v1/rpc/track_public_referral_click',{
        method:'POST',
        headers:{'Content-Type':'application/json',apikey:SUPABASE_PUBLISHABLE_KEY,Authorization:'Bearer '+SUPABASE_PUBLISHABLE_KEY},
        body:JSON.stringify({target_card_id:cardId,event_source:new URLSearchParams(location.search).get('source')==='qr'?'qr':'public_card'}),
        keepalive:true
      });
    }catch{}
  }

  async function apply(){
    const note=document.querySelector('.public-note');
    if(!note)return;
    const card=await resolveCard();
    if(!card)return;
    const url=new URL(OMLIG_URL);
    url.searchParams.set('ref',card.referral_code);
    url.searchParams.set('utm_source','mx_business_card');
    url.searchParams.set('utm_medium','referral');

    let link=note.querySelector(':scope > a[data-mx-referral-link]');
    if(!link){
      note.textContent='';
      link=document.createElement('a');
      link.dataset.mxReferralLink='1';
      link.textContent='MX Business Card';
      link.target='_blank';
      link.rel='noopener noreferrer';
      link.style.cssText='color:inherit;text-decoration:none;';
      note.appendChild(link);
    }
    link.href=url.href;
    if(!link.dataset.mxReferralBound){
      link.dataset.mxReferralBound='1';
      link.addEventListener('click',()=>{void sendReferralClick(card.id)});
    }
  }

  void apply();
  let scheduled=false;
  new MutationObserver(()=>{
    if(scheduled)return;
    scheduled=true;
    requestAnimationFrame(()=>{scheduled=false;void apply();});
  }).observe(document.documentElement,{childList:true,subtree:true});
})();
