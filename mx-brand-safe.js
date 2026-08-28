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
      .brand.mx-brand-official .mx-brand-mark{font-weight:900;font-size:31px;letter-spacing:-1px;line-height:1;display:flex;align-items:center;gap:2px;min-width:76px;padding:2px 7px 3px;justify-content:center;overflow:visible;text-shadow:0 1px 8px rgba(0,0,0,.18)}
      .brand.mx-brand-official .mx-brand-m{display:inline-block;background:linear-gradient(180deg,#58a7ff 0%,#1977d4 48%,#074d9c 100%);-webkit-background-clip:text;background-clip:text;color:transparent}
      .brand.mx-brand-official .mx-brand-x{display:inline-block;padding-right:3px;background:linear-gradient(180deg,#ffe08a 0%,#f6b733 48%,#c7830c 100%);-webkit-background-clip:text;background-clip:text;color:transparent}

      .main.mx-brand-main{position:relative}
      .main>.mx-main-brand{position:absolute;top:24px;left:200px;z-index:2;display:flex;align-items:center;pointer-events:none;background:transparent;border:0;box-shadow:none;padding:0;margin:0}
      .main>.mx-main-brand img{display:block;width:285px;height:68px;object-fit:contain;object-position:left center}

      @media(max-width:1200px){
        .main>.mx-main-brand{left:150px}
        .main>.mx-main-brand img{width:240px;height:60px}
      }
      @media(max-width:950px){
        .brand.mx-brand-official .mx-brand-mark{font-size:27px;min-width:62px}
        .main>.mx-main-brand{left:120px;top:22px}
        .main>.mx-main-brand img{width:205px;height:54px}
      }
      @media(max-width:700px){
        .main>.mx-main-brand{position:relative;top:auto;left:auto;margin:0 0 12px 0;width:100%;justify-content:flex-start}
        .main>.mx-main-brand img{width:190px;height:50px}
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

  const cleanupOld=()=>{
    document.querySelectorAll('.mx-top-brand,.mx-inline-brand').forEach(el=>el.remove());
    document.querySelectorAll('.mx-heading-with-brand').forEach(el=>el.classList.remove('mx-heading-with-brand'));
    document.querySelectorAll('.mx-brand-replaced-icon').forEach(el=>el.classList.remove('mx-brand-replaced-icon'));
  };

  const applyMainBrand=()=>{
    const main=document.querySelector('.main');
    if(!main)return;
    main.classList.add('mx-brand-main');
    let holder=main.querySelector(':scope > .mx-main-brand');
    if(!holder){
      holder=document.createElement('div');
      holder.className='mx-main-brand';
      holder.innerHTML='<img src="/mx-business-card-logo.svg?v=mx-gold-main-20260828-1" alt="MX Business Card">';
      main.insertBefore(holder,main.firstChild);
    }
  };

  const apply=()=>{cleanupOld();applySidebar();applyMainBrand();};
  installStyles();
  apply();
  new MutationObserver(apply).observe(document.documentElement,{childList:true,subtree:true});
})();
