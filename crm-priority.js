(()=>{
  'use strict';
  const t=(es,en)=>typeof language!=='undefined'&&language==='en'?en:es;
  let query='',stage='all',due='all';

  const startOfDay=d=>new Date(d.getFullYear(),d.getMonth(),d.getDate());
  const dueState=value=>{
    if(!value)return 'none';
    const when=new Date(value);if(Number.isNaN(when.getTime()))return 'none';
    const now=new Date(),today=startOfDay(now),target=startOfDay(when);
    if(when.getTime()<now.getTime()&&target.getTime()<=today.getTime())return 'overdue';
    if(target.getTime()===today.getTime())return 'today';
    return 'future';
  };
  const normalize=v=>String(v||'').toLocaleLowerCase('es').normalize('NFD').replace(/[\u0300-\u036f]/g,'');

  function applyFilters(){
    const cards=[...document.querySelectorAll('.crm-card')];
    cards.forEach((card,index)=>{
      const p=state?.prospects?.[index];if(!p)return;
      const haystack=normalize([p.name,p.phone,p.email,p.card_name,p.notes,p.source].join(' '));
      const matchesQuery=!query||haystack.includes(normalize(query));
      const matchesStage=stage==='all'||String(p.status||'new')===stage;
      const ds=dueState(p.next_follow_up_at);
      const matchesDue=due==='all'||ds===due||(due==='pending'&&(ds==='overdue'||ds==='today'||ds==='future'));
      card.style.display=matchesQuery&&matchesStage&&matchesDue?'':'none';
      card.dataset.crmDue=ds;
      if(!card.querySelector('.crm-due-badge')&&ds!=='none'){
        const label=ds==='overdue'?t('Seguimiento vencido','Overdue'):ds==='today'?t('Seguimiento hoy','Due today'):t('Seguimiento programado','Scheduled');
        const badge=document.createElement('span');badge.className=`crm-due-badge crm-due-${ds}`;badge.textContent=label;
        card.querySelector('.crm-card-head')?.appendChild(badge);
      }
    });
    const visible=cards.filter(card=>card.style.display!=='none').length;
    const counter=document.getElementById('crm-visible-count');if(counter)counter.textContent=`${visible} ${t('visibles','visible')}`;
  }

  function toolbar(){
    const panel=document.querySelector('.crm-panel');if(!panel||panel.querySelector('.crm-priority-tools'))return;
    const wrap=document.createElement('div');wrap.className='crm-priority-tools';wrap.innerHTML=`
      <div class="field"><label>${t('Buscar','Search')}</label><input id="crm-search" type="search" placeholder="${t('Nombre, teléfono, nota…','Name, phone, note…')}" autocomplete="off"></div>
      <div class="field"><label>${t('Etapa','Stage')}</label><select id="crm-stage-filter"><option value="all">${t('Todas','All')}</option><option value="new">${t('Nuevo','New')}</option><option value="contacted">${t('Contactado','Contacted')}</option><option value="follow_up">${t('Seguimiento','Follow-up')}</option><option value="customer">${t('Cliente','Customer')}</option><option value="discarded">${t('Descartado','Discarded')}</option></select></div>
      <div class="field"><label>${t('Prioridad','Priority')}</label><select id="crm-due-filter"><option value="all">${t('Todos','All')}</option><option value="overdue">${t('Vencidos','Overdue')}</option><option value="today">${t('Para hoy','Due today')}</option><option value="pending">${t('Con seguimiento','With follow-up')}</option><option value="none">${t('Sin seguimiento','No follow-up')}</option></select></div>
      <small id="crm-visible-count" class="crm-visible-count"></small>`;
    const list=panel.querySelector('.crm-list,.empty');panel.insertBefore(wrap,list||panel.firstChild);
    const search=wrap.querySelector('#crm-search'),stageEl=wrap.querySelector('#crm-stage-filter'),dueEl=wrap.querySelector('#crm-due-filter');
    search.value=query;stageEl.value=stage;dueEl.value=due;
    search.addEventListener('input',()=>{query=search.value;applyFilters()});
    stageEl.addEventListener('change',()=>{stage=stageEl.value;applyFilters()});
    dueEl.addEventListener('change',()=>{due=dueEl.value;applyFilters()});
    applyFilters();
  }

  function styles(){if(document.getElementById('crm-priority-styles'))return;const s=document.createElement('style');s.id='crm-priority-styles';s.textContent=`
    .crm-priority-tools{display:grid;grid-template-columns:minmax(220px,1.4fr) minmax(150px,.7fr) minmax(160px,.8fr) auto;gap:10px;align-items:end;padding:12px;border:1px solid var(--line);border-radius:12px;background:var(--surface-muted)}.crm-priority-tools .field{margin:0}.crm-visible-count{color:var(--muted);padding:0 4px 11px;white-space:nowrap}.crm-card-head{position:relative}.crm-due-badge{display:inline-flex;align-items:center;padding:5px 8px;border-radius:999px;font-size:11px;font-weight:800;margin-left:auto}.crm-due-overdue{background:#fff0f2;color:#b42318}.crm-due-today{background:#fff7df;color:#a16207}.crm-due-future{background:#eff8ff;color:#175cd3}.crm-card[data-crm-due="overdue"]{border-left:4px solid #b42318}.crm-card[data-crm-due="today"]{border-left:4px solid #a16207}@media(max-width:800px){.crm-priority-tools{grid-template-columns:1fr 1fr}.crm-visible-count{padding-bottom:0}}@media(max-width:520px){.crm-priority-tools{grid-template-columns:1fr}}
  `;document.head.appendChild(s)}

  function refresh(){styles();toolbar();applyFilters()}
  const observer=new MutationObserver(()=>{if(state?.page==='prospects')refresh()});observer.observe(document.documentElement,{childList:true,subtree:true});
  const timer=setInterval(()=>{if(typeof state!=='undefined'&&state.page==='prospects')refresh()},250);setTimeout(()=>clearInterval(timer),8000);
})();
