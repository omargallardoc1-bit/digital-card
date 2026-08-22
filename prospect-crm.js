(()=>{
  const CRM_STATUSES=Object.freeze([
    ['new','Nuevo','New'],
    ['contacted','Contactado','Contacted'],
    ['follow_up','Seguimiento','Follow-up'],
    ['customer','Cliente','Customer'],
    ['discarded','Descartado','Discarded']
  ]);
  const CRM_TAGS=Object.freeze([
    ['','Sin etiqueta','No tag'],
    ['prospect','Prospecto','Prospect'],
    ['customer','Cliente','Customer'],
    ['supplier','Proveedor','Supplier'],
    ['alliance','Alianza','Alliance'],
    ['other','Otro','Other']
  ]);

  const t=(es,en)=>language==='en'?en:es;
  const statusLabel=value=>CRM_STATUSES.find(item=>item[0]===value)?.[language==='en'?2:1]||value||t('Nuevo','New');
  const tagLabel=value=>CRM_TAGS.find(item=>item[0]===(value||''))?.[language==='en'?2:1]||value||t('Sin etiqueta','No tag');
  const statusClass=value=>({new:'info',contacted:'warning',follow_up:'draft',customer:'active',discarded:'archived'})[value]||'info';
  const localDateTime=value=>{
    if(!value)return '';
    const date=new Date(value);
    if(Number.isNaN(date.getTime()))return '';
    const pad=n=>String(n).padStart(2,'0');
    return `${date.getFullYear()}-${pad(date.getMonth()+1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
  };
  const isoOrNull=value=>{
    const raw=String(value||'').trim();
    if(!raw)return null;
    const date=new Date(raw);
    return Number.isNaN(date.getTime())?null:date.toISOString();
  };

  function injectCrmStyles(){
    if(document.getElementById('mx-prospect-crm-style'))return;
    const style=document.createElement('style');
    style.id='mx-prospect-crm-style';
    style.textContent=`
      .crm-toolbar{display:flex;flex-wrap:wrap;gap:var(--space-3);align-items:end;margin-bottom:var(--space-5)}
      .crm-toolbar .field{margin:0;min-width:170px;flex:1 1 170px}.crm-toolbar .field.crm-grow{flex:2 1 240px}.crm-toolbar .primary{flex:0 0 auto}
      .crm-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:var(--space-4)}
      .crm-card{display:grid;gap:var(--space-4);padding:var(--space-5);border:1px solid var(--border-default);border-radius:var(--radius-card);background:var(--surface-card);box-shadow:var(--shadow-surface)}
      .crm-card-head{display:flex;justify-content:space-between;align-items:flex-start;gap:var(--space-3)}
      .crm-identity{min-width:0}.crm-identity strong,.crm-identity span,.crm-identity small{display:block;overflow-wrap:anywhere}.crm-identity strong{font-size:16px}.crm-identity span{color:var(--text-secondary);margin-top:2px}.crm-identity small{color:var(--text-muted);margin-top:3px}
      .crm-contact{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:var(--space-3);padding:var(--space-3);border-radius:var(--radius-control);background:var(--surface-muted)}
      .crm-contact div{min-width:0}.crm-contact span,.crm-contact strong{display:block}.crm-contact span{font-size:11px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.03em}.crm-contact strong{font-size:13px;overflow-wrap:anywhere;margin-top:2px}
      .crm-form{display:grid;grid-template-columns:1fr 1fr;gap:var(--space-3)}.crm-form .field{margin:0}.crm-form .crm-full{grid-column:1/-1}.crm-form textarea{min-height:86px}
      .crm-actions{display:flex;gap:var(--space-2);align-items:center;justify-content:flex-end;padding-top:var(--space-3);border-top:1px solid var(--border-default)}
      .crm-followup-due{color:var(--semantic-warning);font-weight:700}.crm-followup-overdue{color:var(--semantic-danger);font-weight:700}
      .crm-empty-note{margin:0;color:var(--text-muted);font-size:12px}
      @media(max-width:1000px){.crm-grid{grid-template-columns:1fr}}
      @media(max-width:600px){.crm-card{padding:var(--space-4)}.crm-contact,.crm-form{grid-template-columns:1fr}.crm-form .crm-full{grid-column:auto}.crm-actions{display:grid}.crm-actions .primary{width:100%}}
    `;
    document.head.appendChild(style);
  }

  function followUpDisplay(value){
    if(!value)return t('Sin seguimiento programado','No follow-up scheduled');
    const date=new Date(value);
    if(Number.isNaN(date.getTime()))return '—';
    const overdue=date.getTime()<Date.now();
    return `<span class="${overdue?'crm-followup-overdue':'crm-followup-due'}">${esc(formatDate(value))}</span>`;
  }

  function statusOptions(selected){
    return CRM_STATUSES.map(([value,es,en])=>`<option value="${value}" ${selected===value?'selected':''}>${esc(language==='en'?en:es)}</option>`).join('');
  }
  function tagOptions(selected){
    return CRM_TAGS.map(([value,es,en])=>`<option value="${value}" ${(selected||'')===value?'selected':''}>${esc(language==='en'?en:es)}</option>`).join('');
  }

  function prospectCrmCard(p){
    const id=String(p.id||'');
    const followup=p.next_follow_up_at?followUpDisplay(p.next_follow_up_at):t('Sin seguimiento programado','No follow-up scheduled');
    return `<article class="crm-card" data-prospect-id="${esc(id)}">
      <header class="crm-card-head">
        <div class="crm-identity"><strong>${esc(p.name||t('Sin nombre','Unnamed'))}</strong><span>${esc(p.card_name||t('Tarjeta no disponible','Card unavailable'))}</span><small>${esc(t('Captado','Captured'))}: ${esc(formatDate(p.created_at))} · ${esc(t('Origen','Source'))}: ${esc(p.source||'—')}</small></div>
        <span class="badge ${statusClass(p.status||'new')}">${esc(statusLabel(p.status||'new'))}</span>
      </header>
      <div class="crm-contact">
        <div><span>${esc(t('Teléfono','Phone'))}</span><strong>${esc(p.phone||'—')}</strong></div>
        <div><span>${esc(t('Correo','Email'))}</span><strong>${esc(p.email||'—')}</strong></div>
        <div><span>${esc(t('Etiqueta','Tag'))}</span><strong>${esc(tagLabel(p.tag))}</strong></div>
        <div><span>${esc(t('Próximo seguimiento','Next follow-up'))}</span><strong>${followup}</strong></div>
      </div>
      <div class="crm-form">
        <div class="field"><label for="crm-status-${esc(id)}">${esc(t('Estado','Status'))}</label><select id="crm-status-${esc(id)}">${statusOptions(p.status||'new')}</select></div>
        <div class="field"><label for="crm-tag-${esc(id)}">${esc(t('Etiqueta','Tag'))}</label><select id="crm-tag-${esc(id)}">${tagOptions(p.tag)}</select></div>
        <div class="field crm-full"><label for="crm-followup-${esc(id)}">${esc(t('Próximo seguimiento','Next follow-up'))}</label><input id="crm-followup-${esc(id)}" type="datetime-local" value="${esc(localDateTime(p.next_follow_up_at))}"><small>${esc(t('Déjalo vacío para quitar el recordatorio.','Leave blank to clear the reminder.'))}</small></div>
        <div class="field crm-full"><label for="crm-notes-${esc(id)}">${esc(t('Notas','Notes'))}</label><textarea id="crm-notes-${esc(id)}" maxlength="4000" placeholder="${esc(t('Ej. Solicitó información del paquete PyME.','E.g. Asked for information about the PyME plan.'))}">${esc(p.notes||'')}</textarea></div>
      </div>
      <div class="crm-actions"><span class="crm-empty-note">${p.consent_given?esc(t('Consentimiento registrado','Consent recorded')):esc(t('Sin consentimiento registrado','No recorded consent'))}</span><button class="primary" type="button" onclick="saveProspectCrm('${esc(id)}')">${uiIcon('save')}<span>${esc(t('Guardar seguimiento','Save follow-up'))}</span></button></div>
    </article>`;
  }

  window.saveProspectCrm=async function(prospectId){
    if(!state.session||!state.organization?.id||!canViewOrganizationProspectPii())return;
    const prospect=state.prospects.find(item=>item.id===prospectId);
    if(!prospect)return;
    const card=document.querySelector(`.crm-card[data-prospect-id="${CSS.escape(prospectId)}"]`);
    if(!card)return;
    const button=card.querySelector('.crm-actions .primary');
    const status=card.querySelector(`#crm-status-${CSS.escape(prospectId)}`)?.value||'new';
    const tag=card.querySelector(`#crm-tag-${CSS.escape(prospectId)}`)?.value||'';
    const notes=card.querySelector(`#crm-notes-${CSS.escape(prospectId)}`)?.value??'';
    const followupRaw=card.querySelector(`#crm-followup-${CSS.escape(prospectId)}`)?.value||'';
    const followup=isoOrNull(followupRaw);
    if(followupRaw&&!followup){toast(t('La fecha de seguimiento no es válida.','The follow-up date is invalid.'));return}
    button.disabled=true;
    const {data,error}=await db.rpc('update_organization_prospect',{
      target_organization_id:state.organization.id,
      target_prospect_id:prospectId,
      new_status:status,
      new_tag:tag,
      new_notes:notes,
      new_next_follow_up_at:followup
    });
    button.disabled=false;
    if(error){toast(t('No se pudo actualizar el prospecto: ','Could not update prospect: ')+error.message);return}
    const result=Array.isArray(data)?data[0]:data;
    if(result&&typeof result==='object')Object.assign(prospect,result);
    toast(t('Prospecto actualizado correctamente.','Prospect updated successfully.'));
    render();
  };

  window.prospectsView=function(){
    injectCrmStyles();
    if(!canViewOrganizationProspectPii())return '<div class="top"><div><h1>'+esc(t('Prospectos','Prospects'))+'</h1><p>'+esc(t('Tu rol no incluye acceso a datos personales de prospectos.','Your role does not include access to prospect personal data.'))+'</p></div></div><div class="panel empty">'+esc(t('Los prospectos están disponibles para owner, admin y editor.','Prospects are available to owner, admin and editor.'))+'</div>';
    const pages=Math.max(1,Math.ceil(state.prospectsTotal/state.prospectsPageSize));
    const toolbar=`<div class="crm-toolbar">
      <div class="field crm-grow"><label for="prospects-card">${esc(t('Tarjeta','Card'))}</label><select id="prospects-card" onchange="setProspectsCard(this.value)"><option value="all">${esc(t('Todas las tarjetas','All cards'))}</option>${state.organizationCards.map(card=>`<option value="${esc(card.id)}" ${state.prospectsCard===card.id?'selected':''}>${esc(card.name)}</option>`).join('')}</select></div>
      <div class="field"><label for="prospects-sort">${esc(t('Orden','Order'))}</label><select id="prospects-sort" onchange="setProspectsSort(this.value)"><option value="desc" ${state.prospectsSort==='desc'?'selected':''}>${esc(t('Más recientes','Newest first'))}</option><option value="asc" ${state.prospectsSort==='asc'?'selected':''}>${esc(t('Más antiguos','Oldest first'))}</option></select></div>
      <div class="field"><label for="prospects-page-size">${esc(t('Filas','Rows'))}</label><select id="prospects-page-size" onchange="setProspectsPageSize(this.value)"><option value="25" ${state.prospectsPageSize===25?'selected':''}>25</option><option value="50" ${state.prospectsPageSize===50?'selected':''}>50</option><option value="100" ${state.prospectsPageSize===100?'selected':''}>100</option></select></div>
      <button class="primary" onclick="exportProspectsCsv()" ${state.prospectsTotal&&!state.prospectsLoading?'':'disabled'}>${uiIcon('download')}<span>${esc(t('Exportar CSV','Export CSV'))}</span></button>
    </div>`;
    const content=state.prospectsLoading?`<div class="empty">${esc(t('Cargando prospectos…','Loading prospects…'))}</div>`:state.prospects.length?`<div class="crm-grid">${state.prospects.map(prospectCrmCard).join('')}</div>`:`<div class="empty">${esc(t('Aún no hay prospectos para tus Digital Cards.','There are no prospects for your Digital Cards yet.'))}</div>`;
    return `<div class="top"><div><h1>${esc(t('Prospectos','Prospects'))}</h1><p>${esc(t('Gestiona contactos, estados, notas y próximos seguimientos.','Manage contacts, statuses, notes and next follow-ups.'))}</p></div></div><div class="panel">${toolbar}${content}<div class="top prospects-pagination" style="margin:20px 0 0"><p>${esc(t('Página','Page'))} ${esc(state.prospectsPage)} ${esc(t('de','of'))} ${esc(pages)} · ${esc(state.prospectsTotal)} ${esc(t('prospectos','prospects'))}</p><div><button class="ghost" onclick="changeProspectsPage(-1)" ${state.prospectsPage<=1||state.prospectsLoading?'disabled':''}>${esc(t('Anterior','Previous'))}</button> <button class="ghost" onclick="changeProspectsPage(1)" ${state.prospectsPage>=pages||state.prospectsLoading?'disabled':''}>${esc(t('Siguiente','Next'))}</button></div></div></div>`;
  };

  // Keep the legacy table helper available but point it to the CRM cards if another view calls it.
  window.prospectsTable=function(){return state.prospects.length?`<div class="crm-grid">${state.prospects.map(prospectCrmCard).join('')}</div>`:`<div class="empty">${esc(t('Aún no hay prospectos para tus Digital Cards.','There are no prospects for your Digital Cards yet.'))}</div>`};

  if(state?.session&&state.page==='prospects')render();
})();
