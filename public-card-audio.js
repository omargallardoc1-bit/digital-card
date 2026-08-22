(()=>{
  if(!location.pathname.startsWith('/c/'))return;
  const SUPABASE_URL='https://loovwrnifdimlwpfgjza.supabase.co';
  const SUPABASE_PUBLISHABLE_KEY='sb_publishable_eP8FFThBgpS4ox4tlP40Lg_8Y51C9sR';
  const BUCKET='digital-card-media';
  const slug=decodeURIComponent(location.pathname.split('/').filter(Boolean)[1]||'').trim();
  if(!slug)return;
  let client=null,mountedFor='',loading=false;
  const esc=v=>String(v??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
  function dbClient(){
    if(client)return client;
    if(window.__mxDb){client=window.__mxDb;return client}
    if(window.supabase?.createClient){client=window.supabase.createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});return client}
    return null;
  }
  function findHost(){
    return document.querySelector('.public-card .mini')||document.querySelector('.public-card')||document.querySelector('.public-content .mini')||document.querySelector('.public-content')||document.querySelector('.screen .mini')||document.querySelector('.screen');
  }
  async function loadCard(){
    const db=dbClient();if(!db)return null;
    const {data,error}=await db.from('digital_cards').select('id,slug,status,audio_url,audio_duration_seconds,audio_loop').eq('slug',slug).eq('status','published').maybeSingle();
    if(error){console.warn('Public audio card query failed',error);return null}
    return data||null;
  }
  async function mount(){
    if(loading)return;
    const host=findHost();if(!host)return;
    loading=true;
    try{
      const c=await loadCard();
      if(!c?.audio_url){document.getElementById('mx-public-card-audio')?.remove();mountedFor='';return}
      const key=`${c.id}:${c.audio_url}:${!!c.audio_loop}`;
      if(mountedFor===key&&document.getElementById('mx-public-card-audio'))return;
      const db=dbClient();
      const {data,error}=await db.storage.from(BUCKET).createSignedUrl(c.audio_url,3600);
      if(error||!data?.signedUrl){console.warn('Public audio signed URL failed',error);return}
      document.getElementById('mx-public-card-audio')?.remove();
      const section=document.createElement('section');
      section.id='mx-public-card-audio';
      section.className='section';
      section.style.cssText='padding:14px 0;border-top:1px solid var(--line,#e2e7f0)';
      const duration=Number(c.audio_duration_seconds)||0;
      section.innerHTML=`<div style="display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:8px"><strong style="font-size:15px">🎵 Audio</strong>${duration?`<span style="font-size:12px;color:var(--muted,#667085)">${Math.floor(duration/60)}:${String(duration%60).padStart(2,'0')}</span>`:''}</div><audio controls controlsList="nodownload" preload="metadata" ${c.audio_loop?'loop':''} src="${esc(data.signedUrl)}" style="display:block;width:100%;height:42px"></audio>`;
      const about=[...host.querySelectorAll('h1,h2,h3,strong')].find(el=>/acerca de|about/i.test((el.textContent||'').trim()));
      if(about){const container=about.closest('section,.section,.card-section')||about.parentElement;if(container?.parentNode===host)host.insertBefore(section,container);else host.appendChild(section)}else host.appendChild(section);
      mountedFor=key;
    }finally{loading=false}
  }
  let scheduled=false;
  const observer=new MutationObserver(()=>{if(scheduled)return;scheduled=true;setTimeout(()=>{scheduled=false;void mount()},250)});
  observer.observe(document.documentElement,{childList:true,subtree:true});
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>setTimeout(()=>void mount(),350));else setTimeout(()=>void mount(),350);
  setTimeout(()=>void mount(),1200);
  setTimeout(()=>void mount(),3000);
})();