(()=>{
  const NFC_PUBLIC_BASE='https://mxbusinesscard.com/nfc/';
  const placements=[['phone_case','Funda de celular'],['paper_card','Tarjeta de opalina'],['pvc_card','Tarjeta PVC'],['counter','Mostrador'],['badge','Gafete'],['other','Otro']];
  const placementLabel=value=>placements.find(x=>x[0]===value)?.[1]||value||'Otro';
  const statusLabel=value=>({active:'Activo',inactive:'Inactivo',lost:'Perdido',replaced:'Reemplazado'})[value]||value;
  const nfcUrl=tag=>NFC_PUBLIC_BASE+encodeURIComponent(String(tag?.token||'').toLowerCase());
  const safe=value=>typeof esc==='function'?esc(String(value??'')):String(value??'').replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  const notify=message=>typeof toast==='function'?toast(message):console.log(message);

  async function list(cardId){
    let query=db.from('nfc_tags').select('id,card_id,label,token,placement,chip_type,status,notes,tap_count,last_tapped_at,created_at').order('created_at',{ascending:false});
    if(cardId)query=query.eq('card_id',cardId);
    const {data,error}=await query;
    if(error)throw error;
    return data||[];
  }

  async function create({cardId,label,placement='paper_card',notes=''}){
    if(!state.session?.user?.id)throw new Error('Inicia sesión para crear un NFC.');
    const card=(state.cards||[]).find(item=>item.id===cardId);
    if(!card)throw new Error('Selecciona una Digital Card válida.');
    const payload={card_id:cardId,owner_id:state.session.user.id,label:String(label||'NFC').trim()||'NFC',placement,chip_type:'NTAG213',notes:String(notes||'').trim()||null};
    const {data,error}=await db.from('nfc_tags').insert(payload).select('id,card_id,label,token,placement,chip_type,status,notes,tap_count,last_tapped_at,created_at').single();
    if(error)throw error;
    return data;
  }

  async function setStatus(id,status){
    if(!['active','inactive','lost','replaced'].includes(status))throw new Error('Estado NFC no válido.');
    const {data,error}=await db.from('nfc_tags').update({status,updated_at:new Date().toISOString()}).eq('id',id).select('id,status').single();
    if(error)throw error;
    return data;
  }

  async function copyUrl(tag){
    const url=nfcUrl(tag);
    await navigator.clipboard.writeText(url);
    return url;
  }

  function cardLabel(tag){
    const card=(state.cards||[]).find(item=>item.id===tag.card_id);
    return card?`${card.name||'Digital Card'} · /c/${card.slug||''}`:'Digital Card asignada';
  }

  function instructions(){return `<div class="panel"><h2>Cómo programar el NFC</h2><ol><li>Crea y asigna aquí el NFC a una Digital Card publicada.</li><li>Copia la URL de programación de MX Business Card.</li><li>En NFC Tools, crea un registro URL/URI.</li><li>Escribe la URL en el NTAG213.</li><li>No bloquees el chip durante el piloto.</li><li>Prueba el NFC fuera de NFC Tools.</li></ol><p class="readonly-note">Los stickers nuevos usan una URL propia de MX Business Card. Si después cambia la infraestructura, la URL física puede seguir siendo la misma.</p></div>`}

  function form(){
    const options=(state.cards||[]).filter(c=>c.status==='published').map(c=>`<option value="${safe(c.id)}">${safe(c.name)} · /c/${safe(c.slug)}</option>`).join('');
    return `<form class="panel" id="nfc-create-form"><h2>Asignar nuevo NFC</h2>${options?`<div class="formgrid"><div class="field"><label>Digital Card</label><select name="cardId" required>${options}</select></div><div class="field"><label>Uso físico</label><select name="placement">${placements.map(([v,l])=>`<option value="${v}">${l}</option>`).join('')}</select></div><div class="field full"><label>Nombre interno</label><input name="label" maxlength="80" placeholder="Ej. Sticker celular 01" value="NFC"></div><div class="field full"><label>Notas</label><input name="notes" maxlength="250" placeholder="Opcional"></div></div><button class="primary" type="submit">Crear NFC</button>`:'<p>Publica primero una Digital Card para poder asignarle un NFC.</p>'}</form>`;
  }

  function table(tags){
    if(!tags.length)return '<div class="panel empty">Todavía no hay NFC registrados.</div>';
    return `<div class="panel table-wrap"><table class="table"><thead><tr><th>NFC</th><th>Digital Card</th><th>Uso</th><th>Lecturas</th><th>Estado</th><th>Acciones</th></tr></thead><tbody>${tags.map(tag=>`<tr><td><b>${safe(tag.label)}</b><small class="entity-slug">${safe(tag.id.slice(0,8))} · ${safe(tag.chip_type)}</small></td><td>${safe(cardLabel(tag))}</td><td>${safe(placementLabel(tag.placement))}</td><td><b>${Number(tag.tap_count||0)}</b><small class="entity-slug">${tag.last_tapped_at?'Última: '+safe(new Date(tag.last_tapped_at).toLocaleString('es-MX')):'Sin lecturas'}</small></td><td><span class="badge">${safe(statusLabel(tag.status))}</span></td><td><div class="team-actions"><button class="ghost" data-nfc-copy="${safe(tag.id)}">Copiar URL</button><select data-nfc-status="${safe(tag.id)}"><option value="active" ${tag.status==='active'?'selected':''}>Activo</option><option value="inactive" ${tag.status==='inactive'?'selected':''}>Inactivo</option><option value="lost" ${tag.status==='lost'?'selected':''}>Perdido</option><option value="replaced" ${tag.status==='replaced'?'selected':''}>Reemplazado</option></select></div><small class="nfc-public-url">${safe(nfcUrl(tag))}</small></td></tr>`).join('')}</tbody></table></div>`;
  }

  async function mount(container){
    if(!container)return;
    container.innerHTML='<div class="panel">Cargando NFC…</div>';
    try{
      const tags=await list();
      const total=tags.reduce((sum,t)=>sum+Number(t.tap_count||0),0);
      const active=tags.filter(t=>t.status==='active').length;
      container.innerHTML=`<style>.nfc-summary{display:grid;grid-template-columns:repeat(3,minmax(140px,1fr));gap:12px;margin:16px 0}.nfc-summary .metric{margin:0}.nfc-public-url{display:block;margin-top:6px;color:var(--muted);max-width:260px;word-break:break-all}.entity-slug{display:block;color:var(--muted);margin-top:4px}.nfc-route-note{margin:0 0 16px;color:var(--muted)}@media(max-width:700px){.nfc-summary{grid-template-columns:1fr}}</style><div class="top"><div><h1>Mis NFC</h1><p>Administra stickers y tarjetas NFC vinculados a tus Digital Cards.</p></div></div><p class="nfc-route-note">URL de producción: <b>mxbusinesscard.com/nfc/...</b></p><div class="nfc-summary"><div class="metric"><span>NFC registrados</span><b>${tags.length}</b></div><div class="metric"><span>NFC activos</span><b>${active}</b></div><div class="metric"><span>Lecturas acumuladas</span><b>${total}</b></div></div><div class="editor" style="align-items:start"><div>${form()}<div style="height:16px"></div>${table(tags)}</div>${instructions()}</div>`;
      const createForm=container.querySelector('#nfc-create-form');
      createForm?.addEventListener('submit',async event=>{event.preventDefault();const button=createForm.querySelector('button[type=submit]'),fd=new FormData(createForm);button.disabled=true;try{const tag=await create({cardId:String(fd.get('cardId')||''),placement:String(fd.get('placement')||'paper_card'),label:String(fd.get('label')||'NFC'),notes:String(fd.get('notes')||'')});await copyUrl(tag);notify('NFC creado. URL de MX Business Card copiada.');await mount(container)}catch(error){notify('No se pudo crear el NFC: '+(error?.message||'Error desconocido'))}finally{button.disabled=false}});
      container.querySelectorAll('[data-nfc-copy]').forEach(button=>button.addEventListener('click',async()=>{const tag=tags.find(x=>x.id===button.dataset.nfcCopy);if(!tag)return;try{await copyUrl(tag);notify('URL NFC copiada.')}catch{notify('No se pudo copiar la URL NFC.')}}));
      container.querySelectorAll('[data-nfc-status]').forEach(select=>select.addEventListener('change',async()=>{try{await setStatus(select.dataset.nfcStatus,select.value);notify('Estado NFC actualizado.');await mount(container)}catch(error){notify('No se pudo actualizar el NFC: '+(error?.message||'Error desconocido'))}}));
    }catch(error){container.innerHTML=`<div class="panel"><h2>No se pudo cargar Mis NFC</h2><p>${safe(error?.message||'Error desconocido')}</p></div>`}
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
    button.addEventListener('click',event=>{event.stopPropagation();openPanel()});
    nav.appendChild(button);
    nav.addEventListener('click',event=>{const clicked=event.target.closest('button');if(clicked&&!clicked.matches('[data-mx-nfc-nav]'))window.__mxNfcOpen=false},{capture:true});
  }

  function keepInstalled(){
    installNav();
    if(window.__mxNfcOpen){
      const main=document.querySelector('.main');
      if(main&&!main.querySelector('#mx-nfc-view'))openPanel();
    }
  }

  const observer=new MutationObserver(()=>keepInstalled());
  observer.observe(document.documentElement,{childList:true,subtree:true});
  document.readyState==='loading'?document.addEventListener('DOMContentLoaded',keepInstalled):keepInstalled();

  window.MXNfc={list,create,setStatus,nfcUrl,mount,openPanel};
})();
