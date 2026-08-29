(()=>{
  'use strict';
  if(window.__mxRewardsSubtleMobileInstalled)return;
  window.__mxRewardsSubtleMobileInstalled=true;
  const style=document.createElement('style');
  style.id='mx-rewards-subtle-mobile-style';
  style.textContent=`
    .mx-rewards-usage-link{display:none}
    @media(max-width:950px){
      .nav button[data-mx-rewards-nav],.mx-rewards-mobile-cta{display:none!important}
      .mx-rewards-usage-link{display:flex;align-items:center;justify-content:space-between;gap:10px;width:100%;margin-top:14px;padding:10px 0 0;border-top:1px solid var(--line);background:transparent;color:var(--text-secondary,#475467);font-size:13px;font-weight:600;text-align:left}
      .mx-rewards-usage-link .arrow{color:var(--muted,#667085);font-size:16px}
    }
  `;
  document.head.appendChild(style);
  const label=()=>{try{return typeof language!=='undefined'&&language==='en'?'View rewards':'Ver recompensas'}catch{return 'Ver recompensas'}};
  const install=()=>{
    document.querySelectorAll('.mx-rewards-mobile-cta').forEach(el=>el.remove());
    if(innerWidth>950)return;
    const main=document.querySelector('.main');
    if(!main||document.querySelector('.mx-rewards-usage-link'))return;
    const headings=[...main.querySelectorAll('h1,h2,h3')];
    const heading=headings.find(h=>/Uso contratado|Contracted usage/i.test((h.textContent||'').trim()));
    const panel=heading?.closest('.panel');
    if(!panel)return;
    const button=document.createElement('button');
    button.type='button';
    button.className='mx-rewards-usage-link';
    button.innerHTML=`<span>${label()}</span><span class="arrow" aria-hidden="true">›</span>`;
    button.addEventListener('click',()=>{if(typeof window.go==='function')window.go('rewards')});
    panel.appendChild(button);
  };
  install();
  let scheduled=false;
  new MutationObserver(()=>{if(scheduled)return;scheduled=true;requestAnimationFrame(()=>{scheduled=false;install()})}).observe(document.documentElement,{childList:true,subtree:true});
})();
