(()=>{
  const style=document.createElement('style');
  style.id='mx-assisted-layout-fix';
  style.textContent=`
    #main{overflow:visible!important;min-width:0!important;padding-bottom:80px!important}
    #main .panel{min-width:0!important;overflow:visible!important}
    #main .edit-grid{display:grid!important;grid-template-columns:minmax(0,1fr) minmax(0,1fr)!important;gap:14px!important;align-items:start!important}
    #main .edit-grid>div{min-width:0!important}
    #main .edit-grid input,#main .edit-grid select,#main .edit-grid textarea{width:100%!important;max-width:100%!important;box-sizing:border-box!important}
    #main .edit-grid textarea{min-height:92px!important;resize:vertical!important}
    #main .edit-grid button[type="submit"]{grid-column:1/-1!important;width:100%!important;min-height:46px!important;margin-top:8px!important}
    @media(max-width:1180px){
      #main>div[style*="grid-template-columns:minmax(280px"]{grid-template-columns:1fr!important}
      #assisted-work{min-height:180px!important}
    }
    @media(max-width:820px){
      #main .edit-grid{grid-template-columns:1fr!important}
      #main .edit-grid>div[style*="grid-column:1/3"]{grid-column:1!important}
    }
  `;
  document.head.appendChild(style);
  const obs=new MutationObserver(()=>{
    const main=document.getElementById('main');
    if(!main)return;
    const h=[...main.querySelectorAll('h2')].find(x=>x.textContent.trim()==='Alta asistida');
    if(!h)return;
    main.style.overflow='visible';
    document.documentElement.style.overflowY='auto';
    document.body.style.overflowY='auto';
  });
  obs.observe(document.body,{subtree:true,childList:true});
})();