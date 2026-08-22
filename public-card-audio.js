(()=>{
  if(!location.pathname.startsWith('/c/'))return;
  const BUCKET='digital-card-media';
  let mountedFor='';
  const esc=v=>String(v??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
  function getDb(){return window.__mxDb||(typeof db!=='undefined'?db:null)}
  function currentCard(){return typeof state!=='undefined'?state.card:null}
  async function mount(){
    const c=currentCard(),client=getDb();
    if(!c?.id||!c.audio_url||!client)return;
    const key=`${c.id}:${c.audio_url}:${!!c.audio_loop}`;
    if(mountedFor===key&&document.getElementById('mx-public-card-audio'))return;
    const {data,error}=await client.storage.from(BUCKET).createSignedUrl(c.audio_url,3600);
    if(error||!data?.signedUrl)return;
    document.getElementById('mx-public-card-audio')?.remove();
    const publicCard=document.querySelector('.public-card')||document.querySelector('.public-content')||document.querySelector('.screen');
    if(!publicCard)return;
    const section=document.createElement('section');
    section.id='mx-public-card-audio';
    section.style.cssText='margin:14px 0;padding:14px;border:1px solid var(--line,#e2e7f0);border-radius:14px;background:#fff';
    section.innerHTML=`<div style="font-size:13px;font-weight:800;margin-bottom:8px">🎵 Audio</div><audio controls preload="metadata" ${c.audio_loop?'loop':''} src="${esc(data.signedUrl)}" style="display:block;width:100%;height:42px"></audio>`;
    const about=[...publicCard.querySelectorAll('h1,h2,h3,strong')].find(el=>/acerca de|about/i.test(el.textContent||''));
    if(about){const container=about.closest('section,.section,.card-section')||about.parentElement;container?.parentNode?.insertBefore(section,container)}else publicCard.appendChild(section);
    mountedFor=key;
  }
  let scheduled=false;
  const observer=new MutationObserver(()=>{if(scheduled)return;scheduled=true;setTimeout(()=>{scheduled=false;void mount()},100)});
  observer.observe(document.documentElement,{childList:true,subtree:true});
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>void mount());else void mount();
})();