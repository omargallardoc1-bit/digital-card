(()=>{
  'use strict';

  const lang=()=>typeof language!=='undefined'?language:'es';
  const t=(es,en)=>lang()==='en'?en:es;

  // Load configuration/availability layer without modifying the large core HTML.
  if(!document.querySelector('script[src="/appointments-config.js"]')){
    const script=document.createElement('script');
    script.src='/appointments-config.js';
    script.defer=true;
    document.body.appendChild(script);
  }

  // Compatibility bridge: the core app stores the current organization role in
  // state.organizationMembership.role. Keep the appointment module aligned with it.
  const coreAppointmentManager=()=>{
    const role=String(state?.organizationMembership?.role||'').toLowerCase();
    return ['owner','admin'].includes(role);
  };

  const installAppointmentSettingsRoleFix=()=>{
    if(typeof window.saveAppointmentSettings!=='function'||window.__appointmentSettingsRoleFixInstalled)return false;
    window.__appointmentSettingsRoleFixInstalled=true;
    const originalSave=window.saveAppointmentSettings;
    window.saveAppointmentSettings=async function(){
      if(!coreAppointmentManager())return originalSave();
      if(!state?.appointmentSettingsCard)return;
      const rules=[];
      document.querySelectorAll('.appointment-rule-row').forEach(row=>{
        if(!row.querySelector('[data-rule-enabled]')?.checked)return;
        rules.push({
          weekday:Number(row.dataset.weekday),
          start_time:row.querySelector('[data-rule-start]')?.value||'09:00',
          end_time:row.querySelector('[data-rule-end]')?.value||'18:00',
          is_active:true
        });
      });
      const enabled=document.getElementById('appointment-enabled')?.checked===true;
      if(enabled&&!rules.length){window.toast?.(t('Define al menos un día y horario antes de activar la agenda.','Set at least one day and time before enabling booking.'));return;}
      const payload={
        target_organization_id:state.organization.id,
        target_card_id:state.appointmentSettingsCard,
        new_enabled:enabled,
        new_timezone:document.getElementById('appointment-timezone')?.value||'UTC',
        new_default_duration_minutes:Number(document.getElementById('appointment-duration')?.value||30),
        new_slot_interval_minutes:Number(document.getElementById('appointment-interval')?.value||30),
        new_min_notice_minutes:Number(document.getElementById('appointment-notice')?.value||60),
        new_max_booking_days:Number(document.getElementById('appointment-max-days')?.value||60),
        new_rules:rules
      };
      const {data,error}=await db.rpc('update_organization_appointment_settings',payload);
      if(error){window.toast?.(t('No se pudo guardar: ','Could not save: ')+error.message);return;}
      state.appointmentSettings=data||state.appointmentSettings;
      window.toast?.(t('Configuración de agenda guardada.','Schedule settings saved.'));
      window.render?.();
    };

    const refreshPermissionUi=()=>{
      if(!coreAppointmentManager())return;
      const panel=document.querySelector('.appointment-settings-panel');
      if(!panel)return;
      const button=panel.querySelector('.appointment-settings-actions .primary');
      if(button)button.disabled=false;
      panel.querySelectorAll('.readonly-note').forEach(note=>{
        if(/Solo propietario o administrador|Only the owner or an administrator/i.test(note.textContent||''))note.remove();
      });
    };
    refreshPermissionUi();
    const observer=new MutationObserver(refreshPermissionUi);
    observer.observe(document.documentElement,{childList:true,subtree:true});
    return true;
  };

  // Public booking must go through the Edge Function; the SECURITY DEFINER RPC
  // is intentionally service_role-only in production.
  window.submitAppointment=async function(event){
    event.preventDefault();
    const form=event.currentTarget;
    const button=form.querySelector('button[type="submit"]');
    const errorEl=document.getElementById('appointment-form-error');
    const card=typeof state!=='undefined'?state.publicCard:null;
    if(!card||!errorEl||!button)return;

    const values=new FormData(form);
    const rawWhen=String(values.get('scheduled_at')||'');
    const when=new Date(rawWhen);
    if(Number.isNaN(when.getTime())){
      errorEl.textContent=t('La fecha no es válida.','The date is invalid.');
      return;
    }

    const allowedSlots=Array.isArray(state?.appointmentPublicSlots)?state.appointmentPublicSlots:[];
    const selectedSlot=allowedSlots.find(slot=>String(slot?.scheduled_at)===rawWhen);
    if(allowedSlots.length&&!selectedSlot){
      errorEl.textContent=t('Ese horario ya no está disponible. Actualiza la agenda.','That time is no longer available. Refresh the schedule.');
      return;
    }

    const duration=Number(values.get('duration_minutes')||selectedSlot?.duration_minutes||30);
    button.disabled=true;
    button.textContent=t('Enviando…','Sending…');
    errorEl.textContent='';

    const prospectPayload={
      card_id:card.id,
      name:String(values.get('name')||'').trim(),
      phone:String(values.get('phone')||'').trim(),
      email:String(values.get('email')||'').trim(),
      source:typeof publicEventSource==='function'?publicEventSource():'public_card',
      consentimiento:values.get('consentimiento')==='on'
    };

    const prospectResponse=await db.functions.invoke('create-prospect',{body:prospectPayload});
    if(prospectResponse.error){
      errorEl.textContent=t('No se pudieron registrar tus datos. Inténtalo de nuevo.','Your information could not be saved. Please try again.');
      button.disabled=false;
      button.textContent=t('Solicitar cita','Request appointment');
      return;
    }

    const prospectId=prospectResponse.data?.prospect_id||null;
    if(!prospectId){
      errorEl.textContent=t('Tus datos se guardaron, pero no pudimos crear la cita. Contacta al titular desde la tarjeta.','Your information was saved, but the appointment could not be created. Please contact the card owner.');
      button.disabled=false;
      button.textContent=t('Solicitar cita','Request appointment');
      return;
    }

    const appointmentResponse=await db.functions.invoke('create-appointment',{body:{
      card_id:card.id,
      prospect_id:prospectId,
      scheduled_at:when.toISOString(),
      service_id:String(values.get('service_id')||'').trim()||null,
      duration_minutes:duration,
      notes:String(values.get('notes')||'').trim()||null
    }});

    if(appointmentResponse.error){
      errorEl.textContent=appointmentResponse.data?.error||t('No se pudo crear la cita.','The appointment could not be created.');
      button.disabled=false;
      button.textContent=t('Solicitar cita','Request appointment');
      return;
    }

    const panel=document.getElementById('appointment-public-panel');
    if(panel)panel.outerHTML=`<div class="panel success appointment-public-success"><b>${t('Solicitud de cita enviada.','Appointment request sent.')}</b><br>${t('Queda pendiente de confirmación por el titular de la tarjeta.','It is pending confirmation by the card owner.')}</div>`;
  };

  // Add Citas to the mobile navigation when the core mobileNavigation function exists.
  const installMobileHook=()=>{
    if(typeof window.mobileNavigation!=='function'||window.__appointmentsMobileHookInstalled)return false;
    window.__appointmentsMobileHookInstalled=true;
    const original=window.mobileNavigation;
    window.mobileNavigation=function(){
      const html=original();
      if(typeof canViewOrganizationProspectPii!=='function'||!canViewOrganizationProspectPii())return html;
      if(/go\('appointments'\)/.test(html))return html;
      const label=t('Citas','Appointments');
      const button=`<button class="${typeof state!=='undefined'&&state.page==='appointments'?'active':''}" onclick="go('appointments')"><span aria-hidden="true">◷</span><span>${label}</span></button>`;
      const prospects=/(<button[^>]+onclick="go\('prospects'\)"[\s\S]*?<\/button>)/;
      if(prospects.test(html))return html.replace(prospects,`$1${button}`);
      const more=/(<button[^>]+onclick="go\('team'\)"[\s\S]*?<\/button>)/;
      return more.test(html)?html.replace(more,`${button}$1`):html;
    };
    return true;
  };

  const timer=setInterval(()=>{
    const mobileReady=installMobileHook();
    const roleReady=installAppointmentSettingsRoleFix();
    if(mobileReady&&roleReady)clearInterval(timer);
  },25);
  setTimeout(()=>clearInterval(timer),5000);
})();
