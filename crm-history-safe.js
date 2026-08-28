(()=>{
  'use strict';
  const boot=()=>{
    if(typeof state==='undefined'||typeof db==='undefined')return false;
    if(window.__crmHistorySafeInstalled)return true;
    if(typeof window.openCrmSafeProspect!=='function'||typeof window.prospectsView!=='function')return false;
    window.__crmHistorySafeInstalled=true;
    const t=(es,en)=>typeof language!=='undefined'&&language==='en'?en:es;
    const esc=value=>String(value??'').replace(/[&<>'"]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[ch]));
    const fmt=value=>{if(!value)return '';const d=new Date(value);if(Number.isNaN(d.getTime()))return '';return new Intl.DateTimeFormat(typeof language!=='undefined'&&language==='en'?'en-US':'es-MX',{dateStyle:'medium',timeStyle:'short'}).format(d)};
    const stages={new:t('Nuevo','New'),contacted:t('Contactado','Contacted'),interested:t('Interesado','Interested'),appointment:t('Cita','Appointment'),proposal:t('Propuesta','Proposal'),won:t('Ganado','Won'),lost:t('Perdido','Lost')};
    const legacy={follow_up:t('Seguimiento','Follow-up'),customer:t('Cliente','Customer'),discarded:t('Descartado','Discarded')};
    const labelStatus=value=>stages[value]||legacy[value]||value||'—';
    if(!state.crmActivities)state.crmActivities={};
    if(!state.crmActivitiesLoading)state.crmActivitiesLoading={};

    async function loadHistory(id){
      if(!id||!state.organization?.id||state.crmActivitiesLoading[id])return;
      state.crmActivitiesLoading[id]=true;window.render?.();
      const {data,error}=await db.rpc('list_organization_prospect_activities',{target_organization_id:state.organization.id,target_prospect_id:id,requested_limit:100});
      state.crmActivitiesLoading[id]=false;
      state.crmActivities[id]=error?[]:(Array.isArray(data)?data:[]);
      window.render?.();
    }

    function historyHtml(id){
      if(state.crmActivitiesLoading[id])return `<section class="crm-safe-history"><div class="crm-safe-history-head"><h3>${esc(t('Historial comercial','Commercial history'))}</h3></div><div class="crm-safe-history-empty">${esc(t('Cargando historial…','Loading history…'))}</div></section>`;
      const items=state.crmActivities[id];
      if(!items)return `<section class="crm-safe-history"><div class="crm-safe-history-head"><h3>${esc(t('Historial comercial','Commercial history'))}</h3></div><div class="crm-safe-history-empty">${esc(t('Cargando historial…','Loading history…'))}</div></section>`;
      if(!items.length)return `<section class="crm-safe-history"><div class="crm-safe-history-head"><h3>${esc(t('Historial comercial','Commercial history'))}</h3><button type="button" class="ghost" onclick="refreshCrmSafeHistory('${esc(id)}')">${esc(t('Actualizar','Refresh'))}</button></div><div class="crm-safe-history-empty">${esc(t('Aún no hay movimientos registrados.','No activity has been recorded yet.'))}</div></section>`;
      return `<section class="crm-safe-history"><div class="crm-safe-history-head"><h3>${esc(t('Historial comercial','Commercial history'))}</h3><button type="button" class="ghost" onclick="refreshCrmSafeHistory('${esc(id)}')">${esc(t('Actualizar','Refresh'))}</button></div><div class="crm-safe-history-list">${items.map(a=>{const d=a.details||{};let extra='';const currentStatus=d.current_status??d.status;if(d.previous_status&&currentStatus&&d.previous_status!==currentStatus)extra+=`<small>${esc(t('Etapa','Stage'))}: ${esc(labelStatus(d.previous_status))} → ${esc(labelStatus(currentStatus))}</small>`;const currentFollow=d.current_next_follow_up_at??d.next_follow_up_at;if(currentFollow)extra+=`<small>${esc(t('Seguimiento','Follow-up'))}: ${esc(fmt(currentFollow))}</small>`;return `<article class="crm-safe-history-item"><span></span><div><b>${esc(a.summary||t('Actualización','Update'))}</b>${extra}<time>${esc(fmt(a.created_at))}</time></div></article>`}).join('')}</div></section>`;
    }

    function stageOptions(selected,includeLegacy){
      const all={...stages};
      if(includeLegacy)Object.entries(legacy).forEach(([k,v])=>{all[k]=`${v} · ${t('anterior','legacy')}`});
      return Object.entries(all).map(([key,label])=>`<option value="${key}" ${selected===key?'selected':''}>${esc(label)}</option>`).join('');
    }

    function funnelHtml(){
      const f=state.crmFunnel||{};
      const items=[[stages.new,f.new||0],[stages.contacted,f.contacted||0],[stages.interested,f.interested||0],[stages.appointment,f.appointment||0],[stages.proposal,f.proposal||0],[stages.won,f.won||0],[stages.lost,f.lost||0]];
      return `<div class="crm-safe-funnel crm-safe-funnel-v2">${items.map(([label,count])=>`<div class="crm-safe-metric"><span>${esc(label)}</span><b>${esc(count)}</b></div>`).join('')}</div>`;
    }

    function applyV2(html){
      html=html.replace(/<div class="crm-safe-funnel">[\s\S]*?<\/div><\/div>/,funnelHtml());
      html=html.replace(/<select name="stage">[\s\S]*?<\/select>/,()=>`<select name="stage"><option value="all">${esc(t('Todas','All'))}</option>${stageOptions(state.crmStageFilter,false)}</select>`);
      const p=state.prospects?.find(x=>x.id===state.crmSelectedProspectId);
      if(p)html=html.replace(/<select name="status">[\s\S]*?<\/select>/,()=>`<select name="status">${stageOptions(p.status,!!legacy[p.status])}</select>`);
      Object.entries(stages).forEach(([key,label])=>{html=html.replace(new RegExp(`<span class="crm-safe-status">${key}<\\/span>`,'g'),`<span class="crm-safe-status">${esc(label)}</span>`)});
      return html;
    }

    const originalOpen=window.openCrmSafeProspect;
    window.openCrmSafeProspect=function(id){originalOpen(id);if(state.crmActivities[id]===undefined)loadHistory(id)};
    window.refreshCrmSafeHistory=id=>{delete state.crmActivities[id];loadHistory(id)};

    const originalView=window.prospectsView;
    window.prospectsView=function(){
      let html=applyV2(originalView());
      const id=state.crmSelectedProspectId;
      if(!id)return html;
      html=html.replace(/(<div class="crm-safe-editor-actions">[\s\S]*?)<button class="crm-safe-action" type="button" onclick="openCrmSafeProspect\('[^']+'\)">[^<]*<\/button>/,'$1');
      const marker='</form></section></div>';
      if(html.includes(marker))html=html.replace(marker,`</form>${historyHtml(id)}</section></div>`);
      return html;
    };

    const style=document.createElement('style');style.id='crm-history-safe-styles';style.textContent=`#crm-safe-error:empty{display:none}.crm-safe-funnel-v2{grid-template-columns:repeat(7,minmax(100px,1fr))}.crm-safe-history{border-top:1px solid var(--line);margin-top:22px;padding-top:18px}.crm-safe-history-head{display:flex;justify-content:space-between;gap:12px;align-items:center;margin-bottom:12px}.crm-safe-history-head h3{margin:0}.crm-safe-history-list{display:grid;gap:0}.crm-safe-history-item{display:grid;grid-template-columns:14px 1fr;gap:10px;position:relative;padding:0 0 16px}.crm-safe-history-item:not(:last-child):before{content:'';position:absolute;left:5px;top:12px;bottom:-2px;width:2px;background:var(--line)}.crm-safe-history-item>span{width:12px;height:12px;border-radius:50%;background:#6d5bd0;margin-top:5px;z-index:1}.crm-safe-history-item b{display:block}.crm-safe-history-item small,.crm-safe-history-item time{display:block;color:var(--muted);font-size:12px;margin-top:3px}.crm-safe-history-empty{padding:14px;border:1px dashed var(--line);border-radius:10px;color:var(--muted);font-size:13px}@media(max-width:1100px){.crm-safe-funnel-v2{grid-template-columns:repeat(4,1fr)}}@media(max-width:700px){.crm-safe-funnel-v2{grid-template-columns:repeat(2,1fr)}}`;document.head.appendChild(style);
    return true;
  };

  if(boot())return;
  let tries=0;
  const timer=setInterval(()=>{tries+=1;if(boot()||tries>=100)clearInterval(timer)},50);
})();