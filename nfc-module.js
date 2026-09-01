(()=>{
  const NFC_PUBLIC_BASE='https://mxbusinesscard.com/nfc/';
  const placements=[['phone_case','Funda de celular'],['paper_card','Tarjeta de opalina'],['pvc_card','Tarjeta PVC'],['counter','Mostrador'],['badge','Gafete'],['other','Otro']];
  const placementLabel=v=>placements.find(x=>x[0]===v)?.[1]||v||'Otro';
  const statusLabel=v=>({active:'Activo',inactive:'Inactivo',lost:'Perdido',replaced:'Reemplazado'})[v]||v;
  const safe=v=>String(v??'').replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  const db=()=>window.__mxDb;
  const nfcUrl=tag=>NFC_PUBLIC_BASE+encodeURIComponent(String(tag?.token||'').toLowerCase());
  const notify=message=>{ if(typeof window.toast==='function') window.toast(message); else console.log(message); };

  async function currentUser(){
    const client=db();
    if(!client)throw new Error('No se pudo conectar con la sesión del panel.');
    const {data:{user},error}=await client.auth.getUser();
    if(error||!user)throw new Error('Inicia sesión para administrar NFC.');
    return user;
  }

  async function list(cardId){
    const client=db();
    const user=await currentUser();
    let query=client.from('nfc_tags').select('id,card_id,label,token,placement,chip_type,status,notes,tap_count,last_tapped_at,created_at').eq('owner_id',user.id).order('created_at',{ascending:false});
    if(cardId)query=query.eq('card_id',cardId);
    const {data,error}=await query;
    if(error)throw error;
    return data||[];
  }

  async function loadCards(){
    const client=db();
    const user=await currentUser();
    const {data,error}=await client.from('digital_cards').select('id,name,slug,status,owner_id').eq('owner_id',user.id).eq('status','published').order('created_at',{ascending:false});
    if(error)throw error;
    return data||[];
  }

  async function create({cardId,label,placement='paper_card',notes=''}){
    const client=db();
    const user=await currentUser();
    const {data:ownedCard,error:cardError}=await client.from('digital_cards').select('id').eq('id',cardId).eq('owner_id',user.id).eq('status','published').maybeSingle();
    if(cardError||!ownedCard)throw new Error('Solo puedes asignar NFC a tus propias Digital Cards publicadas.');
    const {data,error}=await client.from('nfc_tags').insert({card_id:cardId,owner_id:user.id,label:String(label||'NFC').trim()||'NFC',placement,chip_type:'NTAG213',notes:String(notes||'').trim()||null}).select('id,card_id,label,token,placement,chip_type,status,notes,tap_count,last_tapped_at,created_at').single();
    if(error)throw error;
    return data;
  }

  async function setStatus(id,status){
    if(!['active','inactive','lost','replaced'].includes(status))throw new Error('Estado NFC no válido.');
    const user=await currentUser();
    const {data,error}=await db().from('nfc_tags').update({status,updated_at:new Date().toISOString()}).eq('id',id).eq('owner_id',user.id).select('id,status').single();
    if(error)throw error;
    return data;
  }

  async function copyUrl(tag){
    const url=nfcUrl(tag);
    await navigator.clipboard.writeText(url);
    return url;
  }

  function form(cards){
    const options=cards.map(c=>`<option value="${safe(c.id)}">${safe(c.name||'Digital Card')} · /c/${safe(c.slug||'')}</option>`).join('');
    return `<form class="panel" id="nfc-create-form"><h2>Asignar nuevo NFC</h2>${options?`<div class="formgrid"><div class="field"><label>Digital Card</label><select name="cardId" required>${options}</select></div><div class="field"><label>Uso físico</label><select name="placement">${placements.map(([v,l])=>`<option value="${v}">${l}</option>`).join('')}</select></div><div class="field full"><label>Nombre interno</label><input name="label" maxlength="80" placeholder="Ej. Sticker celular 01" value="NFC"></div><div class="field full"><label>Notas</label><input name="notes" maxlength="250" placeholder="Opcional"></div></div><button class="primary" type="submit">Crear NFC</button>`:'<p>No tienes una Digital Card publicada disponible para asignar un NFC.</p>'}</form>`;
  }

  function table(tags,cards){
    if(!tags.length)return '<div class="panel empty">Todavía no hay NFC registrados.</div>';
    const cardMap=new Map(cards.map(c=>[c.id,c]));
    return `<div class="panel table-wrap"><table class="table"><thead><tr><th>NFC</th><th>Digital Card</th><th>Uso</th><th>Lecturas</th><th>Estado</th><th>Acciones</th></tr></thead><tbody>${tags.map(tag=>{const card=cardMap.get(tag.card_id);const cardText=card?`${card.name||'Digital Card'} · /c/${card.slug||''}`:'Digital Card asignada';return `<tr><td><b>${safe(tag.label)}</b><small class="entity-slug">${safe(tag.id.slice(0,8))} · ${safe(tag.chip_type)}</small></td><td>${safe(cardText)}</td><td>${safe(placementLabel(tag.placement))}</td><td><b>${Number(tag.tap_count||0)}</b><small class="entity-slug">${tag.last_tapped_at?'Última: '+safe(new Date(tag.last_tapped_at).toLocaleString('es-MX')):'Sin lecturas'}</small></td><td><span class="badge">${safe(statusLabel(tag.status))}</span></td><td><div class="team-actions"><button class="ghost" data-nfc-copy="${safe(tag.id)}">Copiar URL</button><select data-nfc-status="${safe(tag.id)}"><option value="active" ${tag.status==='active'?'selected':''}>Activo</option><option value="inactive" ${tag.status==='inactive'?'selected':''}>Inactivo</option><option value="lost" ${tag.status==='lost'?'selected':''}>Perdido</option><option value="replaced" ${tag.status==='replaced'?'selected':''}>Reemplazado</option></select></div><small class="nfc-public-url">${safe(nfcUrl(tag))}</small></td></tr>`}).join('')}</tbody></table></div>`;
  }

  async function mount(container){
    if(!container)return;
    container.innerHTML='<div class="panel">Cargando NFC…</div>';
    try{
      const [tags,cards]=await Promise.all([list(),loadCards()]);
      const total=tags.reduce((sum,t)=>sum+Number(t.tap_count||0),0);
      const active=tags.filter(t=>t.status==='active').length;
      container.innerHTML=`<style>.nfc-summary{display:grid;grid-template-columns:repeat(3,minmax(140px,1fr));gap:12px;margin:16px 0}.nfc-public-url,.entity-slug{display:block;margin-top:5px;color:var(--muted);word-break:break-all}.nfc-route-note{margin:0 0 16px;color:var(--muted)}@media(max-width:700px){.nfc-summary{grid-template-columns:1fr}}</style><div class="top"><div><h1>Mis NFC</h1><p>Administra únicamente los NFC vinculados a tus Digital Cards.</p></div></div><p class="nfc-route-note">URL de producción: <b>mxbusinesscard.com/nfc/...</b></p><div class="nfc-summary"><div class="metric"><span>NFC registrados</span><b>${tags.length}</b></div><div class="metric"><span>NFC activos</span><b>${active}</b></div><div class="metric"><span>Lecturas acumuladas</span><b>${total}</b></div></div><div class="editor" style="align-items:start"><div>${form(cards)}<div style="height:16px"></div>${table(tags,cards)}</div><div class="panel"><h2>Cómo programar el NFC</h2><ol><li>Crea y asigna aquí el NFC.</li><li>Copia la URL de programación.</li><li>En NFC Tools crea un registro URL/URI.</li><li>Escribe la URL en el NTAG213.</li><li>No bloquees el chip durante el piloto.</li></ol></div></div>`;
      const createForm=container.querySelector('#nfc-create-form');
      createForm?.addEventListener('submit',async event=>{event.preventDefault();const button=createForm.querySelector('button[type=submit]'),fd=new FormData(createForm);button.disabled=true;try{const tag=await create({cardId:String(fd.get('cardId')||''),placement:String(fd.get('placement')||'paper_card'),label:String(fd.get('label')||'NFC'),notes:String(fd.get('notes')||'')});await copyUrl(tag);notify('NFC creado. URL copiada.');await mount(container)}catch(error){notify('No se pudo crear el NFC: '+(error?.message||'Error desconocido'))}finally{button.disabled=false}});
      container.querySelectorAll('[data-nfc-copy]').forEach(button=>button.addEventListener('click',async()=>{const tag=tags.find(x=>x.id===button.dataset.nfcCopy);if(tag){await copyUrl(tag);notify('URL NFC copiada.')}}));
      container.querySelectorAll('[data-nfc-status]').forEach(select=>select.addEventListener('change',async()=>{try{await setStatus(select.dataset.nfcStatus,select.value);notify('Estado NFC actualizado.');await mount(container)}catch(error){notify('No se pudo actualizar el NFC: '+(error?.message||'Error desconocido'))}}));
    }catch(error){container.innerHTML=`<div class="panel"><h2>No se pudo cargar Mis NFC</h2><p>${safe(error?.message||'Error desconocido')}</p></div>`;}
  }

  function openPanel(){
    window.__mxNfcOpen=true;
    const main=document.querySelector('.main');
    if(!main)return;
    document.querySelectorAll('.nav button').forEach(b=>b.classList.remove('active'));
    document.querySelector('[data-mx-nfc-nav]')?.classList.add('active');
    main.innerHTML='<div id="mx-nfc-view"></div>';
    mount(main.querySelector('#mx-nfc-view'));
  }

  function installNav(){
    const nav=document.querySelector('.nav');
    if(!nav||nav.querySelector('[data-mx-nfc-nav]'))return;
    const button=document.createElement('button');
    button.type='button';
    button.dataset.mxNfcNav='1';
    button.innerHTML='<span style="display:inline-block;width:22px">◉</span><span>Mis NFC</span>';
    button.addEventListener('click',openPanel);
    nav.appendChild(button);
  }

  const observer=new MutationObserver(()=>installNav());
  observer.observe(document.documentElement,{childList:true,subtree:true});
  document.readyState==='loading'?document.addEventListener('DOMContentLoaded',installNav):installNav();
  window.MXNfc={list,create,setStatus,nfcUrl,mount,openPanel};
})();