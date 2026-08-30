(()=>{
  'use strict';
  const lang=()=>typeof language!=='undefined'?language:'es';
  const t=(es,en)=>lang()==='en'?en:es;
  const managed=()=>['owner','admin'].includes(String(state?.organizationMembership?.role||'').toLowerCase());
  const prospectFor=item=>Array.isArray(state?.prospects)?state.prospects.find(p=>String(p.id)===String(item?.prospect_id)):null;
  const cardFor=item=>Array.isArray(state?.cards)?state.cards.find(c=>String(c.id)===String(item?.card_id)):null;
  const phone=value=>String(value||'').replace(/\D/g,'');
  const calendarUrl=item=>{const u=new URL('/appointment-confirmed.html',location.origin);u.searchParams.set('title',cardFor(item)?.name||cardFor(item)?.title||t('Cita confirmada','Confirmed appointment'));u.searchParams.set('start',item.scheduled_at);u.searchParams.set('duration',String(item.duration_minutes||30));return u.toString()};
  const confirmationText=item=>{const when=new Intl.DateTimeFormat(lang()==='en'?'en-US':'es-MX',{dateStyle:'full',timeStyle:'short'}).format(new Date(item.scheduled_at));return t(`Tu cita ha sido confirmada para ${when}.\n\nAgrégala a tu calendario aquí:\n${calendarUrl(item)}`,`Your appointment has been confirmed for ${when}.\n\nAdd it to your calendar here:\n${calendarUrl(item)}`)};

  const ensureStyle=()=>{
    if(document.getElementById('appointment-confirmation-actions-style'))return;
    const s=document.createElement('style');s.id='appointment-confirmation-actions-style';s.textContent=`.appointment-decision-actions{display:flex;gap:8px;flex-wrap:wrap;border-top:1px solid var(--border-default,var(--line));padding-top:12px;margin-top:2px}.appointment-decision-actions button{flex:1 1 130px}.appointment-confirm-btn{background:var(--semantic-success,#15803d);color:#fff;padding:10px 14px;border-radius:10px;font-weight:700}.appointment-reject-btn{background:#fff;color:var(--semantic-danger,#b42318);border:1px solid #f1b7b2;padding:10px 14px;border-radius:10px;font-weight:700}.appointment-decision-actions button:disabled{opacity:.6;cursor:wait}`;document.head.appendChild(s);
  };

  window.manageAppointmentDecision=async function(id,action){
    if(!managed()||!['confirm','reject','cancel'].includes(action))return;
    const item=Array.isArray(state?.appointments)?state.appointments.find(a=>String(a.id)===String(id)):null;
    const card=document.querySelector(`.appointment-card[data-appointment-id="${CSS.escape(String(id))}"]`);const buttons=card?.querySelectorAll('.appointment-decision-actions button')||[];buttons.forEach(b=>b.disabled=true);
    const {data,error}=await db.functions.invoke('manage-appointment',{body:{appointment_id:id,action}});
    if(error){buttons.forEach(b=>b.disabled=false);window.toast?.((data?.error||error.message)||t('No se pudo actualizar la cita.','Could not update the appointment.'));return;}
    if(item&&data?.appointment)Object.assign(item,data.appointment);
    if(action==='confirm'&&item){
      const prospect=prospectFor(item),number=phone(prospect?.phone||prospect?.telefono||prospect?.whatsapp);
      if(number){window.open(`https://wa.me/${number}?text=${encodeURIComponent(confirmationText(item))}`,'_blank','noopener');window.toast?.(t('Cita confirmada. Se abrió WhatsApp con el aviso listo.','Appointment confirmed. WhatsApp opened with the message ready.'));}
      else{await navigator.clipboard?.writeText(confirmationText(item)).catch(()=>{});window.toast?.(t('Cita confirmada. Copiamos el aviso para compartirlo con el cliente.','Appointment confirmed. The customer message was copied for sharing.'));}
    }else window.toast?.(t('Cita rechazada.','Appointment rejected.'));
    if(typeof window.loadAppointments==='function')await window.loadAppointments();else window.render?.();
  };

  const decorate=()=>{ensureStyle();if(!managed())return;document.querySelectorAll('.appointment-card[data-appointment-id]').forEach(card=>{if(card.querySelector('.appointment-decision-actions'))return;const id=card.getAttribute('data-appointment-id');const item=Array.isArray(state?.appointments)?state.appointments.find(a=>String(a.id)===String(id)):null;if(!item||item.status!=='requested')return;const actions=document.createElement('div');actions.className='appointment-decision-actions';actions.setAttribute('aria-label',t('Decisión de la cita','Appointment decision'));actions.innerHTML=`<button type="button" class="appointment-confirm-btn">${t('Confirmar cita','Confirm appointment')}</button><button type="button" class="appointment-reject-btn">${t('Rechazar','Reject')}</button>`;actions.querySelector('.appointment-confirm-btn')?.addEventListener('click',()=>window.manageAppointmentDecision(id,'confirm'));actions.querySelector('.appointment-reject-btn')?.addEventListener('click',()=>window.manageAppointmentDecision(id,'reject'));card.appendChild(actions)})};
  decorate();new MutationObserver(decorate).observe(document.documentElement,{childList:true,subtree:true});
})();
