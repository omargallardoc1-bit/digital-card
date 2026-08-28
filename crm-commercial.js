(()=>{
  'use strict';

  const t=(es,en)=>typeof language!=='undefined'&&language==='en'?en:es;
  const esc=value=>String(value??'').replace(/[&<>'"]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[ch]));
  const statusMeta={
    new:{es:'Nuevo',en:'New'},
    contacted:{es:'Contactado',en:'Contacted'},
    follow_up:{es:'Seguimiento',en:'Follow-up'},
    customer:{es:'Cliente',en:'Customer'},
    discarded:{es:'Descartado',en:'Discarded'}
  };
  const tagMeta={prospect:'Prospecto',customer:'Cliente',supplier:'Proveedor',alliance:'Alianza',other:'Otro'};
  const statusLabel=s=>statusMeta[s]?.[typeof language!=='undefined'&&language==='en'?'en':'es']||s||'—';
  const localDateTime=value=>{
    if(!value)return '';
    const d=new Date(value);if(Number.isNaN(d.getTime()))return '';
    const pad=n=>String(n).padStart(2,'0');
    return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
  };
  const displayDate=value=>{
    if(!value)return '—';const d=new Date(value);if(Number.isNaN(d.getTime()))return '—';
    return new Intl.DateTimeFormat(typeof language!=='undefined'&&language==='en'?'en-US':'es-MX',{dateStyle:'medium',timeStyle:'short'}).format(d);
  };
  const cleanPhone=value=>String(value||'').replace(/[^0-9+]/g,'');
  const waPhone=value=>String(value||'').replace(/\D/g,'');

  function ensure(){
    if(typeof state==='undefined')return false;
    if(!('crmSelectedProspectId' in state))state.crmSelectedProspectId=null;
    if(!('crmFunnel' in state))state.crmFunnel=null;
    if(!('crmFunnelLoading' in state))state.crmFunnelLoading=false;
    return true;
  }

  async function loadFunnel(){
    if(!ensure()||!state.session||!state.organization?.id)return;
    state.crmFunnelLoading=true;
    const {data,error}=await db.rpc('get_organization_prospect_funnel',{
      target_organization_id:state.organization.id,
      target_card_id:state.prospectsCard==='all'?null:state.prospectsCard
    });
    state.crmFunnelLoading=false;
    if(!error)state.crmFunnel=data||{};
  }

  function funnel(){
    const f=state.crmFunnel||{};
    const cards=[
      ['new',t('Nuevos','New'),f.new||0],
      ['contacted',t('Contactados','Contacted'),f.contacted||0],
      ['follow_up',t('Seguimiento','Follow-up'),f.follow_up||0],
      ['customer',t('Clientes','Customers'),f.customers||0],
      ['discarded',t('Descartados','Discarded'),f.discarded||0]
    ];
    return `<div class="crm-funnel">${cards.map(([key,label,count])=>`<button type="button" class="crm-funnel-card" onclick="crmFocusStatus('${key}')"><span>${esc(label)}</span><b>${esc(count)}</b></button>`).join('')}</div>`;
  }

  function actions(p){
    const tel=cleanPhone(p.phone),wa=waPhone(p.phone);
    return `<div class="crm-contact-actions">${wa?`<a class="crm-action crm-wa" href="https://wa.me/${encodeURIComponent(wa)}" target="_blank" rel="noopener">WhatsApp</a>`:''}${tel?`<a class="crm-action" href="tel:${encodeURIComponent(tel)}">${esc(t('Llamar','Call'))}</a>`:''}<button class="crm-action" type="button" onclick="openCrmProspect('${esc(p.id)}')">${esc(t('Gestionar','Manage'))}</button></div>`;
  }

  function prospectCards(){
    if(state.prospectsLoading)return `<div class="empty">${esc(t('Cargando prospectos…','Loading prospects…'))}</div>`;
    if(!state.prospects.length)return `<div class="empty">${esc(t('Aún no hay prospectos para tus tarjetas.','There are no prospects for your cards yet.'))}</div>`;
    return `<div class="crm-list">${state.prospects.map(p=>`<article class="crm-card" data-status="${esc(p.status||'new')}">
      <div class="crm-card-head"><div><strong>${esc(p.name)}</strong><small>${esc(p.card_name||'—')}</small></div><span class="crm-status crm-${esc(p.status||'new')}">${esc(statusLabel(p.status||'new'))}</span></div>
      <div class="crm-card-grid"><div><span>${esc(t('Teléfono','Phone'))}</span><b>${esc(p.phone||'—')}</b></div><div><span>${esc(t('Próximo seguimiento','Next follow-up'))}</span><b>${esc(displayDate(p.next_follow_up_at))}</b></div><div><span>${esc(t('Origen','Source'))}</span><b>${esc(p.source||'—')}</b></div><div><span>${esc(t('Actualizado','Updated'))}</span><b>${esc(displayDate(p.updated_at||p.created_at))}</b></div></div>
      ${p.notes?`<p class="crm-note-preview">${esc(p.notes)}</p>`:''}
      ${actions(p)}
    </article>`).join('')}</div>`;
  }

  function editor(){
    const p=state.prospects.find(item=>item.id===state.crmSelectedProspectId);
    if(!p)return '';
    return `<div class="crm-editor-backdrop" onclick="if(event.target===this)closeCrmProspect()"><section class="crm-editor" role="dialog" aria-modal="true" aria-label="${esc(t('Gestionar prospecto','Manage prospect'))}">
      <div class="crm-editor-head"><div><small>${esc(t('Prospecto','Prospect'))}</small><h2>${esc(p.name)}</h2><p>${esc(p.phone||'')}${p.email?` · ${esc(p.email)}`:''}</p></div><button class="ghost" type="button" onclick="closeCrmProspect()">×</button></div>
      <form onsubmit="saveCrmProspect(event,'${esc(p.id)}')">
        <div class="formgrid">
          <div class="field"><label>${esc(t('Etapa comercial','Sales stage'))}</label><select name="status">${Object.keys(statusMeta).map(s=>`<option value="${s}" ${p.status===s?'selected':''}>${esc(statusLabel(s))}</option>`).join('')}</select></div>
          <div class="field"><label>${esc(t('Etiqueta','Tag'))}</label><select name="tag"><option value="">${esc(t('Sin etiqueta','No tag'))}</option>${Object.entries(tagMeta).map(([k,v])=>`<option value="${k}" ${p.tag===k?'selected':''}>${esc(v)}</option>`).join('')}</select></div>
          <div class="field full"><label>${esc(t('Próximo seguimiento','Next follow-up'))}</label><input name="next_follow_up_at" type="datetime-local" value="${esc(localDateTime(p.next_follow_up_at))}"></div>
          <div class="field full"><label>${esc(t('Notas comerciales','Sales notes'))}</label><textarea name="notes" maxlength="4000" placeholder="${esc(t('Acuerdos, necesidades, objeciones, siguiente paso…','Agreements, needs, objections, next step…'))}">${esc(p.notes||'')}</textarea></div>
        </div>
        <div id="crm-editor-error" class="error" role="alert"></div>
        <div class="crm-editor-actions">${actions(p)}<button class="primary" type="submit">${esc(t('Guardar seguimiento','Save follow-up'))}</button></div>
      </form>
    </section></div>`;
  }

  function view(){
    if(typeof canViewOrganizationProspectPii==='function'&&!canViewOrganizationProspectPii())return `<div class="top"><div><h1>CRM</h1><p>${esc(t('Tu rol no incluye acceso a datos personales de prospectos.','Your role does not include access to prospect personal data.'))}</p></div></div>`;
    const pages=Math.max(1,Math.ceil((state.prospectsTotal||0)/(state.prospectsPageSize||50)));
    return `<div class="top"><div><h1>${esc(t('CRM Comercial','Sales CRM'))}</h1><p>${esc(t('Da seguimiento a contactos, próxima acción y avance comercial desde un solo lugar.','Track contacts, next actions and sales progress from one place.'))}</p></div><button class="primary" onclick="exportProspectsCsv()" ${state.prospectsTotal&&!state.prospectsLoading?'':'disabled'}>${esc(t('Exportar CSV','Export CSV'))}</button></div>
      ${funnel()}
      <div class="panel crm-panel"><div class="filters"><div class="field"><label>${esc(t('Tarjeta','Card'))}</label><select onchange="setProspectsCard(this.value)"><option value="all">${esc(t('Todas las tarjetas','All cards'))}</option>${state.organizationCards.map(card=>`<option value="${esc(card.id)}" ${state.prospectsCard===card.id?'selected':''}>${esc(card.name)}</option>`).join('')}</select></div><div class="field"><label>${esc(t('Orden','Order'))}</label><select onchange="setProspectsSort(this.value)"><option value="desc" ${state.prospectsSort==='desc'?'selected':''}>${esc(t('Más recientes','Newest'))}</option><option value="asc" ${state.prospectsSort==='asc'?'selected':''}>${esc(t('Más antiguos','Oldest'))}</option></select></div></div>${prospectCards()}<div class="crm-pagination"><span>${esc(t('Página','Page'))} ${esc(state.prospectsPage)} / ${esc(pages)} · ${esc(state.prospectsTotal)} ${esc(t('prospectos','prospects'))}</span><div><button class="ghost" onclick="changeProspectsPage(-1)" ${state.prospectsPage<=1?'disabled':''}>${esc(t('Anterior','Previous'))}</button><button class="ghost" onclick="changeProspectsPage(1)" ${state.prospectsPage>=pages?'disabled':''}>${esc(t('Siguiente','Next'))}</button></div></div></div>${editor()}`;
  }

  window.openCrmProspect=id=>{ensure();state.crmSelectedProspectId=id;window.render?.()};
  window.closeCrmProspect=()=>{state.crmSelectedProspectId=null;window.render?.()};
  window.crmFocusStatus=status=>{document.querySelectorAll('.crm-card').forEach(card=>{card.style.display=card.dataset.status===status?'':'none'});};

  window.saveCrmProspect=async function(event,id){
    event.preventDefault();
    const form=event.currentTarget,button=form.querySelector('button[type="submit"]'),errorEl=document.getElementById('crm-editor-error');
    const values=new FormData(form),rawFollow=String(values.get('next_follow_up_at')||'').trim();
    let follow=null;if(rawFollow){const d=new Date(rawFollow);if(Number.isNaN(d.getTime())){errorEl.textContent=t('La fecha de seguimiento no es válida.','The follow-up date is invalid.');return;}follow=d.toISOString();}
    button.disabled=true;errorEl.textContent='';
    const {data,error}=await db.rpc('update_organization_prospect',{
      target_organization_id:state.organization.id,target_prospect_id:id,
      new_status:String(values.get('status')||'new'),new_tag:String(values.get('tag')||''),
      new_notes:String(values.get('notes')||''),new_next_follow_up_at:follow
    });
    button.disabled=false;
    if(error){errorEl.textContent=error.message||t('No se pudo guardar el seguimiento.','Could not save follow-up.');return;}
    const index=state.prospects.findIndex(p=>p.id===id);if(index>=0)state.prospects[index]={...state.prospects[index],...(data||{})};
    await loadFunnel();
    state.crmSelectedProspectId=null;
    window.toast?.(t('Seguimiento guardado.','Follow-up saved.'));
    window.render?.();
  };

  function styles(){
    if(document.getElementById('crm-commercial-styles'))return;
    const s=document.createElement('style');s.id='crm-commercial-styles';s.textContent=`
      .crm-funnel{display:grid;grid-template-columns:repeat(5,minmax(130px,1fr));gap:10px;margin:0 0 18px}.crm-funnel-card{background:#fff;border:1px solid var(--line);border-radius:13px;padding:14px;text-align:left;box-shadow:var(--shadow-surface)}.crm-funnel-card span{display:block;color:var(--muted);font-size:12px}.crm-funnel-card b{font-size:24px}.crm-panel{display:grid;gap:16px}.crm-list{display:grid;gap:12px}.crm-card{border:1px solid var(--line);border-radius:13px;padding:14px;background:#fff}.crm-card-head{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}.crm-card-head strong{display:block;font-size:16px}.crm-card-head small{color:var(--muted)}.crm-status{padding:5px 9px;border-radius:999px;font-size:12px;font-weight:800;background:#eef2ff}.crm-new{color:#4338ca}.crm-contacted{color:#175cd3;background:#eff8ff}.crm-follow_up{color:#a16207;background:#fff7df}.crm-customer{color:#15803d;background:#eaf8f0}.crm-discarded{color:#667085;background:#f2f4f7}.crm-card-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin:14px 0}.crm-card-grid span{display:block;color:var(--muted);font-size:11px}.crm-card-grid b{font-size:13px}.crm-note-preview{padding:10px 12px;background:var(--surface-muted);border-radius:9px;white-space:pre-wrap;margin:0 0 12px}.crm-contact-actions{display:flex;gap:8px;flex-wrap:wrap}.crm-action{display:inline-flex;align-items:center;justify-content:center;padding:8px 11px;border:1px solid var(--line);border-radius:9px;background:#fff;color:var(--text);text-decoration:none;font-weight:700;font-size:12px}.crm-wa{background:#16a85b;color:#fff;border-color:#16a85b}.crm-pagination{display:flex;justify-content:space-between;gap:12px;align-items:center;color:var(--muted);font-size:13px}.crm-pagination div{display:flex;gap:8px}.crm-editor-backdrop{position:fixed;inset:0;background:#10182877;z-index:100;display:flex;justify-content:flex-end}.crm-editor{width:min(520px,100%);height:100%;overflow:auto;background:#fff;padding:22px;box-shadow:-15px 0 40px #10182822}.crm-editor-head{display:flex;justify-content:space-between;gap:12px;margin-bottom:18px}.crm-editor-head h2{margin:2px 0}.crm-editor-head p{margin:0;color:var(--muted)}.crm-editor-actions{display:flex;justify-content:space-between;gap:12px;align-items:center;flex-wrap:wrap}.crm-editor-actions>.crm-contact-actions{flex:1}@media(max-width:900px){.crm-funnel{grid-template-columns:repeat(2,1fr)}.crm-card-grid{grid-template-columns:repeat(2,1fr)}}@media(max-width:600px){.crm-funnel{grid-template-columns:1fr 1fr}.crm-card-grid{grid-template-columns:1fr}.crm-pagination{align-items:flex-start;flex-direction:column}.crm-editor{padding:16px}}
    `;document.head.appendChild(s);
  }

  function install(){
    if(!ensure()||typeof window.prospectsView!=='function'||window.__crmCommercialInstalled)return false;
    window.__crmCommercialInstalled=true;styles();
    const originalLoad=window.loadProspects;
    if(typeof originalLoad==='function')window.loadProspects=async function(){const result=await originalLoad.apply(this,arguments);await loadFunnel();if(state.page==='prospects')window.render?.();return result};
    window.prospectsView=view;
    if(state.page==='prospects')loadFunnel().then(()=>window.render?.());
    return true;
  }

  const timer=setInterval(()=>{if(install())clearInterval(timer)},25);setTimeout(()=>clearInterval(timer),5000);
})();
