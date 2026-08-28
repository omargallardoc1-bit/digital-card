(()=>{
  'use strict';

  const t=(es,en)=>window.language==='en'?en:es;
  const escHtml=value=>String(value??'').replace(/[&<>'"]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[ch]));
  const appointmentStatuses=[
    ['requested','Solicitada','Requested'],
    ['confirmed','Confirmada','Confirmed'],
    ['rescheduled','Reprogramada','Rescheduled'],
    ['cancelled','Cancelada','Cancelled'],
    ['completed','Atendida','Completed'],
    ['no_show','No asistió','No show']
  ];

  const statusLabel=value=>appointmentStatuses.find(x=>x[0]===value)?.[window.language==='en'?2:1]||value||t('Solicitada','Requested');
  const statusClass=value=>({requested:'warning',confirmed:'active',rescheduled:'draft',cancelled:'archived',completed:'active',no_show:'archived'})[value]||'info';
  const localInput=value=>{
    const d=new Date(value);
    if(Number.isNaN(d.getTime()))return '';
    const pad=n=>String(n).padStart(2,'0');
    return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
  };
  const pretty=value=>{
    const d=new Date(value);
    if(Number.isNaN(d.getTime()))return '—';
    return new Intl.DateTimeFormat(window.language==='en'?'en-US':'es-MX',{dateStyle:'medium',timeStyle:'short'}).format(d);
  };

  function ensureState(){
    if(!window.state)return;
    if(!Array.isArray(state.appointments))state.appointments=[];
    if(typeof state.appointmentsLoading!=='boolean')state.appointmentsLoading=false;
    if(!state.appointmentsCard)state.appointmentsCard='all';
    if(!state.appointmentsWindow)state.appointmentsWindow='upcoming';
  }

  function injectStyles(){
    if(document.getElementById('mx-appointments-style'))return;
    const style=document.createElement('style');
    style.id='mx-appointments-style';
    style.textContent=`
      .appointments-toolbar{display:flex;flex-wrap:wrap;gap:12px;align-items:end;margin-bottom:18px}
      .appointments-toolbar .field{margin:0;min-width:180px;flex:1 1 180px}
      .appointments-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}
      .appointment-card{border:1px solid var(--border-default,var(--line));border-radius:14px;background:var(--surface-card,#fff);padding:18px;display:grid;gap:14px}
      .appointment-head{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}
      .appointment-head strong,.appointment-head small{display:block}.appointment-head small{color:var(--text-muted,var(--muted));margin-top:3px}
      .appointment-info{display:grid;grid-template-columns:1fr 1fr;gap:10px;background:var(--surface-muted,#f8fafc);padding:12px;border-radius:10px}
      .appointment-info span,.appointment-info strong{display:block}.appointment-info span{font-size:11px;color:var(--text-muted,var(--muted));font-weight:700;text-transform:uppercase}.appointment-info strong{font-size:13px;margin-top:2px;overflow-wrap:anywhere}
      .appointment-form{display:grid;grid-template-columns:1fr 1fr;gap:10px}.appointment-form .field{margin:0}.appointment-form .full{grid-column:1/-1}
      .appointment-actions{display:flex;gap:8px;justify-content:flex-end;border-top:1px solid var(--border-default,var(--line));padding-top:12px}
      .appointment-public-panel{margin-top:18px}.appointment-public-panel h2{margin-top:0}.appointment-public-actions{display:flex;gap:8px;flex-wrap:wrap}.appointment-public-actions button{flex:1 1 160px}
      .appointment-public-success{margin-top:18px}
      @media(max-width:900px){.appointments-grid{grid-template-columns:1fr}}
      @media(max-width:600px){.appointment-info,.appointment-form{grid-template-columns:1fr}.appointment-form .full{grid-column:auto}.appointment-actions{display:grid}.appointment-actions button{width:100%}}
    `;
    document.head.appendChild(style);
  }

  function canUseAdmin(){
    return !!(window.state?.session&&window.state?.organization?.id&&typeof window.canViewOrganizationProspectPii==='function'&&canViewOrganizationProspectPii());
  }

  function appointmentCard(a){
    const id=String(a.id||'');
    const service=a.service_title||t('Sin servicio específico','No specific service');
    return `<article class="appointment-card" data-appointment-id="${escHtml(id)}">
      <header class="appointment-head"><div><strong>${escHtml(a.prospect_name||t('Sin nombre','Unnamed'))}</strong><small>${escHtml(a.card_name||'—')} · ${escHtml(service)}</small></div><span class="badge ${statusClass(a.status)}">${escHtml(statusLabel(a.status))}</span></header>
      <div class="appointment-info">
        <div><span>${escHtml(t('Fecha y hora','Date & time'))}</span><strong>${escHtml(pretty(a.scheduled_at))}</strong></div>
        <div><span>${escHtml(t('Duración','Duration'))}</span><strong>${escHtml(a.duration_minutes||30)} min</strong></div>
        <div><span>${escHtml(t('Teléfono','Phone'))}</span><strong>${escHtml(a.phone||'—')}</strong></div>
        <div><span>${escHtml(t('Correo','Email'))}</span><strong>${escHtml(a.email||'—')}</strong></div>
      </div>
      <div class="appointment-form">
        <div class="field"><label for="appointment-status-${escHtml(id)}">${escHtml(t('Estado','Status'))}</label><select id="appointment-status-${escHtml(id)}">${appointmentStatuses.map(([value,es,en])=>`<option value="${value}" ${a.status===value?'selected':''}>${escHtml(window.language==='en'?en:es)}</option>`).join('')}</select></div>
        <div class="field"><label for="appointment-time-${escHtml(id)}">${escHtml(t('Fecha y hora','Date & time'))}</label><input id="appointment-time-${escHtml(id)}" type="datetime-local" value="${escHtml(localInput(a.scheduled_at))}"></div>
        <div class="field full"><label for="appointment-notes-${escHtml(id)}">${escHtml(t('Notas','Notes'))}</label><textarea id="appointment-notes-${escHtml(id)}" maxlength="4000">${escHtml(a.notes||'')}</textarea></div>
      </div>
      <div class="appointment-actions"><button class="primary" type="button" onclick="saveAppointment('${escHtml(id)}')">${escHtml(t('Guardar cita','Save appointment'))}</button></div>
    </article>`;
  }

  window.appointmentsView=function(){
    ensureState();injectStyles();
    if(!canUseAdmin())return `<div class="top"><div><h1>${escHtml(t('Citas','Appointments'))}</h1><p>${escHtml(t('Tu rol no incluye acceso a citas de prospectos.','Your role does not include access to prospect appointments.'))}</p></div></div>`;
    const cards=state.organizationCards||[];
    return `<div class="top"><div><h1>${escHtml(t('Citas','Appointments'))}</h1><p>${escHtml(t('Confirma, reprograma y da seguimiento a las citas generadas desde tus tarjetas.','Confirm, reschedule and manage appointments generated from your cards.'))}</p></div></div>
      <div class="panel"><div class="appointments-toolbar">
        <div class="field"><label for="appointments-card">${escHtml(t('Tarjeta','Card'))}</label><select id="appointments-card" onchange="setAppointmentsCard(this.value)"><option value="all">${escHtml(t('Todas las tarjetas','All cards'))}</option>${cards.map(c=>`<option value="${escHtml(c.id)}" ${state.appointmentsCard===c.id?'selected':''}>${escHtml(c.name)}</option>`).join('')}</select></div>
        <div class="field"><label for="appointments-window">${escHtml(t('Periodo','Period'))}</label><select id="appointments-window" onchange="setAppointmentsWindow(this.value)"><option value="upcoming" ${state.appointmentsWindow==='upcoming'?'selected':''}>${escHtml(t('Próximas','Upcoming'))}</option><option value="30" ${state.appointmentsWindow==='30'?'selected':''}>${escHtml(t('Últimos 30 días','Last 30 days'))}</option><option value="all" ${state.appointmentsWindow==='all'?'selected':''}>${escHtml(t('Todas','All'))}</option></select></div>
        <button class="ghost" type="button" onclick="loadAppointments()">${escHtml(t('Actualizar','Refresh'))}</button>
      </div>${state.appointmentsLoading?`<div class="empty">${escHtml(t('Cargando citas…','Loading appointments…'))}</div>`:state.appointments.length?`<div class="appointments-grid">${state.appointments.map(appointmentCard).join('')}</div>`:`<div class="empty">${escHtml(t('Aún no hay citas para este filtro.','There are no appointments for this filter yet.'))}</div>`}</div>`;
  };

  window.loadAppointments=async function(){
    ensureState();
    if(!canUseAdmin())return;
    state.appointmentsLoading=true;window.render?.();
    let start=null,end=null;
    if(state.appointmentsWindow==='upcoming')start=new Date().toISOString();
    else if(state.appointmentsWindow==='30')start=new Date(Date.now()-30*86400000).toISOString();
    const {data,error}=await db.rpc('list_organization_appointments',{target_organization_id:state.organization.id,target_card_id:state.appointmentsCard==='all'?null:state.appointmentsCard,window_start:start,window_end:end});
    state.appointmentsLoading=false;
    if(error){state.appointments=[];window.toast?.(t('No se pudieron cargar las citas: ','Could not load appointments: ')+error.message);window.render?.();return}
    const result=Array.isArray(data)?data[0]:data;
    state.appointments=Array.isArray(result?.items)?result.items:[];
    window.render?.();
  };

  window.setAppointmentsCard=async value=>{ensureState();if(value!=='all'&&!state.organizationCards?.some(c=>c.id===value))return;state.appointmentsCard=value;await loadAppointments()};
  window.setAppointmentsWindow=async value=>{ensureState();if(!['upcoming','30','all'].includes(value))return;state.appointmentsWindow=value;await loadAppointments()};

  window.saveAppointment=async function(id){
    const item=state.appointments.find(a=>String(a.id)===String(id));if(!item||!canUseAdmin())return;
    const root=document.querySelector(`.appointment-card[data-appointment-id="${CSS.escape(String(id))}"]`);if(!root)return;
    const status=root.querySelector(`#appointment-status-${CSS.escape(String(id))}`)?.value||item.status;
    const raw=root.querySelector(`#appointment-time-${CSS.escape(String(id))}`)?.value||'';
    const date=new Date(raw);if(!raw||Number.isNaN(date.getTime())){toast?.(t('La fecha de la cita no es válida.','The appointment date is invalid.'));return}
    const notes=root.querySelector(`#appointment-notes-${CSS.escape(String(id))}`)?.value??'';
    const {data,error}=await db.rpc('update_organization_appointment',{target_organization_id:state.organization.id,target_appointment_id:id,new_status:status,new_scheduled_at:date.toISOString(),new_notes:notes});
    if(error){toast?.(t('No se pudo actualizar la cita: ','Could not update appointment: ')+error.message);return}
    if(data&&typeof data==='object')Object.assign(item,data);
    toast?.(t('Cita actualizada.','Appointment updated.'));window.render?.();
  };

  function publicAppointmentPanel(card){
    injectStyles();
    const services=Array.isArray(card?.services)?card.services:[];
    const options=services.map(s=>`<option value="${escHtml(s.id)}">${escHtml(s.title)}</option>`).join('');
    return `<div class="panel appointment-public-panel" id="appointment-public-panel"><h2>${escHtml(t('Agenda una cita','Book an appointment'))}</h2><p class="copy-muted">${escHtml(t('Solicita una fecha y hora. El titular de la tarjeta podrá confirmarla o reprogramarla.','Request a date and time. The card owner can confirm or reschedule it.'))}</p><button class="primary" type="button" onclick="showAppointmentForm()">${escHtml(t('Agendar cita','Book appointment'))}</button><template data-appointment-service-options>${options}</template></div>`;
  }
  window.publicAppointmentPanel=publicAppointmentPanel;

  window.showAppointmentForm=function(){
    const card=state.publicCard,panel=document.getElementById('appointment-public-panel');if(!card||!panel)return;
    const services=Array.isArray(card.services)?card.services:[];
    const serviceField=services.length?`<div class="field"><label for="appointment-service">${escHtml(t('Servicio','Service'))}</label><select id="appointment-service" name="service_id"><option value="">${escHtml(t('Selecciona un servicio (opcional)','Select a service (optional)'))}</option>${services.map(s=>`<option value="${escHtml(s.id)}">${escHtml(s.title)}</option>`).join('')}</select></div>`:'';
    const min=new Date(Date.now()+30*60000);min.setSeconds(0,0);
    panel.innerHTML=`<h2>${escHtml(t('Solicitar cita','Request appointment'))}</h2><form onsubmit="submitAppointment(event)" aria-describedby="appointment-form-error">${serviceField}<div class="field"><label for="appointment-at">${escHtml(t('Fecha y hora','Date & time'))}</label><input id="appointment-at" name="scheduled_at" type="datetime-local" min="${escHtml(localInput(min))}" required></div><div class="field"><label for="appointment-name">${escHtml(t('Nombre','Name'))}</label><input id="appointment-name" name="name" maxlength="120" autocomplete="name" required></div><div class="field"><label for="appointment-phone">${escHtml(t('WhatsApp / teléfono','WhatsApp / phone'))}</label><input id="appointment-phone" name="phone" type="tel" maxlength="40" autocomplete="tel" required></div><div class="field"><label for="appointment-email">${escHtml(t('Correo (opcional)','Email (optional)'))}</label><input id="appointment-email" name="email" type="email" maxlength="254" autocomplete="email"></div><div class="field"><label for="appointment-notes">${escHtml(t('Nota (opcional)','Note (optional)'))}</label><textarea id="appointment-notes" name="notes" maxlength="4000"></textarea></div><div class="field check"><label><input name="consentimiento" type="checkbox" required><span class="consent">${escHtml(t('Acepto que mis datos sean utilizados para gestionar esta solicitud de cita y contactarme respecto a ella.','I agree that my information may be used to manage this appointment request and contact me about it.'))}</span></label></div><div class="error" id="appointment-form-error" role="alert" aria-live="polite"></div><div class="appointment-public-actions"><button class="primary" type="submit">${escHtml(t('Solicitar cita','Request appointment'))}</button><button class="ghost" type="button" onclick="hideAppointmentForm()">${escHtml(t('Cancelar','Cancel'))}</button></div></form>`;
    panel.querySelector('#appointment-at')?.focus();
  };

  window.hideAppointmentForm=function(){const panel=document.getElementById('appointment-public-panel');if(panel&&state.publicCard)panel.outerHTML=publicAppointmentPanel(state.publicCard)};

  window.submitAppointment=async function(event){
    event.preventDefault();const form=event.currentTarget,button=form.querySelector('button[type="submit"]'),errorEl=document.getElementById('appointment-form-error'),card=state.publicCard;if(!card)return;
    const values=new FormData(form),when=new Date(String(values.get('scheduled_at')||''));if(Number.isNaN(when.getTime())){errorEl.textContent=t('La fecha no es válida.','The date is invalid.');return}
    button.disabled=true;button.textContent=t('Enviando…','Sending…');errorEl.textContent='';
    const prospectPayload={card_id:card.id,name:String(values.get('name')||'').trim(),phone:String(values.get('phone')||'').trim(),email:String(values.get('email')||'').trim(),source:typeof publicEventSource==='function'?publicEventSource():'public_card',consentimiento:values.get('consentimiento')==='on'};
    const prospectResponse=await db.functions.invoke('create-prospect',{body:prospectPayload});
    if(prospectResponse.error){errorEl.textContent=t('No se pudieron registrar tus datos. Inténtalo de nuevo.','Your information could not be saved. Please try again.');button.disabled=false;button.textContent=t('Solicitar cita','Request appointment');return}
    let prospectId=prospectResponse.data?.prospect_id||prospectResponse.data?.id||null;
    if(!prospectId){
      const {data:lookup}=await db.rpc('find_recent_public_prospect_for_appointment',{target_card_id:card.id,prospect_phone:prospectPayload.phone});
      prospectId=Array.isArray(lookup)?lookup[0]:lookup;
    }
    if(!prospectId){errorEl.textContent=t('Tus datos se guardaron, pero no pudimos crear la cita. Contacta al titular desde la tarjeta.','Your information was saved, but the appointment could not be created. Please contact the card owner.');button.disabled=false;button.textContent=t('Solicitar cita','Request appointment');return}
    const {error}=await db.rpc('create_public_appointment',{target_card_id:card.id,target_prospect_id:prospectId,requested_at:when.toISOString(),target_service_id:String(values.get('service_id')||'').trim()||null,requested_duration_minutes:30,appointment_notes:String(values.get('notes')||'').trim()||null});
    if(error){errorEl.textContent=error.message||t('No se pudo crear la cita.','The appointment could not be created.');button.disabled=false;button.textContent=t('Solicitar cita','Request appointment');return}
    document.getElementById('appointment-public-panel').outerHTML=`<div class="panel success appointment-public-success"><b>${escHtml(t('Solicitud de cita enviada.','Appointment request sent.'))}</b><br>${escHtml(t('Queda pendiente de confirmación por el titular de la tarjeta.','It is pending confirmation by the card owner.'))}</div>`;
  };

  // Extend navigation and rendering without rewriting the large core file.
  function installAdminHooks(){
    if(typeof window.render!=='function'||window.__appointmentsHooksInstalled)return false;
    window.__appointmentsHooksInstalled=true;
    const originalRender=window.render;
    window.render=function(){
      originalRender();ensureState();injectStyles();
      if(!state.session||state.page!=='appointments')return;
      const main=document.getElementById('main');if(main)main.innerHTML=appointmentsView();
    };
    const originalGo=window.go;
    if(typeof originalGo==='function')window.go=async function(page){if(page==='appointments'){state.page='appointments';render();await loadAppointments();return}return originalGo(page)};
    const originalNav=window.nav;
    if(typeof originalNav==='function')window.nav=function(){
      const html=originalNav();
      if(!canUseAdmin())return html;
      return html.replace(/(<button[^>]+onclick="go\('prospects'\)"[\s\S]*?<\/button>)/,`$1<button class="${state.page==='appointments'?'active':''}" onclick="go('appointments')"><span aria-hidden="true">◷</span><span>${t('Citas','Appointments')}</span></button>`);
    };
    return true;
  }

  function installPublicHook(){
    if(typeof window.renderPublic!=='function'||window.__appointmentsPublicHookInstalled)return false;
    window.__appointmentsPublicHookInstalled=true;
    const original=window.renderPublic;
    window.renderPublic=async function(){
      await original();injectStyles();
      const card=state.publicCard;if(!card)return;
      const content=document.querySelector('.public-content');if(!content||document.getElementById('appointment-public-panel'))return;
      const note=content.querySelector('.public-note');
      const html=publicAppointmentPanel(card);
      if(note)note.insertAdjacentHTML('beforebegin',html);else content.insertAdjacentHTML('beforeend',html);
    };
  }

  const timer=setInterval(()=>{const a=installAdminHooks(),b=installPublicHook();if(a&&b)clearInterval(timer)},25);
  setTimeout(()=>clearInterval(timer),5000);
})();