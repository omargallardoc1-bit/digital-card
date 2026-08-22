(()=>{
  if(!location.pathname.startsWith('/c/'))return;
  const SUPABASE_URL='https://loovwrnifdimlwpfgjza.supabase.co';
  const SUPABASE_PUBLISHABLE_KEY='sb_publishable_eP8FFThBgpS4ox4tlP40Lg_8Y51C9sR';
  const BUCKET='digital-card-media';
  const slug=decodeURIComponent(location.pathname.split('/').filter(Boolean)[1]||'').trim();
  if(!slug)return;
  let client=null,mountedFor='',loading=false,audioEl=null;
  function dbClient(){
    if(client)return client;
    if(window.__mxDb){client=window.__mxDb;return client}
    if(window.supabase?.createClient){client=window.supabase.createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});return client}
    return null;
  }
  async function loadCard(){
    const db=dbClient();if(!db)return null;
    const {data,error}=await db.from('digital_cards').select('id,slug,status,audio_url,audio_duration_seconds,audio_loop').eq('slug',slug).eq('status','published').maybeSingle();
    if(error){console.warn('Public audio card query failed',error);return null}
    return data||null;
  }
  function removeExisting(){document.getElementById('mx-public-audio-button')?.remove();if(audioEl){audioEl.pause();audioEl.src='';audioEl=null}}
  async function mount(){
    if(loading)return;
    loading=true;
    try{
      const c=await loadCard();
      if(!c?.audio_url){removeExisting();mountedFor='';return}
      const key=`${c.id}:${c.audio_url}:${!!c.audio_loop}`;
      if(mountedFor===key&&document.getElementById('mx-public-audio-button'))return;
      const db=dbClient();
      const {data,error}=await db.storage.from(BUCKET).createSignedUrl(c.audio_url,3600);
      if(error||!data?.signedUrl){console.warn('Public audio signed URL failed',error);return}
      removeExisting();
      audioEl=new Audio(data.signedUrl);
      audioEl.preload='metadata';
      audioEl.loop=!!c.audio_loop;
      const button=document.createElement('button');
      button.id='mx-public-audio-button';
      button.type='button';
      button.setAttribute('aria-label','Reproducir audio');
      button.title='Reproducir audio';
      button.textContent='▶';
      button.style.cssText='position:fixed;top:14px;left:14px;z-index:9999;width:42px;height:42px;border:1px solid var(--line,#e2e7f0);border-radius:10px;background:#fff;color:var(--text,#101828);box-shadow:0 3px 15px #1112;display:grid;place-items:center;font-size:18px;font-weight:800;cursor:pointer;padding:0';
      button.onclick=async()=>{
        if(!audioEl)return;
        if(audioEl.paused){
          try{await audioEl.play();button.textContent='❚❚';button.setAttribute('aria-label','Pausar audio');button.title='Pausar audio'}catch(error){console.warn('Audio playback failed',error)}
        }else{audioEl.pause();button.textContent='▶';button.setAttribute('aria-label','Reproducir audio');button.title='Reproducir audio'}
      };
      audioEl.addEventListener('ended',()=>{if(!audioEl.loop){button.textContent='▶';button.setAttribute('aria-label','Reproducir audio');button.title='Reproducir audio'}});
      audioEl.addEventListener('pause',()=>{if(audioEl.currentTime<audioEl.duration){button.textContent='▶';button.setAttribute('aria-label','Reproducir audio');button.title='Reproducir audio'}});
      document.body.appendChild(button);
      mountedFor=key;
    }finally{loading=false}
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>setTimeout(()=>void mount(),350));else setTimeout(()=>void mount(),350);
  setTimeout(()=>void mount(),1200);
  setTimeout(()=>void mount(),3000);
})();