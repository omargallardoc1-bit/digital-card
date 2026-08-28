(()=>{
  'use strict';

  const t=(es,en)=>(typeof language!=='undefined'&&language==='en')?en:es;

  window.submitAppointment=async function(event){
    event.preventDefault();
    const form=event.currentTarget;
    const button=form.querySelector('button[type="submit"]');
    const errorEl=document.getElementById('appointment-form-error');
    const card=state.publicCard;
    if(!card)return;

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
      let message=t('No se pudo crear la cita.','The appointment could not be created.');
      try{
        const detail=await appointmentResponse.error.context?.json?.();
        if(detail?.error)message=detail.error;
      }catch{}
      errorEl.textContent=message;
      button.disabled=false;
      button.textContent=t('Solicitar cita','Request appointment');
      return;
    }

    const panel=document.getElementById('appointment-public-panel');
    if(panel)panel.outerHTML=`<div class="panel success appointment-public-success"><b>${t('Solicitud de cita enviada.','Appointment request sent.')}</b><br>${t('Queda pendiente de confirmación por el titular de la tarjeta.','It is pending confirmation by the card owner.')}</div>`;
  };
})();
