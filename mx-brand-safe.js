(()=>{
  'use strict';
  if(window.__mxBrandSafeInstalled)return;
  window.__mxBrandSafeInstalled=true;

  const installStyles=()=>{
    if(document.getElementById('mx-brand-safe-styles'))return;
    const style=document.createElement('style');
    style.id='mx-brand-safe-styles';
    style.textContent=`
      .brand.mx-brand-official{padding:2px 8px 24px;min-height:64px;display:flex;align-items:center;overflow:hidden}
      .brand.mx-brand-official .mx-brand-logo{display:block;width:190px;max-width:100%;height:auto;filter:drop-shadow(0 2px 5px rgba(0,0,0,.24))}
      @media(max-width:950px){
        .brand.mx-brand-official{padding:2px 3px 24px;justify-content:center}
        .brand.mx-brand-official .mx-brand-logo{width:52px;height:52px;object-fit:cover;object-position:left top;clip-path:inset(0 0 0 0)}
      }
    `;
    document.head.appendChild(style);
  };

  const apply=()=>{
    const brand=document.querySelector('.side .brand');
    if(!brand||brand.classList.contains('mx-brand-official'))return;
    brand.classList.add('mx-brand-official');
    brand.innerHTML='<img class="mx-brand-logo" src="/mx-business-card-logo.svg" alt="MX Business Card">';
  };

  installStyles();
  apply();
  new MutationObserver(apply).observe(document.documentElement,{childList:true,subtree:true});
})();
