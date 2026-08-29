(()=>{
  'use strict';
  if(window.__mxRewardsMobileFixInstalled)return;
  window.__mxRewardsMobileFixInstalled=true;

  const style=document.createElement('style');
  style.id='mx-rewards-mobile-fix-style';
  style.textContent=`
    .mx-rewards-mobile-cta{display:none}
    @media(max-width:950px){
      .nav button[data-mx-rewards-nav]{display:none!important}
      .mx-rewards-mobile-cta{
        position:fixed;
        left:50%;
        bottom:78px;
        transform:translateX(-50%);
        z-index:80;
        display:flex;
        align-items:center;
        justify-content:center;
        gap:8px;
        min-width:168px;
        max-width:calc(100vw - 32px);
        padding:11px 18px;
        border:1px solid rgba(79,70,229,.22);
        border-radius:999px;
        background:#fff;
        color:#3027a8;
        font-weight:800;
        box-shadow:0 10px 28px rgba(16,24,40,.18);
      }
      .mx-rewards-mobile-cta.active{background:#4f46e5;color:#fff}
    }
  `;
  document.head.appendChild(style);

  const stateSafe=()=>{try{return typeof state!=='undefined'?state:null}catch{return null}};
  const label=()=>{try{return typeof language!=='undefined'&&language==='en'?'Rewards':'Recompensas'}catch{return 'Recompensas'}};
  const install=()=>{
    if(!document.querySelector('.app')||document.querySelector('.mx-rewards-mobile-cta'))return;
    const button=document.createElement('button');
    button.type='button';
    button.className='mx-rewards-mobile-cta';
    button.setAttribute('aria-label',label());
    button.innerHTML=`<span aria-hidden="true">★</span><span>${label()}</span>`;
    button.addEventListener('click',()=>{if(typeof window.go==='function')window.go('rewards')});
    document.body.appendChild(button);
  };
  const refresh=()=>{
    install();
    const button=document.querySelector('.mx-rewards-mobile-cta');
    if(!button)return;
    button.classList.toggle('active',stateSafe()?.page==='rewards');
    button.querySelector('span:last-child').textContent=label();
    button.setAttribute('aria-label',label());
  };
  refresh();
  let scheduled=false;
  new MutationObserver(()=>{
    if(scheduled)return;
    scheduled=true;
    requestAnimationFrame(()=>{scheduled=false;refresh()});
  }).observe(document.documentElement,{childList:true,subtree:true});
})();
