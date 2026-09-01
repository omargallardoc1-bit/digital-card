(()=>{
  const BUCKET='digital-card-media',INTERVAL=5000;
  let editorCardId='',editorItems=[],editorArchived=[],limits=null,busy=false,publicCardId='',timer=null,index=0;
  const getDb=()=>window.__mxDb||null;
  const esc=v=>String(v??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
  const notify=m=>typeof toast==='function'?toast(m):alert(m);
  const signed=async path=>{const db=getDb();if(!db||!path)return'';const {data}=await db.storage.from(BUCKET).createSignedUrl(path,900);return data?.signedUrl||''};

  function css(){if(document.getElementById('mx-cover-carousel-css'))return;const s=document.createElement('style');s.id='mx-cover-carousel-css';s.textContent=`
    .mx-cover-carousel{position:relative;overflow:hidden}.mx-cover-carousel-controls{position:absolute;inset:auto 12px 12px;z-index:4;display:flex;justify-content:space-between;pointer-events:none}.mx-cover-carousel-controls button{pointer-events:auto;width:38px;height:38px;border:1px solid #fff8;border-radius:999px;background:#111827a8;color:#fff;font-size:22px;line-height:1}.mx-cover-dots{position:absolute;left:50%;bottom:18px;z-index:4;display:flex;gap:6px;transform:translateX(-50%)}.mx-cover-dot{width:7px;height:7px;border:0;border-radius:50%;padding:0;background:#ffffff80}.mx-cover-dot.active{background:#fff}.mx-cover-list{display:grid;gap:10px}.mx-cover-row{display:grid;grid-template-columns:80px 1fr auto;gap:12px;align-items:center;padding:10px;border:1px solid var(--line);border-radius:10px}.mx-cover-row img{width:80px;height:48px;object-fit:cover;border-radius:7px}.mx-cover-archive{margin-top:14px;padding-top:12px;border-top:1px solid var(--line)}@media(max-width:520px){.mx-cover-row{grid-template-columns:64px 1fr}.mx-cover-row img{width:64px}.mx-cover-row button{grid-column:1/-1}}
  `;document.head.appendChild(s)}

  const editorMounted=()=>!!document.getElementById('mx-cover-carousel-editor');

  async function loadEditor(cardId){const db=getDb();if(!db||!cardId)return;const requestedCardId=cardId;
    const [imagesResponse,limitsResponse]=await Promise.all([
      db.from('card_cover_images').select('id,card_id,object_path,position,archived_at,download_until,created_at').eq('card_id',cardId).order('position',{ascending:true}).order('created_at',{ascending:true}),
      db.rpc('get_card_content_limits',{target_card_id:cardId})
    ]);
    if(typeof state!=='undefined'&&state.card?.id&&state.card.id!==requestedCardId)return;
    editorCardId=requestedCardId;
    if(imagesResponse.error){editorItems=[];editorArchived=[];limits=null;renderEditor();return}
    const rows=imagesResponse.data||[];await Promise.all(rows.map(async row=>{row.signed_url=await signed(row.object_path)}));
    editorItems=rows.filter(x=>!x.archived_at);editorArchived=rows.filter(x=>x.archived_at&&new Date(x.download_until)>new Date());
    const l=Array.isArray(limitsResponse.data)?limitsResponse.data[0]:limitsResponse.data;limits=l||null;if(typeof state!=='undefined')state.cardContentLimits=limits;renderEditor();
  }

  function editorHtml(){const limit=Math.max(1,Number(limits?.cover_images_limit)||1),used=editorItems.length,editable=typeof canEditCurrentCardContent==='function'&&canEditCurrentCardContent();
    const active=editorItems.length?`<div class="mx-cover-list">${editorItems.map((x,i)=>`<div class="mx-cover-row"><img src="${esc(x.signed_url)}" alt="Portada ${i+1}"><div><b>Fotografía ${i+1}</b><div class="media-help">Se muestra 5 segundos.</div></div>${editable?`<button class="danger" type="button" onclick="window.MXCoverCarousel.archive('${esc(x.id)}')" ${busy?'disabled':''}>Retirar</button>`:''}</div>`).join('')}</div>`:'<div class="empty">Todavía no hay fotografías de portada.</div>';
    const archived=editorArchived.length?`<div class="mx-cover-archive"><b>Disponibles solo para descarga</b><p class="media-help">Se eliminarán al terminar su periodo de conservación de 30 días.</p>${editorArchived.map(x=>`<div class="mx-cover-row"><img src="${esc(x.signed_url)}" alt="Portada retirada"><div><b>Retirada</b><div class="media-help">Disponible hasta ${esc(new Date(x.download_until).toLocaleDateString('es-MX'))}</div></div><a class="ghost" href="${esc(x.signed_url)}" download>Descargar</a></div>`).join('')}</div>`:'';
    return `<section class="editor-block" id="mx-cover-carousel-editor"><div class="editor-block-header"><div><h2>Fotografías de portada</h2><p>${used} de ${limit} utilizadas · 5 segundos por fotografía.</p></div></div><div class="editor-block-body">${active}${editable&&used<limit?`<div class="field" style="margin-top:12px"><label for="mx-cover-file">Agregar fotografía</label><input id="mx-cover-file" type="file" accept="image/jpeg,image/png,image/webp" ${busy?'disabled':''}></div><button class="primary" id="mx-cover-upload" type="button" ${busy?'disabled':''}>${busy?'Guardando…':'Agregar portada'}</button>`:used>=limit?'<p class="media-help">Alcanzaste el límite de tu plan.</p>':''}${archived}</div></section>`}

  function renderEditor(){if(typeof state==='undefined'||state.page!=='editor')return;css();const host=document.querySelector('.editor-sections');if(!host)return;const old=document.getElementById('mx-cover-carousel-editor');if(old)old.outerHTML=editorHtml();else host.insertAdjacentHTML('beforeend',editorHtml());document.getElementById('mx-cover-upload')?.addEventListener('click',upload)}

  async function upload(){const file=document.getElementById('mx-cover-file')?.files?.[0],db=getDb(),card=state?.card;if(!file||!db||!card?.id||busy)return;try{busy=true;renderEditor();const settings=mediaSettings.cover,processed=await compressCardImage(file,settings),path=`${card.owner_id||state.session.user.id}/${card.id}/cover/${crypto.randomUUID()}.webp`;const up=await db.storage.from(BUCKET).upload(path,processed.blob,{contentType:'image/webp',cacheControl:'3600',upsert:false});if(up.error)throw up.error;const add=await db.rpc('add_card_cover_image',{target_card_id:card.id,object_path:path});if(add.error){await db.storage.from(BUCKET).remove([path]);throw add.error}await loadEditor(card.id);if(typeof refreshCardAndOrganization==='function')await refreshCardAndOrganization(card.id);notify('Fotografía de portada agregada.')}catch(e){notify('No se pudo agregar la portada: '+(e.message||e))}finally{busy=false;renderEditor()}}

  async function archive(id){const db=getDb();if(!db||busy||!confirm('¿Retirar esta fotografía? Quedará disponible para descarga durante 30 días.'))return;busy=true;renderEditor();const {error}=await db.rpc('archive_card_cover_image',{target_image_id:id});busy=false;if(error){notify('No se pudo retirar la fotografía: '+error.message);renderEditor();return}await loadEditor(editorCardId);if(typeof refreshCardAndOrganization==='function')await refreshCardAndOrganization(editorCardId);notify('Fotografía retirada y conservada por 30 días.')}

  function stop(){if(timer)clearInterval(timer);timer=null}
  function paint(cover,items,next){if(!cover||!items.length)return;index=(next+items.length)%items.length;cover.style.backgroundImage=`linear-gradient(0deg,rgba(11,18,32,.52),rgba(11,18,32,.16)),url('${items[index].signed_url.replace(/'/g,"%27")}')`;cover.querySelectorAll('.mx-cover-dot').forEach((d,i)=>d.classList.toggle('active',i===index))}
  function mountPublic(items){const cover=document.querySelector('.public-card .card-cover');if(!cover||!items.length)return;cover.classList.add('mx-cover-carousel');paint(cover,items,0);cover.querySelector('.mx-cover-carousel-controls')?.remove();cover.querySelector('.mx-cover-dots')?.remove();if(items.length<2)return;
    cover.insertAdjacentHTML('beforeend',`<div class="mx-cover-carousel-controls"><button type="button" data-dir="-1" aria-label="Fotografía anterior">‹</button><button type="button" data-dir="1" aria-label="Fotografía siguiente">›</button></div><div class="mx-cover-dots">${items.map((_,i)=>`<button type="button" class="mx-cover-dot ${i===0?'active':''}" data-index="${i}" aria-label="Ver fotografía ${i+1}"></button>`).join('')}</div>`);
    cover.querySelectorAll('[data-dir]').forEach(b=>b.onclick=()=>{paint(cover,items,index+Number(b.dataset.dir));restart(cover,items)});cover.querySelectorAll('[data-index]').forEach(b=>b.onclick=()=>{paint(cover,items,Number(b.dataset.index));restart(cover,items)});restart(cover,items)}
  function restart(cover,items){stop();if(matchMedia('(prefers-reduced-motion: reduce)').matches||document.hidden)return;timer=setInterval(()=>paint(cover,items,index+1),INTERVAL)}
  async function loadPublic(cardId){const db=getDb();if(!db||!cardId||publicCardId===cardId)return;publicCardId=cardId;const {data,error}=await db.from('card_cover_images').select('id,object_path,position').eq('card_id',cardId).is('archived_at',null).order('position',{ascending:true});if(error||!data?.length)return;await Promise.all(data.map(async row=>{row.signed_url=await signed(row.object_path)}));mountPublic(data.filter(x=>x.signed_url))}

  let scheduled=false;const observe=()=>{if(scheduled)return;scheduled=true;requestAnimationFrame(async()=>{scheduled=false;css();if(typeof state==='undefined')return;if(state.page==='editor'&&state.card?.id&&(editorCardId!==state.card.id||!editorMounted()))await loadEditor(state.card.id);if(typeof isPublicRoute==='function'&&isPublicRoute()&&state.publicCard?.id)await loadPublic(state.publicCard.id)})};
  document.addEventListener('visibilitychange',()=>{if(document.hidden)stop();else if(typeof state!=='undefined'&&state.publicCard?.id){publicCardId='';void loadPublic(state.publicCard.id)}});
  new MutationObserver(observe).observe(document.documentElement,{childList:true,subtree:true});
  window.MXCoverCarousel={archive,refresh:()=>{editorCardId='';observe()}};if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',observe);else observe();
})();
