(()=>{
  'use strict';
  if(typeof state==='undefined'||typeof db==='undefined'||typeof window.prospectsView!=='function')return;
  if(window.__crmCommercialSafeInstalled)return;
  window.__crmCommercialSafeInstalled=true;

  const t=(es,en)=>typeof language!=='undefined'&&language==='en'?en:es;
  const esc=value=>String(value??'').replace(/[&<>'"]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[ch]));
  const statusMeta={new:t('Nuevo','New'),contacted:t('Contactado','Contacted'),follow_up:t('Seguimiento','Follow-up'),customer:t('Cliente','Customer'),discarded:t('Descartado','Discarded')};
  const tagMeta={prospect:t('Prospecto','Prospect'),customer:t('Cliente','Customer'),supplier:t('Proveedor','Supplier'),alliance:t('Alianza','Alliance'),other:t('Otro','Other')};
  const fmt=value=>{if(!value)return '—';const d=new Date(value);if(Number.isNaN(d.getTime()))return '—';return new Intl.DateTimeFormat(typeof language!=='undefined'&&language==='en'?'en-US':'es-MX',{dateStyle:'medium',timeStyle:'short'}).format(d)};
  const local=value=>{if(!value)return '';const d=new Date(value);if(Number.isNaN(d.getTime()))return '';const p=n=>String(n).padStart(2,'0');return `${d.getFullYear()}-${p(d.getMonth()+1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`};
  const phoneDigits=value=>String(value||'').replace(/\D/g,'');

  if(!('crmSelectedProspectId' in state))state.crmSelectedProspectId=null;
  if(!('crmFunnel' in state))state.crmFunnel=null;

  async function loadFunnel(){
    if(!state.session||!state.organization?.id)return;
    const {data,error}=await db.rpc('get_organization_prospect_funnel',{target_organization_id:state.organization.id,target_card_id:state.prospectsCard==='all'?null:state.prospectsCard});
    if(!error)state.crmFunnel=data||{};
  }

  function funnel(){
    const f=state.crmFunnel||{};
    const cards=[[t('Nuevos','New'),f.new||0],[t('Contactados','Contacted'),f.contacted||0],[t('Seguimiento','Follow-up'),f.follow_up||0],[t('Clientes','Customers'),f.customers||0],[t('Descartados','Discarded'),f.discarded||0]];
    return `<div class="crm-safe-funnel">${cards.map(([label,count])=>`<div class="crm-safe-metric"><span>${esc(label)}</span><b>${esc(count)}</b></div>`).join('')}</div>`;
  }

  function actions(p){
    const wa=phoneDigits(p.phone),tel=String(p.phone||'').replace(/[^0-9+]/g,'');
    return `<div class="crm-safe-actions">${wa?`<a class="crm-safe-action crm-safe-wa" href="https://wa.me/${encodeURIComponent(wa)}" target="_blank" rel="noopener">WhatsApp</a>`:''}${tel?`<a class="crm-safe-action" href="tel:${encodeURIComponent(tel)}">${esc(t('Llamar','Call'))}</a>`:''}<button class="crm-safe-action" type="button" onclick="openCrmSafeProspect('${esc(p.id)}')">${esc(t('Gestionar','Manage'))}</button></div>`;
  }

  function cards(){
    if(state.prospectsLoading)return `<div class="empty">${esc(t('Cargando prospectos…','Loading prospects…'))}</div>`;
    if(!state.prospects?.length)return `<div class="empty">${esc(t('Aún no hay prospectos.','There are no prospects yet.'))}</div>`;
    return `<div class="crm-safe-list">${state.prospects.map(p=>`<article class="crm-safe-card"><div class="crm-safe-head"><div><strong>${esc(p.name||'—')}</strong><small>${esc(p.card_name||'—')}</small></div><span class="crm-safe-status">${esc(statusMeta[p.status]||p.status||statusMeta.new)}</span></div><div class="crm-safe-grid"><div><span>${esc(t('Teléfono','Phone'))}</span><b>${esc(p.phone||'—')}</b></div><div><span>${esc(t('Próximo seguimiento','Next follow-up'))}</span><b>${esc(fmt(p.next_follow_up_at))}</b></div><div><span>${esc(t('Origen','Source'))}</span><b>${esc(p.source||'—')}</b></div></div>${p.notes?`<p class="crm-safe-note">${esc(p.notes)}</p>`:''}${actions(p)}</article>`).join('')}</div>`;
  }

  function editor(){
    const p=state.prospects?.find(x=>x.id===state.crmSelectedProspectId);if(!p)return '';
    return `<div class="crm-safe-backdrop" onclick="if(event.target===this)closeCrmSafeProspect()"><section class="crm-safe-editor" role="dialog" aria-modal="true"><div class="crm-safe-editor-head"><div><small>${esc(t('Prospecto','Prospect'))}</small><h2>${esc(p.name||'—')}</h2><p>${esc(p.phone||'')}${p.email?` · ${esc(p.email)}`:''}</p></div><button class="ghost" type="button" onclick="closeCrmSafeProspect()">×</button></div><form onsubmit="saveCrmSafeProspect(event,'${esc(p.id)}')"><div class="formgrid"><div class="field"><label>${esc(t('Etapa comercial','Sales stage'))}</label><select name="status">${Object.entries(statusMeta).map(([key,label])=>`<option value="${key}" ${p.status===key?'selected':''}>${esc(label)}</option>`).join('')}</select></div><div class="field"><label>${esc(t('Etiqueta','Tag'))}</label><select name="tag"><option value="">${esc(t('Sin etiqueta','No tag'))}</option>${Object.entries(tagMeta).map(([key,label])=>`<option value="${key}" ${p.tag===key?'selected':''}>${esc(label)}</option>`).join('')}</select></div><div class="field full"><label>${esc(t('Próximo seguimiento','Next follow-up'))}</label><input name="next_follow_up_at" type="datetime-local" value="${esc(local(p.next_follow_up_at))}"></div><div class="field full"><label>${esc(t('Notas comerciales','Sales notes'))}</label><textarea name="notes" maxlength="4000">${esc(p.notes||'')}</textarea></div></div><div id="crm-safe-error" class="error" role="alert"></div><div class="crm-safe-editor-actions">${actions(p)}<button class="primary" type="submit">${esc(t('Guardar seguimiento','Save follow-up'))}</button></div></form></section></div>`;
  }

  window.openCrmSafeProspect=id=>{state.crmSelectedProspectId=id;window.render?.()};
  window.closeCrmSafeProspect=()=>{state.crmSelectedProspectId=null;window.render?.()};
  window.saveCrmSafeProspect=async(event,id)=>{
    event.preventDefault();const form=event.currentTarget,button=form.querySelector('button[type="submit"]'),err=document.getElementById('crm-safe-error'),values=new FormData(form),raw=String(values.get('next_follow_up_at')||'').trim();let follow=null;
    if(raw){const d=new Date(raw);if(Number.isNaN(d.getTime())){err.textContent=t('La fecha no es válida.','The date is invalid.');return;}follow=d.toISOString();}
    button.disabled=true;err.textContent='';
    const {data,error}=await db.rpc('update_organization_prospect',{target_organization_id:state.organization.id,target_prospect_id:id,new_status:String(values.get('status')||'new'),new_tag:String(values.get('tag')||''),new_notes:String(values.get('notes')||''),new_next_follow_up_at:follow});
    button.disabled=false;if(error){err.textContent=error.message||t('No se pudo guardar.','Could not save.');return;}
    const i=state.prospects.findIndex(p=>p.id===id);if(i>=0)state.prospects[i]={...state.prospects[i],...(data||{})};await loadFunnel();state.crmSelectedProspectId=null;window.toast?.(t('Seguimiento guardado.','Follow-up saved.'));window.render?.();
  };

  const originalLoad=window.loadProspects;
  if(typeof originalLoad==='function')window.loadProspects=async function(){const result=await originalLoad.apply(this,arguments);await loadFunnel();if(state.page==='prospects')window.render?.();return result};

  window.prospectsView=function(){
    const pages=Math.max(1,Math.ceil((state.prospectsTotal||0)/(state.prospectsPageSize||50)));
    return `<div class="top"><div><h1>${esc(t('CRM Comercial','Sales CRM'))}</h1><p>${esc(t('Seguimiento básico de prospectos y próxima acción.','Basic prospect tracking and next action.'))}</p></div><button class="primary" onclick="exportProspectsCsv()" ${state.prospectsTotal&&!state.prospectsLoading?'':'disabled'}>${esc(t('Exportar CSV','Export CSV'))}</button></div>${funnel()}<div class="panel crm-safe-panel"><div class="filters"><div class="field"><label>${esc(t('Tarjeta','Card'))}</label><select onchange="setProspectsCard(this.value)"><option value="all">${esc(t('Todas las tarjetas','All cards'))}</option>${state.organizationCards.map(card=>`<option value="${esc(card.id)}" ${state.prospectsCard===card.id?'selected':''}>${esc(card.name)}</option>`).join('')}</select></div><div class="field"><label>${esc(t('Orden','Order'))}</label><select onchange="setProspectsSort(this.value)"><option value="desc" ${state.prospectsSort==='desc'?'selected':''}>${esc(t('Más recientes','Newest'))}</option><option value="asc" ${state.prospectsSort==='asc'?'selected':''}>${esc(t('Más antiguos','Oldest'))}</option></select></div></div>${cards()}<div class="crm-safe-pagination"><span>${esc(t('Página','Page'))} ${esc(state.prospectsPage)} / ${esc(pages)}</span><div><button class="ghost" onclick="changeProspectsPage(-1)" ${state.prospectsPage<=1?'disabled':''}>${esc(t('Anterior','Previous'))}</button><button class="ghost" onclick="changeProspectsPage(1)" ${state.prospectsPage>=pages?'disabled':''}>${esc(t('Siguiente','Next'))}</button></div></div></div>${editor()}`;
  };

  const style=document.createElement('style');style.id='crm-commercial-safe-styles';style.textContent=`.crm-safe-funnel{display:grid;grid-template-columns:repeat(5,minmax(110px,1fr));gap:10px;margin-bottom:18px}.crm-safe-metric,.crm-safe-card{background:#fff;border:1px solid var(--line);border-radius:13px;padding:14px}.crm-safe-metric span,.crm-safe-card small,.crm-safe-grid span{display:block;color:var(--muted);font-size:12px}.crm-safe-metric b{font-size:24px}.crm-safe-panel,.crm-safe-list{display:grid;gap:12px}.crm-safe-head,.crm-safe-pagination,.crm-safe-editor-head,.crm-safe-editor-actions{display:flex;justify-content:space-between;gap:12px;align-items:center}.crm-safe-status{padding:5px 9px;border-radius:999px;background:#eef2ff;color:#4338ca;font-size:12px;font-weight:800}.crm-safe-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin:14px 0}.crm-safe-note{background:var(--surface-muted);padding:10px 12px;border-radius:9px;white-space:pre-wrap}.crm-safe-actions{display:flex;gap:8px;flex-wrap:wrap}.crm-safe-action{display:inline-flex;padding:8px 11px;border:1px solid var(--line);border-radius:9px;background:#fff;color:var(--text);text-decoration:none;font-weight:700;font-size:12px}.crm-safe-wa{background:#16a85b;color:#fff;border-color:#16a85b}.crm-safe-backdrop{position:fixed;inset:0;background:#10182877;z-index:100;display:flex;justify-content:flex-end}.crm-safe-editor{width:min(520px,100%);height:100%;overflow:auto;background:#fff;padding:22px}.crm-safe-editor-head{align-items:flex-start}.crm-safe-editor-head h2{margin:2px 0}.crm-safe-editor-head p{margin:0;color:var(--muted)}.crm-safe-editor-actions{margin-top:12px;flex-wrap:wrap}@media(max-width:900px){.crm-safe-funnel{grid-template-columns:repeat(2,1fr)}.crm-safe-grid{grid-template-columns:1fr}}@media(max-width:600px){.crm-safe-editor{padding:16px}.crm-safe-pagination{align-items:flex-start;flex-direction:column}}`;document.head.appendChild(style);

  loadFunnel().then(()=>{if(state.page==='prospects')window.render?.()});
})();