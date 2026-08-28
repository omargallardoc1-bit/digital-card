(()=>{
  'use strict';
  const boot=()=>{
    if(typeof state==='undefined'||typeof window.prospectsView!=='function')return false;
    if(window.__crmAppointmentsSafeInstalled)return true;
    window.__crmAppointmentsSafeInstalled=true;

    const t=(es,en)=>typeof language!=='undefined'&&language==='en'?en:es;
    const esc=value=>String(value??'').replace(/[&<>'"]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[ch]));
    const fmt=value=>{if(!value)return '—';const d=new Date(value);if(Number.isNaN(d.getTime()))return '—';return new Intl.DateTimeFormat(typeof language!=='undefined'&&language==='en'?'en-US':'es-MX',{dateStyle:'medium',timeStyle:'short'}).format(d)};
    const appointmentLabel=value=>({requested:t('Solicitada','Requested'),confirmed:t('Confirmada','Confirmed'),rescheduled:t('Reprogramada','Rescheduled'),cancelled:t('Cancelada','Cancelled'),completed:t('Atendida','Completed'),no_show:t('No asistió','No-show')})[value]||value||'—';

    const appointmentHtml=(p,compact=false)=>{
      const a=p?.latest_appointment;if(!a)return '';
      const title=a.service_title||t('Cita','Appointment');
      return `<section class="crm-appt-box ${compact?'crm-appt-compact':''}"><div class="crm-appt-head"><div><small>${esc(t('Cita relacionada','Related appointment'))}</small><b>${esc(title)}</b></div><span class="crm-appt-status crm-appt-${esc(a.status||'requested')}">${esc(appointmentLabel(a.status))}</span></div><div class="crm-appt-meta"><span>◷ ${esc(fmt(a.scheduled_at))}</span>${a.duration_minutes?`<span>${esc(a.duration_minutes)} min</span>`:''}</div>${compact?'':`<button class="ghost crm-appt-open" type="button" onclick="go('appointments')">${esc(t('Abrir en Citas','Open in Appointments'))}</button>`}</section>`;
    };

    const originalView=window.prospectsView;
    window.prospectsView=function(){
      let html=originalView();
      const prospects=Array.isArray(state.prospects)?state.prospects:[];
      prospects.forEach(p=>{
        if(!p?.latest_appointment)return;
        const escapedId=String(p.id||'').replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
        const cardPattern=new RegExp(`(<article class="crm-safe-card">[\\s\\S]*?openCrmSafeProspect\\('${escapedId}'\\)[\\s\\S]*?)(<div class="crm-safe-actions">)`);
        html=html.replace(cardPattern,`$1${appointmentHtml(p,true)}$2`);
      });
      const selected=prospects.find(p=>p.id===state.crmSelectedProspectId);
      if(selected?.latest_appointment){
        const marker='<form onsubmit="saveCrmSafeProspect';
        const idx=html.indexOf(marker);
        if(idx>=0){
          const headEnd=html.lastIndexOf('</div>',idx);
          if(headEnd>=0)html=html.slice(0,headEnd+6)+appointmentHtml(selected,false)+html.slice(headEnd+6);
        }
      }
      return html;
    };

    const style=document.createElement('style');style.id='crm-appointments-safe-styles';style.textContent=`.crm-appt-box{border:1px solid var(--line);border-radius:12px;padding:12px;margin:12px 0;background:var(--surface-muted)}.crm-appt-head{display:flex;justify-content:space-between;gap:10px;align-items:flex-start}.crm-appt-head small{display:block;color:var(--muted);font-size:11px}.crm-appt-head b{display:block;margin-top:2px}.crm-appt-status{padding:5px 8px;border-radius:999px;font-size:11px;font-weight:800;background:#eef2ff;color:#4338ca}.crm-appt-confirmed{background:#ecfdf3;color:#027a48}.crm-appt-cancelled,.crm-appt-no_show{background:#fff1f3;color:#c01048}.crm-appt-completed{background:#eff8ff;color:#175cd3}.crm-appt-meta{display:flex;gap:10px;flex-wrap:wrap;color:var(--muted);font-size:12px;margin-top:8px}.crm-appt-open{margin-top:10px}.crm-appt-compact{margin:8px 0 12px;padding:10px}`;document.head.appendChild(style);
    return true;
  };

  if(boot())return;
  let tries=0;const timer=setInterval(()=>{tries+=1;if(boot()||tries>=120)clearInterval(timer)},50);
})();