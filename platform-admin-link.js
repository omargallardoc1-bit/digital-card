(()=>{
  const LABEL_ES='Superadministración',LABEL_EN='Platform admin';
  let authorized=false,checking=false;
  function label(){return document.documentElement.lang==='en'?LABEL_EN:LABEL_ES}
  function addLinks(){
    if(!authorized)return;
    const side=document.querySelector('.side-nav');
    if(side&&!side.querySelector('[data-platform-admin-link]')){
      const button=document.createElement('button');button.type='button';button.dataset.platformAdminLink='1';button.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3 4 7v5c0 4.8 3.2 7.8 8 9 4.8-1.2 8-4.2 8-9V7l-8-4Z"/><path d="M9 12h6M12 9v6"/></svg><span>'+label()+'</span>';button.onclick=()=>location.assign('/platform-admin');side.appendChild(button);
    }
    const more=document.querySelector('.mobile-more-links');
    if(more&&!more.querySelector('[data-platform-admin-link]')){
      const button=document.createElement('button');button.type='button';button.className='ghost';button.dataset.platformAdminLink='1';button.innerHTML='<span>'+label()+'</span>';button.onclick=()=>location.assign('/platform-admin');more.appendChild(button);
    }
  }
  async function check(){
    if(checking)return;const supabaseClient=window.__mxDb;if(!supabaseClient?.auth||!supabaseClient?.functions)return;
    checking=true;
    try{const {data:{session}}=await supabaseClient.auth.getSession();if(!session){authorized=false;return}const {data,error}=await supabaseClient.functions.invoke('platform-admin',{body:{action:'list_customers',search_text:'',page:1,page_size:1}});authorized=!error&&data?.ok===true}catch{authorized=false}finally{checking=false;addLinks()}
  }
  const observer=new MutationObserver(()=>{addLinks();void check()});observer.observe(document.documentElement,{childList:true,subtree:true});
  window.addEventListener('load',()=>{void check()});setTimeout(()=>void check(),600);
})();
