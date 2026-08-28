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

      .mx-heading-with-brand{display:grid!important;grid-template-columns:auto minmax(0,1fr);grid-template-rows:auto auto;column-gap:18px;row-gap:0;align-items:center;justify-content:start}
      .mx-heading-with-brand>.mx-inline-brand{grid-column:1;grid-row:1 / span 2;align-self:center;display:flex;align-items:center;justify-content:flex-start;min-width:225px}
      .mx-heading-with-brand>.mx-inline-brand img{display:block;width:220px;height:58px;object-fit:contain;object-position:left center}
      .mx-heading-with-brand>h1{grid-column:2;grid-row:1;margin-bottom:0!important;align-self:end}
      .mx-heading-with-brand>h1+p{grid-column:2;grid-row:2;align-self:start;margin-top:3px!important}
      .mx-heading-with-brand>.mx-brand-replaced-icon{display:none!important}

      @media(max-width:950px){
        .brand.mx-brand-official .mx-brand-mark{font-size:27px;min-width:62px}
        .mx-heading-with-brand{column-gap:12px}
        .mx-heading-with-brand>.mx-inline-brand{min-width:175px}
        .mx-heading-with-brand>.mx-inline-brand img{width:170px;height:50px}
      }
      @media(max-width:700px){
        .mx-heading-with-brand{grid-template-columns:1fr;grid-template-rows:auto auto auto;row-gap:4px}
        .mx-heading-with-brand>.mx-inline-brand{grid-column:1;grid-row:1;min-width:0}
        .mx-heading-with-brand>.mx-inline-brand img{width:180px;height:48px}
        .mx-heading-with-brand>h1{grid-column:1;grid-row:2}
        .mx-heading-with-brand>h1+p{grid-column:1;grid-row:3}
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

  const visibleHeading=()=>{
    const main=document.querySelector('.main');
    if(!main)return null;
    return [...main.querySelectorAll('h1')].find(h=>{
      const r=h.getBoundingClientRect();
      return r.width>0&&r.height>0&&r.top<260&&r.bottom>0;
    })||null;
  };

  const applyHeader=()=>{
    document.querySelectorAll('.mx-top-brand').forEach(el=>el.remove());
    const heading=visibleHeading();
    if(!heading)return;
    const block=heading.parentElement;
    if(!block)return;
    block.classList.add('mx-heading-with-brand');

    [...block.children].forEach(el=>{
      if(el===heading||el.classList.contains('mx-inline-brand')||el.tagName==='P')return;
      if(el.querySelector('button,a,input,select,textarea'))return;
      const r=el.getBoundingClientRect();
      if(r.width>0&&r.width<=150&&r.height>0&&r.height<=150)el.classList.add('mx-brand-replaced-icon');
    });

    let logo=block.querySelector(':scope > .mx-inline-brand');
    if(!logo){
      logo=document.createElement('div');
      logo.className='mx-inline-brand';
      logo.innerHTML='<img src="/mx-business-card-logo.svg?v=mx-gold-native-20260828-1" alt="MX Business Card">';
      block.insertBefore(logo,heading);
    }
  };

  const apply=()=>{applySidebar();applyHeader();};
  installStyles();
  apply();
  new MutationObserver(apply).observe(document.documentElement,{childList:true,subtree:true});
})();
