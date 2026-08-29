(()=>{
  'use strict';
  const lang=()=>typeof language!=='undefined'?language:'es';
  const t=(es,en)=>lang()==='en'?en:es;
  const loadScript=src=>{if(document.querySelector(`script[src="${src}"]`))return;const s=document.createElement('script');s.src=src;s.defer=true;document.body.appendChild(s)};
  loadScript('/appointments-config.js');
  loadScript('/appointments-blocks.js');
  loadScript('/crm-commercial-safe.js');
  loadScript('/crm-history-safe.js');
  loadScript('/crm-appointments-safe.js');
  loadScript('/mx-brand-safe.js');
  loadScript('/referral-tracking-safe.js');
  loadScript('/rewards-safe.js');
  loadScript('/rewards-mobile-fix.js');
  loadScript('/rewards-subtle-mobile.js');

  const manager=()=>['owner','admin'].includes(String(state?.organizationMembership?.role||'').toLowerCase());
  const installRoleFix=()=>{
    if(typeof window.saveAppointmentSettings!=='function'||window.__appointmentSettingsRoleFixInstalled)return false;
    window.__appointmentSettingsRoleFixInstalled=true;
    const original=window.saveAppointmentSettings;
    window.saveAppointmentSettings=async function(){
      if(!manager())return original();
      if(!state?.appointmentSettingsCard)return;
      const rules=[];
      document.querySelectorAll('.appointment-rule-row').forEach(row=>{
        if(!row.querySelector('[data-rule-enabled]')?.checked)return;
        rules.push({weekday:Number(row.dataset.weekday),start_time:row.querySelector('[data-rule-start]')?.value||'09:00',end_time:row.querySelector('[data-rule-end]')?.value||'18:00',is_active:true});
      });
      const enabled=document.getElementById('appointment-enabled')?.checked===true;
      if(enabled&&!rules.length){window.toast?.(t('Define al menos un día y horario antes de activar la agenda.','Set at least one day and time before enabling booking.'));return;}
      const {data,error}=await db.rpc('update_organization_appointment_settings',{
        target_organization_id:state.organization.id,target_card_id:state.appointmentSettingsCard,new_enabled:enabled,
        new_timezone:document.getElementById('appointment-timezone')?.value||'UTC',
        new_default_duration_minutes:Number(document.getElementById('appointment-duration')?.value||30),
        new_slot_interval_minutes:Number(document.getElementById('appointment-interval')?.value||30),
        new_min_notice_minutes:Number(document.getElementById('appointment-notice')?.value||60),
        new_max_booking_days:Number(document.getElementById('appointment-max-days')?.value||60),new_rules:rules
      });
      if(error){window.toast?.(t('No se pudo guardar: ','Could not save: ')+error.message);return;}
      state.appointmentSettings=data||state.appointmentSettings;window.toast?.(t('Configuración de agenda guardada.','Schedule settings saved.'));window.render?.();
    };
    const refresh=()=>{if(!manager())return;const panel=document.querySelector('.appointment-settings-panel');if(!panel)return;const b=panel.querySelector('.appointment-settings-actions .primary');if(b)b.disabled=false;panel.querySelectorAll('.readonly-note').forEach(n=>{if(/Solo propietario o administrador|Only the owner or an administrator/i.test(n.textContent||''))n.remove()})};
    refresh();new MutationObserver(refresh).observe(document.documentElement,{childList:true,subtree:true});return true;
  };

  window.submitAppointment=async function(event){
    event.preventDefault();const form=event.currentTarget,button=form.querySelector('button[type="submit"]'),errorEl=document.getElementById('appointment-form-error'),card=state?.publicCard;if(!card||!button||!errorEl)return;
    const values=new FormData(form),rawWhen=String(values.get('scheduled_at')||''),when=new Date(rawWhen);if(Number.isNaN(when.getTime())){errorEl.textContent=t('La fecha no es válida.','The date is invalid.');return;}
    const slots=Array.isArray(state?.appointmentPublicSlots)?state.appointmentPublicSlots:[],slot=slots.find(s=>String(s?.scheduled_at)===rawWhen);if(slots.length&&!slot){errorEl.textContent=t('Ese horario ya no está disponible. Actualiza la agenda.','That time is no longer available. Refresh the schedule.');return;}
    const duration=Number(slot?.duration_minutes||values.get('duration_minutes')||30);button.disabled=true;button.textContent=t('Enviando…','Sending…');errorEl.textContent='';
    const appointment=await db.functions.invoke('create-appointment',{body:{
      card_id:card.id,
      name:String(values.get('name')||'').trim(),
      phone:String(values.get('phone')||'').trim(),
      email:String(values.get('email')||'').trim(),
      source:typeof publicEventSource==='function'?publicEventSource():'public_card',
      consentimiento:values.get('consentimiento')==='on',
      scheduled_at:when.toISOString(),
      service_id:String(values.get('service_id')||'').trim()||null,
      duration_minutes:duration,
      notes:String(values.get('notes')||'').trim()||null
    }});
    if(appointment.error){errorEl.textContent=appointment.data?.error||t('No se pudo crear la cita. No se guardaron tus datos.','The appointment could not be created. Your details were not saved.');button.disabled=false;button.textContent=t('Solicitar cita','Request appointment');return;}
    const panel=document.getElementById('appointment-public-panel');if(panel)panel.outerHTML=`<div class="panel success appointment-public-success"><b>${t('Solicitud de cita enviada.','Appointment request sent.')}</b><br>${t('La cita debe ser confirmada por llamada o WhatsApp por el titular de la tarjeta.','The appointment must be confirmed by the card owner by phone call or WhatsApp.')}</div>`;
  };

  const installConfirmationNotice=()=>{
    const add=()=>{
      const form=document.querySelector('#appointment-public-panel form');
      if(!form||form.querySelector('.appointment-confirmation-notice'))return;
      const notice=document.createElement('div');
      notice.className='appointment-confirmation-notice';
      notice.setAttribute('role','note');
      notice.style.cssText='margin:12px 0;padding:10px 12px;border-radius:10px;background:rgba(245,158,11,.12);font-size:.92rem;line-height:1.35';
      notice.innerHTML=`<b>${t('Importante:','Important:')}</b> ${t('La solicitud no queda confirmada automáticamente. La cita debe ser confirmada por llamada o WhatsApp por el titular de la tarjeta.','The request is not automatically confirmed. The appointment must be confirmed by the card owner by phone call or WhatsApp.')}`;
      const actions=form.querySelector('.appointment-public-actions');
      if(actions)form.insertBefore(notice,actions);else form.appendChild(notice);
    };
    add();
    new MutationObserver(add).observe(document.documentElement,{childList:true,subtree:true});
  };

  const installMobile=()=>{
    if(typeof window.mobileNavigation!=='function'||window.__appointmentsMobileHookInstalled)return false;window.__appointmentsMobileHookInstalled=true;const original=window.mobileNavigation;
    window.mobileNavigation=function(){const html=original();if(typeof canViewOrganizationProspectPii!=='function'||!canViewOrganizationProspectPii()||/go\('appointments'\)/.test(html))return html;const label=t('Citas','Appointments'),button=`<button class="${state?.page==='appointments'?'active':''}" onclick="go('appointments')"><span aria-hidden="true">◷</span><span>${label}</span></button>`,prospects=/(<button[^>]+onclick="go\('prospects'\)"[\s\S]*?<\/button>)/;return prospects.test(html)?html.replace(prospects,`$1${button}`):html};return true;
  };
  installConfirmationNotice();
  const timer=setInterval(()=>{const a=installMobile(),b=installRoleFix();if(a&&b)clearInterval(timer)},25);setTimeout(()=>clearInterval(timer),5000);
})();
