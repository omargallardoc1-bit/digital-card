(()=>{
  'use strict';

  const lang=()=>typeof language!=='undefined'?language:'es';
  const t=(es,en)=>lang()==='en'?en:es;
  const esc=value=>String(value??'').replace(/[&<>'"]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[ch]));
  const days=[['0','Domingo','Sunday'],['1','Lunes','Monday'],['2','Martes','Tuesday'],['3','Miércoles','Wednesday'],['4','Jueves','Thursday'],['5','Viernes','Friday'],['6','Sábado','Saturday']];
  const tzOptions=['UTC','America/Mazatlan','America/Mexico_City','America/Tijuana','America/Chihuahua','America/Hermosillo','America/Monterrey','America/Cancun','America/New_York','America/Chicago','America/Denver','America/Los_Angeles','Europe/Madrid'];

  function ensure(){
    if(typeof state==='undefined')return;
    if(!('appointmentSettings' in state))state.appointmentSettings=null;
    if(!('appointmentSettingsCard' in state))state.appointmentSettingsCard='';
    if(!('appointmentSettingsLoading' in state))state.appointmentSettingsLoading=false;
    if(!('appointmentPublicSlots' in state))state.appointmentPublicSlots=[];
    if(!('appointmentPublicTimezone' in state))state.appointmentPublicTimezone='UTC';
  }

  function canConfigure(){
    const role=state?.organizationRole||state?.membership?.role||state?.memberRole||'';
    return ['owner','admin'].includes(String(role).toLowerCase()) || state?.organization?.owner_id===state?.session?.user?.id;
  }

  function rulesGrid(settings){
    const byDay=new Map((settings?.rules||[]).filter(r=>r?.is_active!==false).map(r=>[String(r.weekday),r]));
    return `<div class="appointment-rules-grid">${days.map(([value,es,en])=>{
      const r=byDay.get(value);
      return `<div class="appointment-rule-row" data-weekday="${value}"><label class="appointment-day-check"><input type="checkbox" data-rule-enabled ${r?'checked':''}><span>${esc(lang()==='en'?en:es)}</span></label><input type="time" data-rule-start value="${esc(r?.start_time||'09:00')}" ${r?'':'disabled'}><span>–</span><input type="time" data-rule-end value="${esc(r?.end_time||'18:00')}" ${r?'':'disabled'}></div>`;
    }).join('')}</div>`;
  }

  function configPanel(){
    ensure();
    const cards=state.organizationCards||[];
    if(!cards.length)return `<div class="panel appointment-settings-panel"><h2>${esc(t('Configuración de agenda','Schedule settings'))}</h2><p>${esc(t('Primero crea una tarjeta para configurar su agenda.','Create a card first to configure its schedule.'))}</p></div>`;
    const selected=state.appointmentSettingsCard||cards[0]?.id||'';
    const s=state.appointmentSettings;
    const loading=state.appointmentSettingsLoading;
    const capability=s?.capability_enabled!==false;
    const tz=s?.timezone||'UTC';
    const tzs=Array.from(new Set([tz,...tzOptions]));
    return `<div class="panel appointment-settings-panel">
      <div class="appointment-settings-head"><div><h2>${esc(t('Configuración de agenda','Schedule settings'))}</h2><p>${esc(t('La zona horaria y los horarios pertenecen a esta tarjeta. La estructura ya admite sucursales futuras.','Timezone and availability belong to this card. The structure is ready for future branches.'))}</p></div></div>
      <div class="formgrid">
        <div class="field"><label>${esc(t('Tarjeta','Card'))}</label><select onchange="changeAppointmentSettingsCard(this.value)">${cards.map(c=>`<option value="${esc(c.id)}" ${selected===c.id?'selected':''}>${esc(c.name||c.slug||'Tarjeta')}</option>`).join('')}</select></div>
        ${loading?`<div class="field"><label>&nbsp;</label><div>${esc(t('Cargando…','Loading…'))}</div></div>`:''}
      </div>
      ${!s?`<div class="empty">${esc(t('Selecciona una tarjeta para cargar su configuración.','Select a card to load its settings.'))}</div>`:`
        ${!capability?`<div class="qr-warning">${esc(t('El plan efectivo de esta tarjeta no incluye agenda de citas.','The effective plan for this card does not include appointment scheduling.'))}</div>`:''}
        <div class="formgrid">
          <div class="field check"><label><input id="appointment-enabled" type="checkbox" ${s.enabled?'checked':''} ${!capability?'disabled':''}><span>${esc(t('Activar agenda pública en esta tarjeta','Enable public booking on this card'))}</span></label></div>
          <div class="field"><label>${esc(t('Zona horaria','Timezone'))}</label><select id="appointment-timezone">${tzs.map(z=>`<option value="${esc(z)}" ${z===tz?'selected':''}>${esc(z)}</option>`).join('')}</select></div>
          <div class="field"><label>${esc(t('Duración de cita','Appointment duration'))}</label><select id="appointment-duration">${[15,20,30,45,60,90,120].map(v=>`<option value="${v}" ${Number(s.default_duration_minutes||30)===v?'selected':''}>${v} min</option>`).join('')}</select></div>
          <div class="field"><label>${esc(t('Intervalo entre horarios','Slot interval'))}</label><select id="appointment-interval">${[15,20,30,45,60].map(v=>`<option value="${v}" ${Number(s.slot_interval_minutes||30)===v?'selected':''}>${v} min</option>`).join('')}</select></div>
          <div class="field"><label>${esc(t('Anticipación mínima','Minimum notice'))}</label><select id="appointment-notice">${[[0,'0'],[30,'30 min'],[60,'1 h'],[120,'2 h'],[240,'4 h'],[1440,'24 h']].map(([v,label])=>`<option value="${v}" ${Number(s.min_notice_minutes||60)===v?'selected':''}>${label}</option>`).join('')}</select></div>
          <div class="field"><label>${esc(t('Días máximos para reservar','Maximum booking window'))}</label><select id="appointment-max-days">${[14,30,60,90,180,365].map(v=>`<option value="${v}" ${Number(s.max_booking_days||60)===v?'selected':''}>${v} ${esc(t('días','days'))}</option>`).join('')}</select></div>
        </div>
        <h3>${esc(t('Horario semanal','Weekly availability'))}</h3>
        ${rulesGrid(s)}
        <div class="appointment-settings-actions"><button class="primary" type="button" onclick="saveAppointmentSettings()" ${!canConfigure()?'disabled':''}>${esc(t('Guardar configuración','Save settings'))}</button></div>
        ${!canConfigure()?`<p class="readonly-note">${esc(t('Solo propietario o administrador puede cambiar la configuración.','Only the owner or an administrator can change these settings.'))}</p>`:''}
      `}
    </div>`;
  }

  window.loadAppointmentSettings=async function(cardId){
    ensure();
    if(!state.session||!state.organization?.id||!cardId)return;
    state.appointmentSettingsCard=cardId;
    state.appointmentSettingsLoading=true;
    window.render?.();
    const {data,error}=await db.rpc('get_organization_appointment_settings',{target_organization_id:state.organization.id,target_card_id:cardId});
    state.appointmentSettingsLoading=false;
    if(error){state.appointmentSettings=null;window.toast?.(t('No se pudo cargar la configuración: ','Could not load settings: ')+error.message);window.render?.();return;}
    state.appointmentSettings=data||null;
    window.render?.();
  };

  window.changeAppointmentSettingsCard=async function(cardId){await window.loadAppointmentSettings(cardId)};

  window.saveAppointmentSettings=async function(){
    if(!canConfigure()||!state.appointmentSettingsCard)return;
    const rules=[];
    document.querySelectorAll('.appointment-rule-row').forEach(row=>{
      const enabled=row.querySelector('[data-rule-enabled]')?.checked;
      if(!enabled)return;
      rules.push({weekday:Number(row.dataset.weekday),start_time:row.querySelector('[data-rule-start]')?.value||'09:00',end_time:row.querySelector('[data-rule-end]')?.value||'18:00',is_active:true});
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

  function installRuleToggle(){
    document.addEventListener('change',event=>{
      const target=event.target;
      if(!(target instanceof HTMLInputElement)||!target.matches('[data-rule-enabled]'))return;
      const row=target.closest('.appointment-rule-row');
      row?.querySelectorAll('[data-rule-start],[data-rule-end]').forEach(el=>el.disabled=!target.checked);
    });
  }

  function installAdminView(){
    if(typeof window.appointmentsView!=='function'||window.__appointmentSettingsViewInstalled)return false;
    window.__appointmentSettingsViewInstalled=true;
    const original=window.appointmentsView;
    window.appointmentsView=function(){
      ensure();
      const html=original();
      return `${configPanel()}${html}`;
    };
    const originalGo=window.go;
    if(typeof originalGo==='function')window.go=async function(page){
      const result=await originalGo(page);
      if(page==='appointments'){
        ensure();
        const first=state.appointmentSettingsCard||state.organizationCards?.[0]?.id;
        if(first&&!state.appointmentSettings&&!state.appointmentSettingsLoading)await window.loadAppointmentSettings(first);
      }
      return result;
    };
    return true;
  }

  async function fetchPublicSlots(card){
    const res=await db.functions.invoke('list-appointment-slots',{body:{card_id:card.id,days:14}});
    if(res.error)return {slots:[],timezone:'UTC',duration_minutes:30};
    return {slots:Array.isArray(res.data?.slots)?res.data.slots:[],timezone:res.data?.timezone||'UTC',duration_minutes:Number(res.data?.duration_minutes||30)};
  }

  function slotLabel(iso,timezone){
    const d=new Date(iso);
    if(Number.isNaN(d.getTime()))return iso;
    return new Intl.DateTimeFormat(lang()==='en'?'en-US':'es-MX',{weekday:'short',day:'numeric',month:'short',hour:'numeric',minute:'2-digit',timeZone:timezone}).format(d);
  }

  window.showAppointmentForm=async function(){
    ensure();
    const card=state.publicCard,panel=document.getElementById('appointment-public-panel');
    if(!card||!panel)return;
    panel.innerHTML=`<h2>${esc(t('Solicitar cita','Request appointment'))}</h2><div class="empty">${esc(t('Consultando horarios disponibles…','Checking available times…'))}</div>`;
    const availability=await fetchPublicSlots(card);
    state.appointmentPublicSlots=availability.slots;
    state.appointmentPublicTimezone=availability.timezone;
    if(!availability.slots.length){panel.remove();return;}
    const services=Array.isArray(card.services)?card.services:[];
    const serviceField=services.length?`<div class="field"><label>${esc(t('Servicio','Service'))}</label><select name="service_id"><option value="">${esc(t('Selecciona un servicio (opcional)','Select a service (optional)'))}</option>${services.map(s=>`<option value="${esc(s.id)}">${esc(s.title)}</option>`).join('')}</select></div>`:'';
    panel.innerHTML=`<h2>${esc(t('Solicitar cita','Request appointment'))}</h2><p class="copy-muted">${esc(t('Horarios mostrados en la zona horaria de esta agenda: ','Times shown in this schedule timezone: '))}<b>${esc(availability.timezone)}</b></p><form onsubmit="submitAppointment(event)" aria-describedby="appointment-form-error">${serviceField}<div class="field"><label>${esc(t('Horario disponible','Available time'))}</label><select name="scheduled_at" required>${availability.slots.map(s=>`<option value="${esc(s.scheduled_at)}">${esc(slotLabel(s.scheduled_at,availability.timezone))}</option>`).join('')}</select></div><input type="hidden" name="duration_minutes" value="${esc(availability.duration_minutes)}"><div class="field"><label>${esc(t('Nombre','Name'))}</label><input name="name" maxlength="120" autocomplete="name" required></div><div class="field"><label>${esc(t('WhatsApp / teléfono','WhatsApp / phone'))}</label><input name="phone" type="tel" maxlength="40" autocomplete="tel" required></div><div class="field"><label>${esc(t('Correo (opcional)','Email (optional)'))}</label><input name="email" type="email" maxlength="254" autocomplete="email"></div><div class="field"><label>${esc(t('Nota (opcional)','Note (optional)'))}</label><textarea name="notes" maxlength="4000"></textarea></div><div class="field check"><label><input name="consentimiento" type="checkbox" required><span class="consent">${esc(t('Acepto que mis datos sean utilizados para gestionar esta solicitud de cita y contactarme respecto a ella.','I agree that my information may be used to manage this appointment request and contact me about it.'))}</span></label></div><div class="error" id="appointment-form-error" role="alert" aria-live="polite"></div><div class="appointment-public-actions"><button class="primary" type="submit">${esc(t('Solicitar cita','Request appointment'))}</button><button class="ghost" type="button" onclick="hideAppointmentForm()">${esc(t('Cancelar','Cancel'))}</button></div></form>`;
  };

  // Hide the public CTA entirely unless the server returns at least one valid slot.
  const checkedCards=new Set();
  const observer=new MutationObserver(async()=>{
    const panel=document.getElementById('appointment-public-panel');
    const card=typeof state!=='undefined'?state.publicCard:null;
    if(!panel||!card||checkedCards.has(card.id))return;
    checkedCards.add(card.id);
    const availability=await fetchPublicSlots(card);
    state.appointmentPublicSlots=availability.slots;
    state.appointmentPublicTimezone=availability.timezone;
    if(!availability.slots.length){panel.remove();return;}
    const p=panel.querySelector('p');
    if(p)p.textContent=t('Elige uno de los horarios disponibles de esta agenda.','Choose one of the available times for this schedule.');
  });
  observer.observe(document.documentElement,{childList:true,subtree:true});

  function injectStyles(){
    if(document.getElementById('appointment-config-styles'))return;
    const s=document.createElement('style');s.id='appointment-config-styles';s.textContent=`.appointment-settings-panel{margin-bottom:18px}.appointment-settings-panel h2{margin:0}.appointment-settings-head p{color:var(--muted);margin:5px 0 16px}.appointment-rules-grid{display:grid;gap:8px;margin:12px 0 16px}.appointment-rule-row{display:grid;grid-template-columns:minmax(120px,1fr) 130px auto 130px;align-items:center;gap:8px;border:1px solid var(--line);border-radius:10px;padding:10px}.appointment-day-check{display:flex;gap:8px;align-items:center;font-weight:700}.appointment-rule-row input[type=time]{padding:8px;border:1px solid var(--line);border-radius:8px}.appointment-settings-actions{display:flex;justify-content:flex-end;margin-top:14px}@media(max-width:600px){.appointment-rule-row{grid-template-columns:1fr 1fr auto 1fr}}`;
    document.head.appendChild(s);
  }

  injectStyles();installRuleToggle();
  const timer=setInterval(()=>{if(installAdminView())clearInterval(timer)},25);
  setTimeout(()=>clearInterval(timer),5000);
})();
