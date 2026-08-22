(()=>{
  let funnelData=null,funnelLoading=false,funnelOrg=null,funnelCard=null;
  const t=(es,en)=>language==='en'?en:es;
  const num=v=>Number(v||0).toLocaleString(language==='en'?'en-US':'es-MX');

  function selectedCard(){
    const candidate=state?.metricsCard;
    return candidate&&candidate!=='all'?candidate:null;
  }

  async function loadFunnel(force=false){
    if(!state?.session||!state?.organization?.id||!canViewOrganizationProspectPii())return;
    const org=state.organization.id,card=selectedCard();
    if(!force&&funnelData&&funnelOrg===org&&funnelCard===card)return;
    if(funnelLoading)return;
    funnelLoading=true;
    const {data,error}=await db.rpc('get_organization_prospect_funnel',{target_organization_id:org,target_card_id:card});
    funnelLoading=false;
    if(error){console.warn('prospect funnel',error);return}
    funnelData=Array.isArray(data)?data[0]:data;
    funnelOrg=org;funnelCard=card;
    render();
  }

  function funnelHtml(){
    if(!canViewOrganizationProspectPii())return '';
    if(!funnelData){queueMicrotask(()=>loadFunnel());return `<section class="dashboard-section"><div class="dashboard-section-header"><div><h2>${esc(t('Embudo comercial','Sales funnel'))}</h2><p>${esc(t('Cargando conversión de prospectos…','Loading prospect conversion…'))}</p></div></div></section>`}
    const d=funnelData;
    const steps=[
      [t('Prospectos','Prospects'),d.prospects],
      [t('Contactados','Contacted'),d.contacted],
      [t('Seguimiento','Follow-up'),d.follow_up],
      [t('Clientes','Customers'),d.customers]
    ];
    return `<section class="dashboard-section mx-funnel-section">
      <div class="dashboard-section-header"><div><h2>${esc(t('Embudo comercial','Sales funnel'))}</h2><p>${esc(t('Del contacto captado al cliente.','From captured contact to customer.'))}</p></div><button class="ghost" type="button" onclick="window.refreshProspectFunnel()">${uiIcon('refresh')}<span>${esc(t('Actualizar','Refresh'))}</span></button></div>
      <div class="dashboard-section-body">
        <div class="mx-funnel-grid">${steps.map(([label,value],i)=>`<div class="mx-funnel-step"><span>${esc(label)}</span><strong>${esc(num(value))}</strong>${i<steps.length-1?'<b aria-hidden="true">›</b>':''}</div>`).join('')}</div>
        <div class="mx-funnel-summary"><div><span>${esc(t('Nuevos','New'))}</span><strong>${esc(num(d.new))}</strong></div><div><span>${esc(t('Trabajados','Worked'))}</span><strong>${esc(num(d.worked))}</strong></div><div><span>${esc(t('Descartados','Discarded'))}</span><strong>${esc(num(d.discarded))}</strong></div><div><span>${esc(t('Prospecto → cliente','Prospect → customer'))}</span><strong>${esc(String(d.prospect_to_customer_rate||0))}%</strong></div></div>
      </div>
    </section>`;
  }

  function styles(){
    if(document.getElementById('mx-funnel-style'))return;
    const s=document.createElement('style');s.id='mx-funnel-style';s.textContent=`
      .mx-funnel-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}.mx-funnel-step{position:relative;min-height:104px;padding:16px;border:1px solid var(--border-default);border-radius:var(--radius-card);background:var(--surface-card);display:grid;align-content:center}.mx-funnel-step span{font-size:12px;font-weight:700;color:var(--text-muted)}.mx-funnel-step strong{font-size:26px;line-height:34px}.mx-funnel-step>b{position:absolute;right:-11px;top:35px;z-index:2;width:20px;height:32px;display:grid;place-items:center;color:var(--app-primary);font-size:28px;background:var(--surface-canvas)}.mx-funnel-summary{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-top:12px}.mx-funnel-summary>div{padding:12px;border-radius:var(--radius-control);background:var(--surface-muted)}.mx-funnel-summary span,.mx-funnel-summary strong{display:block}.mx-funnel-summary span{font-size:11px;color:var(--text-muted);font-weight:700}.mx-funnel-summary strong{font-size:18px;margin-top:3px}@media(max-width:767px){.mx-funnel-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.mx-funnel-step>b{display:none}.mx-funnel-summary{grid-template-columns:repeat(2,minmax(0,1fr))}}@media(max-width:420px){.mx-funnel-grid,.mx-funnel-summary{grid-template-columns:1fr}}
    `;document.head.appendChild(s);
  }

  window.refreshProspectFunnel=()=>{funnelData=null;loadFunnel(true)};

  const originalDashboard=window.dashboardView;
  if(typeof originalDashboard==='function'){
    window.dashboardView=function(){
      styles();
      const html=originalDashboard.apply(this,arguments);
      queueMicrotask(()=>loadFunnel());
      const funnel=funnelHtml();
      const pos=html.lastIndexOf('</div>');
      return pos>=0?html.slice(0,pos)+funnel+html.slice(pos):html+funnel;
    };
  }
})();
