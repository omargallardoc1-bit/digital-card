(()=>{
  'use strict';
  const t=(es,en)=>typeof language!=='undefined'&&language==='en'?en:es;
  const esc=value=>String(value??'').replace(/[&<>'"]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[ch]));
  const fmt=value=>{if(!value)return '';const d=new Date(value);if(Number.isNaN(d.getTime()))return '';return new Intl.DateTimeFormat(typeof language!=='undefined'&&language==='en'?'en-US':'es-MX',{dateStyle:'medium',timeStyle:'short'}).format(d)};

  function ensure(){
    if(typeof state==='undefined')return false;
    if(!('crmActivities' in state))state.crmActivities={};
    if(!('crmActivitiesLoading' in state))state.crmActivitiesLoading={};
    return true;
  }

  async function load(id){
    if(!ensure()||!id||!state.organization?.id||state.crmActivitiesLoading[id])return;
    state.crmActivitiesLoading[id]=true;
    inject(true);
    const {data,error}=await db.rpc('list_organization_prospect_activities',{
      target_organization_id:state.organization.id,target_prospect_id:id,requested_limit:100
    });
    state.crmActivitiesLoading[id]=false;
    state.crmActivities[id]=error?[]:(Array.isArray(data)?data:[]);
    inject(true);
  }

  function timeline(id){
    if(state.crmActivitiesLoading?.[id])return `<div class="crm-history-empty">${esc(t('Cargando historial…','Loading history…'))}</div>`;
    const items=state.crmActivities?.[id]||[];
    if(!items.length)return `<div class="crm-history-empty">${esc(t('Aún no hay movimientos registrados. El próximo cambio quedará guardado aquí.','No activity has been recorded yet. The next change will appear here.'))}</div>`;
    return `<div class="crm-history-list">${items.map(a=>{
      const d=a.details||{};let detail='';
      if(d.previous_status&&d.status&&d.previous_status!==d.status)detail+=`<small>${esc(t('Etapa','Stage'))}: ${esc(d.previous_status)} → ${esc(d.status)}</small>`;
      if(d.next_follow_up_at)detail+=`<small>${esc(t('Seguimiento','Follow-up'))}: ${esc(fmt(d.next_follow_up_at))}</small>`;
      return `<article class="crm-history-item"><span class="crm-history-dot"></span><div><b>${esc(a.summary||t('Actualización','Update'))}</b>${detail}<time>${esc(fmt(a.created_at))}</time></div></article>`;
    }).join('')}</div>`;
  }

  function renderKey(id){
    const items=state.crmActivities?.[id];
    const last=Array.isArray(items)&&items.length?`${items.length}:${items[0]?.id||''}:${items[0]?.created_at||''}`:'0';
    return `${id}:${state.crmActivitiesLoading?.[id]?'loading':'ready'}:${last}:${typeof language!=='undefined'?language:'es'}`;
  }

  function inject(force=false){
    if(!ensure())return;
    const editor=document.querySelector('.crm-editor'),id=state.crmSelectedProspectId;
    if(!editor||!id)return;
    let section=editor.querySelector('.crm-history-section');
    if(!section){section=document.createElement('section');section.className='crm-history-section';const form=editor.querySelector('form');if(form)form.insertAdjacentElement('afterend',section);else editor.appendChild(section);}
    const key=renderKey(id);
    if(force||section.dataset.renderKey!==key){
      section.dataset.renderKey=key;
      section.innerHTML=`<div class="crm-history-heading"><div><small>${esc(t('Actividad','Activity'))}</small><h3>${esc(t('Historial comercial','Commercial history'))}</h3></div><button type="button" class="ghost" onclick="refreshCrmHistory()">${esc(t('Actualizar','Refresh'))}</button></div>${timeline(id)}`;
    }
    if(state.crmActivities[id]===undefined&&!state.crmActivitiesLoading[id])load(id);
  }

  window.refreshCrmHistory=()=>{const id=state?.crmSelectedProspectId;if(id){delete state.crmActivities[id];load(id)}};

  function install(){
    if(!ensure()||window.__crmHistoryInstalled)return false;
    window.__crmHistoryInstalled=true;
    const style=document.createElement('style');style.textContent=`.crm-history-section{border-top:1px solid var(--line);margin-top:22px;padding-top:18px}.crm-history-heading{display:flex;justify-content:space-between;gap:12px;align-items:center;margin-bottom:12px}.crm-history-heading h3{margin:2px 0 0}.crm-history-heading small{color:var(--muted)}.crm-history-list{display:grid;gap:0}.crm-history-item{display:grid;grid-template-columns:14px 1fr;gap:10px;position:relative;padding:0 0 16px}.crm-history-item:not(:last-child):before{content:'';position:absolute;left:5px;top:12px;bottom:-2px;width:2px;background:var(--line)}.crm-history-dot{width:12px;height:12px;border-radius:50%;background:var(--purple);margin-top:5px;z-index:1}.crm-history-item b{display:block}.crm-history-item small,.crm-history-item time{display:block;color:var(--muted);font-size:12px;margin-top:3px}.crm-history-empty{padding:16px;border:1px dashed var(--line);border-radius:10px;color:var(--muted);font-size:13px}`;document.head.appendChild(style);
    const observer=new MutationObserver(mutations=>{
      if(!state?.crmSelectedProspectId)return;
      const needsInject=mutations.some(m=>[...m.addedNodes].some(n=>n.nodeType===1&&(n.matches?.('.crm-editor')||n.querySelector?.('.crm-editor'))));
      if(needsInject)requestAnimationFrame(()=>inject(false));
    });
    observer.observe(document.body,{childList:true,subtree:true});
    inject(false);
    return true;
  }
  const timer=setInterval(()=>{if(typeof state!=='undefined'&&install())clearInterval(timer)},25);setTimeout(()=>clearInterval(timer),5000);
})();