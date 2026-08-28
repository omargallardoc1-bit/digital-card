(()=>{
  'use strict';
  const lang=()=>typeof language!=='undefined'?language:'es';
  const t=(es,en)=>lang()==='en'?en:es;
  const esc=v=>String(v??'').replace(/[&<>'"]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[ch]));

  function ensure(){
    if(typeof state==='undefined')return;
    if(!('appointmentBlocks' in state))state.appointmentBlocks=[];
    if(!('appointmentBlocksLoading' in state))state.appointmentBlocksLoading=false;
  }

  function cardId(){return state?.appointmentSettingsCard||state?.organizationCards?.[0]?.id||''}
  function timezone(){return state?.appointmentSettings?.timezone||'UTC'}
  function canManage(){return ['owner','admin','editor'].includes(String(state?.organizationMembership?.role||'').toLowerCase())}

  function formatInZone(iso){
    const d=new Date(iso);if(Number.isNaN(d.getTime()))return iso;
    return new Intl.DateTimeFormat(lang()==='en'?'en-US':'es-MX',{dateStyle:'medium',timeStyle:'short',timeZone:timezone()}).format(d)
  }

  function blockPanel(){
    ensure();
    const id=cardId();
    if(!id)return '';
    const blocks=state.appointmentBlocks||[];
    return `<div class="panel appointment-blocks-panel">
      <div class="appointment-blocks-head"><div><h2>${esc(t('Bloqueos de agenda','Schedule blocks'))}</h2><p>${esc(t('Reserva espacios ocupados por citas externas, reuniones u otros compromisos. Estos horarios dejan de mostrarse al público.','Reserve time occupied by external appointments, meetings, or other commitments. These times are removed from public availability.'))}</p></div></div>
      <div class="formgrid">
        <div class="field"><label>${esc(t('Inicio','Start'))}</label><input id="appointment-block-start" type="datetime-local"></div>
        <div class="field"><label>${esc(t('Fin','End'))}</label><input id="appointment-block-end" type="datetime-local"></div>
        <div class="field"><label>${esc(t('Origen','Source'))}</label><select id="appointment-block-source"><option value="external">${esc(t('Cita externa','External appointment'))}</option><option value="manual">${esc(t('Bloqueo manual','Manual block'))}</option><option value="other">${esc(t('Otro compromiso','Other commitment'))}</option></select></div>
        <div class="field"><label>${esc(t('Nota (opcional)','Note (optional)'))}</label><input id="appointment-block-note" maxlength="1000" placeholder="${esc(t('Ej. cita recibida por teléfono','e.g. appointment received by phone'))}"></div>
      </div>
      <p class="readonly-note">${esc(t('Zona horaria de este bloqueo: ','Timezone for this block: '))}<b>${esc(timezone())}</b></p>
      <div class="appointment-settings-actions"><button class="primary" type="button" onclick="createAppointmentBlock()" ${canManage()?'':'disabled'}>${esc(t('Bloquear horario','Block time'))}</button></div>
      <h3>${esc(t('Próximos bloqueos','Upcoming blocks'))}</h3>
      ${state.appointmentBlocksLoading?`<div class="empty">${esc(t('Cargando…','Loading…'))}</div>`:blocks.length?`<div class="appointment-block-list">${blocks.map(b=>`<div class="appointment-block-item"><div><b>${esc(formatInZone(b.starts_at))} – ${esc(formatInZone(b.ends_at))}</b><small>${esc(b.source||'manual')}${b.note?` · ${esc(b.note)}`:''}</small></div><button class="ghost" type="button" onclick="deleteAppointmentBlock('${esc(b.id)}')">${esc(t('Liberar','Release'))}</button></div>`).join('')}</div>`:`<div class="empty">${esc(t('No hay bloqueos próximos.','No upcoming blocks.'))}</div>`}
    </div>`;
  }

  window.loadAppointmentBlocks=async function(){
    ensure();
    if(!state?.session||!state?.organization?.id||!cardId())return;
    state.appointmentBlocksLoading=true;window.render?.();
    const from=new Date().toISOString(),to=new Date(Date.now()+90*86400000).toISOString();
    const {data,error}=await db.rpc('list_organization_appointment_blocks',{target_organization_id:state.organization.id,target_card_id:cardId(),from_at:from,to_at:to});
    state.appointmentBlocksLoading=false;
    if(error){window.toast?.(t('No se pudieron cargar los bloqueos: ','Could not load blocks: ')+error.message);state.appointmentBlocks=[];window.render?.();return;}
    state.appointmentBlocks=Array.isArray(data)?data:[];window.render?.();
  };

  window.createAppointmentBlock=async function(){
    if(!canManage())return;
    const start=document.getElementById('appointment-block-start')?.value||'';
    const end=document.getElementById('appointment-block-end')?.value||'';
    if(!start||!end||start>=end){window.toast?.(t('Selecciona un inicio y fin válidos.','Select a valid start and end.'));return;}
    const {error}=await db.rpc('create_organization_appointment_block_local',{
      target_organization_id:state.organization.id,
      target_card_id:cardId(),
      local_starts_at:start.replace('T',' '),
      local_ends_at:end.replace('T',' '),
      block_timezone:timezone(),
      block_source:document.getElementById('appointment-block-source')?.value||'external',
      block_note:document.getElementById('appointment-block-note')?.value||null,
      target_branch_id:null
    });
    if(error){window.toast?.(t('No se pudo bloquear el horario: ','Could not block time: ')+error.message);return;}
    window.toast?.(t('Horario bloqueado.','Time blocked.'));await window.loadAppointmentBlocks();
  };

  window.deleteAppointmentBlock=async function(id){
    const {error}=await db.rpc('delete_organization_appointment_block',{target_organization_id:state.organization.id,target_block_id:id});
    if(error){window.toast?.(t('No se pudo liberar el horario: ','Could not release time: ')+error.message);return;}
    window.toast?.(t('Horario liberado.','Time released.'));await window.loadAppointmentBlocks();
  };

  function expandMinimumNotice(){
    const select=document.getElementById('appointment-notice');
    if(!select||select.dataset.expanded==='1')return;
    select.dataset.expanded='1';
    const current=String(select.value||'60');
    const options=[[0,'0'],[30,'30 min'],[60,'1 h'],[120,'2 h'],[240,'4 h'],[360,'6 h'],[720,'12 h'],[1440,'24 h'],[2880,'48 h'],[4320,'72 h']];
    select.innerHTML=options.map(([v,label])=>`<option value="${v}" ${String(v)===current?'selected':''}>${label}</option>`).join('');
  }

  function install(){
    if(typeof window.appointmentsView!=='function'||window.__appointmentBlocksInstalled)return false;
    window.__appointmentBlocksInstalled=true;
    const original=window.appointmentsView;
    window.appointmentsView=function(){
      const html=original();
      return `${html}${blockPanel()}`;
    };
    const originalLoadSettings=window.loadAppointmentSettings;
    if(typeof originalLoadSettings==='function')window.loadAppointmentSettings=async function(id){
      const result=await originalLoadSettings(id);
      state.appointmentBlocks=[];
      await window.loadAppointmentBlocks();
      return result;
    };
    const originalGo=window.go;
    if(typeof originalGo==='function')window.go=async function(page){
      const result=await originalGo(page);
      if(page==='appointments')setTimeout(()=>window.loadAppointmentBlocks(),0);
      return result;
    };
    const observer=new MutationObserver(()=>expandMinimumNotice());
    observer.observe(document.documentElement,{childList:true,subtree:true});
    expandMinimumNotice();
    return true;
  }

  const timer=setInterval(()=>{if(install())clearInterval(timer)},25);
  setTimeout(()=>clearInterval(timer),5000);
})();
