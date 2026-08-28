(()=>{
  'use strict';
  if(window.__mxBrandSafeInstalled)return;
  window.__mxBrandSafeInstalled=true;

  const installStyles=()=>{
    if(document.getElementById('mx-brand-safe-styles'))return;
    const style=document.createElement('style');
    style.id='mx-brand-safe-styles';
    style.textContent=`
      .brand.mx-brand-official{padding:2px 8px 22px;min-height:58px;display:flex;align-items:center;justify-content:center}
      .brand.mx-brand-official .mx-brand-mark{font-weight:900;font-size:31px;letter-spacing:-3px;line-height:1;display:flex;align-items:center;gap:1px;text-shadow:0 1px 8px rgba(0,0,0,.18)}
      .brand.mx-brand-official .mx-brand-m{background:linear-gradient(180deg,#58a7ff 0%,#1977d4 48%,#074d9c 100%);-webkit-background-clip:text;background-clip:text;color:transparent}
      .brand.mx-brand-official .mx-brand-x{background:linear-gradient(180deg,#ffe08a 0%,#f6b733 48%,#c7830c 100%);-webkit-background-clip:text;background-clip:text;color:transparent}
      .mx-top-brand{display:flex;align-items:center;gap:14px;margin-right:auto;min-width:260px}
      .mx-top-brand-card{display:flex;align-items:center;background:#fff;border:1px solid #e2e7f0;border-radius:14px;padding:8px 14px;box-shadow:0 4px 16px rgba(16,24,40,.07)}
      .mx-top-brand-logo{display:block;width:250px;max-width:30vw;height:64px;object-fit:contain}
      @media(max-width:950px){
        .brand.mx-brand-official{padding:2px 3px 22px}
        .brand.mx-brand-official .mx-brand-mark{font-size:27px}
        .mx-top-brand{min-width:0}
        .mx-top-brand-logo{width:210px;max-width:32vw;height:56px}
      }
      @media(max-width:700px){
        .mx-top-brand{width:100%;order:-1}
        .mx-top-brand-card{width:100%;justify-content:center;padding:7px 10px}
        .mx-top-brand-logo{width:220px;max-width:80vw;height:54px}
      }
    `;
    document.head.appendChild(style);
  };

  const applySidebar=()=>{
    const brand=document.querySelector('.side .brand');
    if(!brand)return;
    brand.classList.add('mx-brand-official');
    if(!brand.querySelector('.mx-brand-mark')) brand.innerHTML='<span class="mx-brand-mark" aria-label="MX"><span class="mx-brand-m">M</span><span class="mx-brand-x">X</span></span>';
  };

  const applyHeader=()=>{
    const top=document.querySelector('.main .top');
    if(!top||top.querySelector('.mx-top-brand'))return;
    const holder=document.createElement('div');
    holder.className='mx-top-brand';
    holder.innerHTML='<div class="mx-top-brand-card"><img class="mx-top-brand-logo" src="/mx-business-card-logo.svg?v=mx-gold-20260828-2" alt="MX Business Card"></div>';
    top.insertBefore(holder,top.firstChild);
  };

  const apply=()=>{applySidebar();applyHeader();};
  installStyles();
  apply();
  new MutationObserver(apply).observe(document.documentElement,{childList:true,subtree:true});
})();
