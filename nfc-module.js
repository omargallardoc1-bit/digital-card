(()=>{
  const NFC_REDIRECT_BASE='https://loovwrnifdimlwpfgjza.supabase.co/functions/v1/nfc-redirect?token=';
  const placements=[['phone_case','Funda de celular'],['paper_card','Tarjeta de opalina'],['pvc_card','Tarjeta PVC'],['counter','Mostrador'],['badge','Gafete'],['other','Otro']];
  const placementLabel=value=>placements.find(x=>x[0]===value)?.[1]||value||'Otro';
  const statusLabel=value=>({active:'Activo',inactive:'Inactivo',lost:'Perdido',replaced:'Reemplazado'})[value]||value;
  const nfcUrl=tag=>NFC_REDIRECT_BASE+encodeURIComponent(tag.token||'');

  async function list(cardId){
    let query=db.from('nfc_tags').select('id,card_id,label,token,placement,chip_type,status,notes,tap_count,last_tapped_at,created_at').order('created_at',{ascending:false});
    if(cardId)query=query.eq('card_id',cardId);
    const {data,error}=await query;
    if(error)throw error;
    return data||[];
  }

  async function create({cardId,label,placement='paper_card',notes=''}){
    if(!state.session?.user?.id)throw new Error('Inicia sesión para crear un NFC.');
    const card=state.cards.find(item=>item.id===cardId);
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

  function instructions(){return `<div class="panel"><h2>Cómo programar el sticker</h2><ol><li>Crea y asigna aquí el NFC a una Digital Card.</li><li>Copia la URL de programación.</li><li>En un teléfono Android con NFC, abre tu aplicación de escritura NFC.</li><li>Escribe la URL como registro URL/URI en el NTAG213.</li><li>No bloquees el chip durante las pruebas.</li><li>Prueba el sticker con otro Android y con iPhone.</li></ol><p class="readonly-note">La URL del NFC es permanente. Los cambios posteriores de teléfono, WhatsApp, redes o contenido se hacen en la Digital Card sin reprogramar el sticker.</p></div>`}

  function form(){const options=state.cards.filter(c=>c.status==='published').map(c=>`<option value="${esc(c.id)}">${esc(c.name)} · /c/${esc(c.slug)}</option>`).join('');return `<form class="panel" id="nfc-create-form"><h2>Asignar nuevo NFC</h2>${options?`<div class="formgrid"><div class="field"><label>Digital Card</label><select name="cardId" required>${options}</select></div><div class="field"><label>Uso físico</label><select name="placement">${placements.map(([v,l])=>`<option value="${v}">${l}</option>`).join('')}</select></div><div class="field full"><label>Nombre interno</label><input name="label" maxlength="80" placeholder="Ej. Tarjeta opalina 01" value="NFC"></div><div class="field full"><label>Notas</label><input name="notes" maxlength="250" placeholder="Opcional"></div></div><button class="primary" type="submit">Crear NFC</button>`:'<p>Publica primero una Digital Card para poder asignarle un NFC.</p>'}</form>`}

  function table(tags){if(!tags.length)return '<div class="panel empty">Todavía no hay stickers NFC registrados.</div>';return `<div class="panel table-wrap"><table class="table"><thead><tr><th>NFC</th><th>Uso</th><th>Chip</th><th>Lecturas</th><th>Estado</th><th>Programación</th></tr></thead><tbody>${tags.map(tag=>`<tr><td><b>${esc(tag.label)}</b><small class="entity-slug">${esc(tag.id.slice(0,8))}</small></td><td>${esc(placementLabel(tag.placement))}</td><td>${esc(tag.chip_type)}</td><td><b>${Number(tag.tap_count||0)}</b><small class="entity-slug">${tag.last_tapped_at?'Última: '+esc(new Date(tag.last_tapped_at).toLocaleString('es-MX')):'Sin lecturas'}</small></td><td><span class="badge">${esc(statusLabel(tag.status))}</span></td><td><div class="team-actions"><button class="ghost" data-nfc-copy="${esc(tag.id)}">Copiar URL</button><select data-nfc-status="${esc(tag.id)}"><option value="active" ${tag.status==='active'?'selected':''}>Activo</option><option value="inactive" ${tag.status==='inactive'?'selected':''}>Inactivo</option><option value="lost" ${tag.status==='lost'?'selected':''}>Perdido</option><option value="replaced" ${tag.status==='replaced'?'selected':''}>Reemplazado</option></select></div></td></tr>`).join('')}</tbody></table></div>`}

  async function mount(container){
    if(!container)return;
    container.innerHTML='<div class="panel">Cargando NFC…</div>';
    try{
      const tags=await list();
      container.innerHTML=`<div class="top"><div><h1>Mis NFC</h1><p>Administra stickers y tarjetas NFC vinculados a tus Digital Cards.</p></div></div><div class="editor" style="align-items:start"><div>${form()}<div style="height:16px"></div>${table(tags)}</div>${instructions()}</div>`;
      const createForm=container.querySelector('#nfc-create-form');
      createForm?.addEventListener('submit',async event=>{event.preventDefault();const button=createForm.querySelector('button[type=submit]'),fd=new FormData(createForm);button.disabled=true;try{const tag=await create({cardId:String(fd.get('cardId')||''),placement:String(fd.get('placement')||'paper_card'),label:String(fd.get('label')||'NFC'),notes:String(fd.get('notes')||'')});await copyUrl(tag);toast('NFC creado. URL de programación copiada.');await mount(container)}catch(error){toast('No se pudo crear el NFC: '+(error?.message||'Error desconocido'))}finally{button.disabled=false}});
      container.querySelectorAll('[data-nfc-copy]').forEach(button=>button.addEventListener('click',async()=>{const tag=tags.find(x=>x.id===button.dataset.nfcCopy);if(!tag)return;try{await copyUrl(tag);toast('URL NFC copiada.')}catch{toast('No se pudo copiar la URL NFC.')}}));
      container.querySelectorAll('[data-nfc-status]').forEach(select=>select.addEventListener('change',async()=>{try{await setStatus(select.dataset.nfcStatus,select.value);toast('Estado NFC actualizado.');await mount(container)}catch(error){toast('No se pudo actualizar el NFC: '+(error?.message||'Error desconocido'))}}));
    }catch(error){container.innerHTML=`<div class="panel"><h2>No se pudo cargar Mis NFC</h2><p>${esc(error?.message||'Error desconocido')}</p></div>`}
  }

  window.MXNfc={list,create,setStatus,nfcUrl,mount};
})();
