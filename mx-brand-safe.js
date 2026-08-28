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

      .admin-header .admin-heading.mx-admin-heading-branded{display:grid;grid-template-columns:auto minmax(0,1fr);grid-template-rows:auto auto;column-gap:18px;align-items:center}
      .admin-header .admin-heading.mx-admin-heading-branded .mx-admin-logo{grid-column:1;grid-row:1 / span 2;display:flex;align-items:center}
      .admin-header .admin-heading.mx-admin-heading-branded .mx-admin-logo img{display:block;width:230px;height:58px;object-fit:contain;object-position:left center}
      .admin-header .admin-heading.mx-admin-heading-branded>strong{grid-column:2;grid-row:1;align-self:end}
      .admin-header .admin-heading.mx-admin-heading-branded>span:not(.mobile-header-mark){grid-column:2;grid-row:2;align-self:start}
      .admin-header .admin-heading.mx-admin-heading-branded>.mobile-header-mark{display:none!important}

      @media(max-width:1100px){
        .admin-header .admin-heading.mx-admin-heading-branded{column-gap:12px}
        .admin-header .admin-heading.mx-admin-heading-branded .mx-admin-logo img{width:190px;height:52px}
      }
      @media(max-width:800px){
        .admin-header .admin-heading.mx-admin-heading-branded .mx-admin-logo{display:none}
        .admin-header .admin-heading.mx-admin-heading-branded{display:block}
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

  const applyAdminHeader=()=>{
    document.querySelectorAll('.mx-top-brand,.mx-main-brand,.mx-inline-brand').forEach(el=>el.remove());
    const heading=document.querySelector('.admin-header .admin-heading');
    if(!heading)return;
    heading.classList.add('mx-admin-heading-branded');
    let logo=heading.querySelector(':scope > .mx-admin-logo');
    if(!logo){
      logo=document.createElement('span');
      logo.className='mx-admin-logo';
      logo.innerHTML='<img src="/mx-business-card-logo.svg?v=mx-admin-native-20260828-1" alt="MX Business Card">';
      heading.insertBefore(logo,heading.firstChild);
    }
  };

  const apply=()=>{applySidebar();applyAdminHeader();};
  installStyles();
  apply();
  new MutationObserver(apply).observe(document.documentElement,{childList:true,subtree:true});
})();
