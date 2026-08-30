(()=>{
  'use strict';
  const lang=()=>typeof language!=='undefined'?language:'es';
  const t=(es,en)=>lang()==='en'?en:es;
  const managed=()=>['owner','admin'].includes(String(state?.organizationMembership?.role||'').toLowerCase());

  const ensureStyle=()=>{
    if(document.getElementById('appointment-confirmation-actions-style'))return;
    const s=document.createElement('style');
    s.id='appointment-confirmation-actions-style';
    s.textContent=`.appointment-decision-actions{display:flex;gap:8px;flex-wrap:wrap;border-top:1px solid var(--border-default,var(--line));padding-top:12px;margin-top:2px}.appointment-decision-actions button{flex:1 1 130px}.appointment-confirm-btn{background:var(--semantic-success,#15803d);color:#fff;padding:10px 14px;border-radius:10px;font-weight:700}.appointment-reject-btn{background:#fff;color:var(--semantic-danger,#b42318);border:1px solid #f1b7b2;padding:10px 14px;border-radius:10px;font-weight:700}.appointment-decision-actions button:disabled{opacity:.6;cursor:wait}`;
    document.head.appendChild(s);
  };

  window.manageAppointmentDecision=async function(id,action){
    if(!managed()||!['confirm','reject','cancel'].includes(action))return;
    const card=document.querySelector(`.appointment-card[data-appointment-id="${CSS.escape(String(id))}"]`);
    const buttons=card?.querySelectorAll('.appointment-decision-actions button')||[];
    buttons.forEach(b=>b.disabled=true);
    const {data,error}=await db.functions.invoke('manage-appointment',{body:{appointment_id:id,action}});
    if(error){
      buttons.forEach(b=>b.disabled=false);
      window.toast?.((data?.error||error.message)||t('No se pudo actualizar la cita.','Could not update the appointment.'));
      return;
    }
    const item=Array.isArray(state?.appointments)?state.appointments.find(a=>String(a.id)===String(id)):null;
    if(item&&data?.appointment)Object.assign(item,data.appointment);
    window.toast?.(action==='confirm'?t('Cita confirmada.','Appointment confirmed.'):t('Cita rechazada.','Appointment rejected.'));
    if(typeof window.loadAppointments==='function')await window.loadAppointments();else window.render?.();
  };

  const decorate=()=>{
    ensureStyle();
    if(!managed())return;
    document.querySelectorAll('.appointment-card[data-appointment-id]').forEach(card=>{
      if(card.querySelector('.appointment-decision-actions'))return;
      const id=card.getAttribute('data-appointment-id');
      const item=Array.isArray(state?.appointments)?state.appointments.find(a=>String(a.id)===String(id)):null;
      if(!item||item.status!=='requested')return;
      const actions=document.createElement('div');
      actions.className='appointment-decision-actions';
      actions.setAttribute('aria-label',t('Decisión de la cita','Appointment decision'));
      actions.innerHTML=`<button type="button" class="appointment-confirm-btn">${t('Confirmar cita','Confirm appointment')}</button><button type="button" class="appointment-reject-btn">${t('Rechazar','Reject')}</button>`;
      actions.querySelector('.appointment-confirm-btn')?.addEventListener('click',()=>window.manageAppointmentDecision(id,'confirm'));
      actions.querySelector('.appointment-reject-btn')?.addEventListener('click',()=>window.manageAppointmentDecision(id,'reject'));
      card.appendChild(actions);
    });
  };

  decorate();
  new MutationObserver(decorate).observe(document.documentElement,{childList:true,subtree:true});
})();
