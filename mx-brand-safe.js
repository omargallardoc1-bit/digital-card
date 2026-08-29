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

      .admin-header{min-height:104px;padding-top:16px!important;padding-bottom:16px!important;align-items:center!important}
      .admin-header .admin-heading.mx-admin-heading-branded{display:grid;grid-template-columns:190px minmax(0,1fr);grid-template-rows:auto auto;column-gap:16px;row-gap:2px;align-items:center;min-width:0}
      .admin-header .admin-heading.mx-admin-heading-branded .mx-admin-logo{grid-column:1;grid-row:1 / span 2;display:flex;align-items:center;justify-content:flex-start;min-width:0}
      .admin-header .admin-heading.mx-admin-heading-branded .mx-admin-logo img{display:block;width:185px;height:52px;object-fit:contain;object-position:left center}
      .admin-header .admin-heading.mx-admin-heading-branded>strong{grid-column:2;grid-row:1;align-self:end;margin:0!important;line-height:1.15}
      .admin-header .admin-heading.mx-admin-heading-branded>span:not(.mobile-header-mark):not(.mx-admin-logo){grid-column:2;grid-row:2;align-self:start;margin:0!important;line-height:1.2}
      .admin-header .admin-heading.mx-admin-heading-branded>.mobile-header-mark{display:none!important}
      .admin-header .admin-tools{align-self:center}

      @media(max-width:1150px){
        .admin-header .admin-heading.mx-admin-heading-branded{grid-template-columns:165px minmax(0,1fr);column-gap:12px}
        .admin-header .admin-heading.mx-admin-heading-branded .mx-admin-logo img{width:160px;height:48px}
      }
      @media(max-width:900px){
        .admin-header{min-height:92px}
        .admin-header .admin-heading.mx-admin-heading-branded{grid-template-columns:138px minmax(0,1fr)}
        .admin-header .admin-heading.mx-admin-heading-branded .mx-admin-logo img{width:134px;height:42px}
      }
      @media(max-width:800px){
        .admin-header{min-height:unset;padding-top:12px!important;padding-bottom:12px!important}
        .admin-header .admin-heading.mx-admin-heading-branded .mx-admin-logo{display:none}
        .admin-header .admin-heading.mx-admin-heading-branded{display:block}
      }
    `;
    document.head.appendChild(style);
  };

  const sidebarMarkup='<span class="mx-brand-mark" aria-label="MX"><span class="mx-brand-m">M</span><span class="mx-brand-x">X</span></span>';

  const applySidebar=()=>{
    const brand=document.querySelector('.side .brand');
    if(!brand)return;
    if(brand.classList.contains('mx-brand-official')&&brand.querySelector('.mx-brand-mark'))return;
    brand.classList.add('mx-brand-official');
    brand.innerHTML=sidebarMarkup;
  };

  const applyAdminHeader=()=>{
    const heading=document.querySelector('.admin-header .admin-heading');
    if(!heading)return;
    if(!heading.classList.contains('mx-admin-heading-branded'))heading.classList.add('mx-admin-heading-branded');
    if(heading.querySelector(':scope > .mx-admin-logo'))return;
    const logo=document.createElement('span');
    logo.className='mx-admin-logo';
    logo.innerHTML='<img src="/mx-business-card-logo.svg?v=mx-admin-stable-20260828-2" alt="MX Business Card">';
    heading.insertBefore(logo,heading.firstChild);
  };

  const apply=()=>{applySidebar();applyAdminHeader();};
  installStyles();
  apply();
  let scheduled=false;
  const observer=new MutationObserver(()=>{
    if(scheduled)return;
    scheduled=true;
    requestAnimationFrame(()=>{scheduled=false;apply();});
  });
  observer.observe(document.documentElement,{childList:true,subtree:true});
})();
