(()=>{
  'use strict';

  const lang=()=>typeof language!=='undefined'?language:'es';
  const t=(es,en)=>lang()==='en'?en:es;

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
    const when=new Date(String(values.get('scheduled_at')||''));
    if(Number.isNaN(when.getTime())){
      errorEl.textContent=t('La fecha no es válida.','The date is invalid.');
      return;
    }

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
      duration_minutes:30,
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

  const timer=setInterval(()=>{if(installMobileHook())clearInterval(timer)},25);
  setTimeout(()=>clearInterval(timer),5000);
})();
