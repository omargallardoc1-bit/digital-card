(()=>{
  const CARD_PLAN_CODES=['conecta-card-esencial','conecta-card-independiente','conecta-card-pyme','conecta-card-empresarial'];
  let cardPlanCatalog=[];
  const cardCapabilities=new Map();

  function packageFromCode(code){return ({'conecta-card-esencial':'esencial','conecta-card-independiente':'independiente','conecta-card-pyme':'pyme','conecta-card-empresarial':'empresarial'})[code]||''}
  function planById(id){return cardPlanCatalog.find(plan=>plan.id===id)||null}
  function planLabel(plan){if(!plan)return language==='en'?'Inherited plan':'Plan heredado';const labels={'conecta-card-esencial':'Esencial','conecta-card-independiente':'Independiente','conecta-card-pyme':'PyME','conecta-card-empresarial':'Empresarial'};return labels[plan.code]||plan.name||plan.code}
  function canManageCardPlan(){return ['owner','admin'].includes(String(currentOrganizationRole?.()||''))}
  function catalogCapabilities(plan){if(!plan)return null;const extra=plan.capabilities&&typeof plan.capabilities==='object'?plan.capabilities:{};return {...plan,qr_custom_colors:extra.qr_custom_colors===true,qr_logo_enabled:extra.qr_logo_enabled===true,qr_premium_styles:extra.qr_premium_styles===true}}
  function currentCapabilities(card=state.card){if(card?.id&&cardCapabilities.has(card.id))return cardCapabilities.get(card.id);return catalogCapabilities(planById(card?.plan_id))}

  async function loadCardPlanCatalog(){
    if(!state?.session)return;
    const {data,error}=await db.from('plans').select('id,code,name,sort_order,lead_capture_enabled,analytics_enabled,analytics_history_days,qr_enabled,profile_image_enabled,logo_image_enabled,cover_image_enabled,csv_export_enabled,visual_customization_level,video_enabled,payment_card_enabled,support_level,capabilities').in('code',CARD_PLAN_CODES).eq('status','active').order('sort_order',{ascending:true});
    if(error){console.warn('No se pudo cargar el catálogo de tipos de tarjeta',error);return}
    cardPlanCatalog=data||[];
  }

  async function loadCardCapabilities(cardId){
    if(!cardId||!state?.session)return null;
    const {data,error}=await db.rpc('get_card_capabilities',{target_card_id:cardId});
    if(error){console.warn('No se pudieron cargar las capacidades de la tarjeta',error);return null}
    const row=Array.isArray(data)?data[0]:data;
    if(row)cardCapabilities.set(cardId,{...row,qr_custom_colors:row.capabilities?.qr_custom_colors===true,qr_logo_enabled:row.capabilities?.qr_logo_enabled===true,qr_premium_styles:row.capabilities?.qr_premium_styles===true});
    return row||null;
  }

  async function loadAllCardCapabilities(){
    if(!state?.session||!Array.isArray(state.cards))return;
    await Promise.all(state.cards.filter(card=>card?.id).map(card=>loadCardCapabilities(card.id)));
  }

  function capabilityItem(label,enabled,detail=''){
    return `<div class="capability"><span>${esc(label)}</span><strong class="${enabled?'':'off'}">${enabled?esc(detail||'Incluido'):'No incluido'}</strong></div>`;
  }

  function cardPlanEditorHtml(){
    const card=state.card||{},caps=currentCapabilities(card),selected=String(card.plan_id||''),editable=canManageCardPlan(),inherited=!card.plan_id&&!!card.id;
    const options=(inherited?`<option value="" selected>${language==='en'?'Inherited temporarily':'Heredado temporalmente'}</option>`:'')+cardPlanCatalog.map(plan=>`<option value="${esc(plan.id)}" ${selected===plan.id?'selected':''}>${esc(planLabel(plan))}</option>`).join('');
    const status=caps?`<div class="capability-grid" style="margin-top:14px">${capabilityItem(language==='en'?'Lead capture':'Captura de prospectos',caps.lead_capture_enabled===true)}${capabilityItem(language==='en'?'Analytics':'Estadísticas',caps.analytics_enabled===true,caps.analytics_history_days?`${caps.analytics_history_days} días`:'')}${capabilityItem('QR',caps.qr_enabled===true)}${capabilityItem(language==='en'?'Logo':'Logo',caps.logo_image_enabled===true)}${capabilityItem(language==='en'?'Cover':'Portada',caps.cover_image_enabled===true)}${capabilityItem(language==='en'?'CSV export':'Exportación CSV',caps.csv_export_enabled===true)}${capabilityItem('Video',caps.video_enabled===true)}${capabilityItem(language==='en'?'Payment card':'Tarjeta de pago',caps.payment_card_enabled===true)}</div>`:'<p class="readonly-note" style="margin-top:10px">'+(language==='en'?'Select a card type to view its features.':'Selecciona un tipo de tarjeta para ver sus beneficios.')+'</p>';
    return `<div data-card-plan-editor="1"><div class="field"><label for="card-plan-select">${language==='en'?'Card type':'Tipo de tarjeta'}</label><select id="card-plan-select" onchange="changeCardPlan(this.value)" ${editable?'':'disabled'}>${options}</select><small class="field-help">${editable?(language==='en'?'The card type controls this card’s features.':'El tipo de tarjeta determina los beneficios de esta tarjeta.'):(language==='en'?'Only an owner or administrator can change the card type.':'Solo un propietario o administrador puede cambiar el tipo de tarjeta.')}</small></div>${status}</div>`;
  }

  function injectCardPlanEditor(){
    if(state?.page!=='editor'||!state?.session)return;
    const sections=document.querySelector('.editor-sections');
    if(!sections||sections.querySelector('[data-card-plan-editor]'))return;
    sections.insertAdjacentHTML('afterbegin',editorBlock('card-plan',language==='en'?'Card type':'Tipo de tarjeta',cardPlanEditorHtml(),true,'0'));
    applyCapabilityGuards();
  }

  function applyCapabilityGuards(){
    const caps=currentCapabilities();
    if(!caps)return;
    const contact=document.querySelector('[data-editor-block="contact"]');
    const capture=contact?.querySelector('input[type="checkbox"]');
    if(capture&&caps.lead_capture_enabled!==true){capture.disabled=true;capture.checked=false;if(state.card)state.card.capture=false;const label=capture.closest('label');if(label&&!label.querySelector('[data-plan-limit]'))label.insertAdjacentHTML('beforeend',`<small data-plan-limit class="field-help">${language==='en'?'Not included in this card type.':'No incluido en este tipo de tarjeta.'}</small>`)}
    for(const [kind,allowed] of [['logo',caps.logo_image_enabled===true],['cover',caps.cover_image_enabled===true]]){
      if(allowed)continue;const control=document.querySelector(`.media-control[data-kind="${kind}"]`);if(!control)continue;control.querySelectorAll('input,button').forEach(el=>el.disabled=true);if(!control.querySelector('[data-plan-limit]'))control.insertAdjacentHTML('beforeend',`<p data-plan-limit class="media-help">${language==='en'?'Not included in this card type.':'No incluido en este tipo de tarjeta.'}</p>`)
    }
  }

  window.changeCardPlan=async function(planId){
    if(!canManageCardPlan()||!planId)return;
    const plan=planById(planId);if(!plan)return;
    if(!state.card?.id){state.card.plan_id=plan.id;state.card.package=packageFromCode(plan.code);if(plan.lead_capture_enabled!==true)state.card.capture=false;render();return}
    const {data,error}=await db.rpc('set_card_plan',{target_card_id:state.card.id,target_plan_id:plan.id});
    if(error){toast((language==='en'?'Card type could not be changed: ':'No se pudo cambiar el tipo de tarjeta: ')+error.message);render();return}
    const row=Array.isArray(data)?data[0]:data;state.card.plan_id=row?.plan_id||plan.id;state.card.package=packageFromCode(row?.plan_code||plan.code);
    state.cards=state.cards.map(card=>card.id===state.card.id?{...card,plan_id:state.card.plan_id,package:state.card.package}:card);
    await loadCardCapabilities(state.card.id);
    const caps=currentCapabilities();
    if(caps?.lead_capture_enabled!==true&&state.card.capture){state.card.capture=false;await originalSaveCard()}
    toast(language==='en'?'Card type updated.':'Tipo de tarjeta actualizado.');render();
  };

  const originalFinishRender=finishRender;
  finishRender=function(...args){const result=originalFinishRender(...args);injectCardPlanEditor();return result};

  const originalLoadCards=loadCards;
  loadCards=async function(...args){await loadCardPlanCatalog();const result=await originalLoadCards(...args);await loadAllCardCapabilities();render();return result};

  const originalEditCard=editCard;
  editCard=async function(id){const result=await originalEditCard(id);await loadCardCapabilities(id);render();return result};

  const originalNewCard=newCard;
  newCard=function(...args){const result=originalNewCard(...args);if(state.page==='editor'&&!state.card.id&&!state.card.plan_id&&cardPlanCatalog.length){const plan=cardPlanCatalog[0];state.card.plan_id=plan.id;state.card.package=packageFromCode(plan.code);state.card.capture=plan.lead_capture_enabled===true}render();return result};

  const originalSaveCard=saveCard;
  saveCard=async function(...args){const wasNew=!state.card?.id,desiredPlanId=state.card?.plan_id||null;if(wasNew&&!desiredPlanId){toast(language==='en'?'Select a card type before saving.':'Selecciona el tipo de tarjeta antes de guardar.');return false}const selectedPlan=planById(desiredPlanId);if(selectedPlan&&selectedPlan.lead_capture_enabled!==true)state.card.capture=false;const result=await originalSaveCard(...args);if(!result)return result;if(wasNew&&desiredPlanId&&state.card?.id){const {data,error}=await db.rpc('set_card_plan',{target_card_id:state.card.id,target_plan_id:desiredPlanId});if(error){toast((language==='en'?'The card was created, but its type could not be assigned: ':'La tarjeta se creó, pero no se pudo asignar su tipo: ')+error.message);return false}const row=Array.isArray(data)?data[0]:data;state.card.plan_id=row?.plan_id||desiredPlanId;state.card.package=packageFromCode(row?.plan_code||selectedPlan?.code);await loadCardCapabilities(state.card.id);await refreshCardAndOrganization(state.card.id);toast(language==='en'?'Card saved with its assigned type.':'Tarjeta guardada con su tipo asignado.');render()}return result};

  const originalLogout=logout;
  logout=async function(...args){cardPlanCatalog=[];cardCapabilities.clear();return originalLogout(...args)};

  void (async()=>{await loadCardPlanCatalog();if(state?.session){await loadAllCardCapabilities();render()}})();
})();
