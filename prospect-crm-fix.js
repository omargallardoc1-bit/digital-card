(()=>{
  const t=(es,en)=>language==='en'?en:es;
  const isoOrNull=value=>{
    const raw=String(value||'').trim();
    if(!raw)return null;
    const date=new Date(raw);
    return Number.isNaN(date.getTime())?null:date.toISOString();
  };

  window.saveProspectCrm=async function(prospectId){
    if(!state.session||!state.organization?.id||!canViewOrganizationProspectPii())return;
    const card=[...document.querySelectorAll('.crm-card')].find(el=>el.dataset.prospectId===prospectId);
    if(!card){toast(t('No se encontró el prospecto en pantalla.','Prospect was not found on screen.'));return}

    const selects=card.querySelectorAll('.crm-form select');
    const status=String(selects[0]?.value||'').trim();
    const tag=String(selects[1]?.value||'').trim();
    const notes=String(card.querySelector('.crm-form textarea')?.value??'');
    const followupRaw=String(card.querySelector('input[type="datetime-local"]')?.value||'').trim();
    const followup=isoOrNull(followupRaw);

    if(!['new','contacted','follow_up','customer','discarded'].includes(status)){
      toast(t('Selecciona un estado válido.','Select a valid status.'));return;
    }
    if(followupRaw&&!followup){toast(t('La fecha de seguimiento no es válida.','The follow-up date is invalid.'));return}

    const button=card.querySelector('.crm-actions .primary');
    if(button){button.disabled=true;button.setAttribute('aria-busy','true')}

    const {data,error}=await db.rpc('update_organization_prospect',{
      target_organization_id:state.organization.id,
      target_prospect_id:prospectId,
      new_status:status,
      new_tag:tag,
      new_notes:notes,
      new_next_follow_up_at:followup
    });

    if(button){button.disabled=false;button.removeAttribute('aria-busy')}
    if(error){toast(t('No se pudo actualizar el prospecto: ','Could not update prospect: ')+error.message);return}

    const result=Array.isArray(data)?data[0]:data;
    const verified=result&&result.status===status&&String(result.tag||'')===tag&&String(result.notes||'')===String(notes.trim()||'');
    if(!verified){
      toast(t('El servidor respondió, pero la verificación no coincidió. Recargando datos…','The server responded, but verification did not match. Reloading data…'));
    }else{
      toast(t('Prospecto actualizado correctamente.','Prospect updated successfully.'));
    }

    await loadProspects();
    if(typeof window.refreshProspectFunnel==='function')window.refreshProspectFunnel();
  };
})();
