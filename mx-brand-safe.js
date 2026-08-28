(()=>{
  'use strict';
  if(window.__mxBrandSafeInstalled)return;
  window.__mxBrandSafeInstalled=true;

  const installStyles=()=>{
    if(document.getElementById('mx-brand-safe-styles'))return;
    const style=document.createElement('style');
    style.id='mx-brand-safe-styles';
    style.textContent=`
      .brand.mx-brand-official{padding:2px 8px 22px;min-height:58px;display:flex;align-items:center;justify-content:center;overflow:visible}
      .brand.mx-brand-official .mx-brand-mark{font-weight:900;font-size:31px;letter-spacing:-1px;line-height:1;display:flex;align-items:center;gap:2px;min-width:72px;padding:2px 5px 3px;justify-content:center;overflow:visible;text-shadow:0 1px 8px rgba(0,0,0,.18)}
      .brand.mx-brand-official .mx-brand-m{display:inline-block;background:linear-gradient(180deg,#58a7ff 0%,#1977d4 48%,#074d9c 100%);-webkit-background-clip:text;background-clip:text;color:transparent}
      .brand.mx-brand-official .mx-brand-x{display:inline-block;padding-right:2px;background:linear-gradient(180deg,#ffe08a 0%,#f6b733 48%,#c7830c 100%);-webkit-background-clip:text;background-clip:text;color:transparent}
      .mx-top-brand{position:fixed;top:22px;z-index:19;display:flex;align-items:center;pointer-events:none}
      .mx-top-brand-card{display:flex;align-items:center;background:#fff;border:1px solid #e2e7f0;border-radius:14px;padding:7px 14px;box-shadow:0 4px 16px rgba(16,24,40,.07)}
      .mx-top-brand-logo{display:block;width:270px;height:66px;object-fit:contain}
      @media(max-width:950px){
        .brand.mx-brand-official .mx-brand-mark{font-size:27px;min-width:58px}
        .mx-top-brand-logo{width:220px;height:58px}
      }
      @media(max-width:700px){
        .mx-top-brand{top:10px;left:50%!important;transform:translateX(-50%)}
        .mx-top-brand-logo{width:190px;height:50px}
        .mx-top-brand-card{padding:5px 9px}
      }
    `;
    document.head.appendChild(style);
  };

  const applySidebar=()=>{
    const brand=document.querySelector('.side .brand');
    if(!brand)return;
    brand.classList.add('mx-brand-official');
    brand.innerHTML='<span class="mx-brand-mark" aria-label="MX"><span class="mx-brand-m">M</span><span class="mx-brand-x">X</span></span>';
  };

  const positionHeader=()=>{
    const holder=document.querySelector('.mx-top-brand');
    const side=document.querySelector('.side');
    if(!holder||!side||window.innerWidth<=700)return;
    const sideRight=Math.round(side.getBoundingClientRect().right);
    holder.style.left=`${sideRight+155}px`;
  };

  const applyHeader=()=>{
    if(!document.querySelector('.side'))return;
    let holder=document.querySelector('.mx-top-brand');
    if(!holder){
      holder=document.createElement('div');
      holder.className='mx-top-brand';
      holder.innerHTML='<div class="mx-top-brand-card"><img class="mx-top-brand-logo" src="/mx-business-card-logo.svg?v=mx-gold-20260828-3" alt="MX Business Card"></div>';
      document.body.appendChild(holder);
    }
    positionHeader();
  };

  const apply=()=>{applySidebar();applyHeader();};
  installStyles();
  apply();
  window.addEventListener('resize',positionHeader,{passive:true});
  new MutationObserver(apply).observe(document.documentElement,{childList:true,subtree:true});
})();
