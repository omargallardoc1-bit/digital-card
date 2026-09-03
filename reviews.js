(()=>{
  'use strict';

  const isPublic=()=>location.pathname.startsWith('/c/');
  const escReview=value=>String(value??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
  const starText=n=>'★'.repeat(Math.max(0,Math.min(5,Number(n)||0)))+'☆'.repeat(5-Math.max(0,Math.min(5,Number(n)||0)));
  const reviewState={publicRows:[],adminRows:[],loading:false};

  function injectStyles(){
    if(document.getElementById('mx-reviews-styles'))return;
    const style=document.createElement('style');style.id='mx-reviews-styles';style.textContent=`
      .mx-reviews{display:grid;gap:14px}.mx-reviews-summary{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:14px;border:1px solid var(--border-default,#e5e7eb);border-radius:14px;background:var(--surface-muted,#f8fafc)}
      .mx-reviews-score{font-size:28px;font-weight:800}.mx-stars{letter-spacing:2px;color:#b7791f;font-size:18px}.mx-review-list{display:grid;gap:10px}.mx-review-item{padding:14px;border:1px solid var(--border-default,#e5e7eb);border-radius:14px;background:var(--surface-card,#fff)}
      .mx-review-head{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}.mx-review-name{font-weight:800}.mx-review-meta{font-size:12px;color:var(--text-muted,#667085)}.mx-review-comment{margin:8px 0 0;white-space:pre-wrap;overflow-wrap:anywhere;color:var(--text-secondary,#475467)}
      .mx-review-form{display:grid;gap:12px;padding:14px;border:1px solid var(--border-default,#e5e7eb);border-radius:14px;background:var(--surface-card,#fff)}.mx-review-form .field{margin:0}.mx-rating-picker{display:flex;gap:5px}.mx-rating-picker button{min-width:40px;padding:7px 9px;background:#fff;border:1px solid var(--border-default,#e5e7eb);color:#b7791f}.mx-rating-picker button.selected{background:#fff7df;border-color:#d6b65a}
      .mx-review-actions{display:flex;gap:8px;flex-wrap:wrap}.mx-review-status{font-size:12px;font-weight:800;padding:4px 8px;border-radius:999px;background:#eef2ff}.mx-review-admin{margin-top:18px}.mx-review-empty{padding:12px;color:var(--text-muted,#667085);text-align:center}.mx-review-service{margin-top:4px;font-size:12px;color:var(--text-muted,#667085)}
    `;document.head.appendChild(style);
  }

  async function getCapabilities(cardId){
    if(!cardId)return {reviews_enabled:false,service_reviews_enabled:false};
    try{const {data,error}=await db.rpc('get_card_review_capabilities',{target_card_id:cardId});if(error)throw error;return data||{reviews_enabled:false,service_reviews_enabled:false}}catch{return {reviews_enabled:false,service_reviews_enabled:false}}
  }

  async function loadPublicReviews(card){
    if(!card?.id)return [];
    const {data,error}=await db.from('card_reviews').select('id,card_id,service_id,reviewer_name,rating,comment,status,created_at,owner_response,card_services(title)').eq('card_id',card.id).eq('status','approved').order('created_at',{ascending:false}).limit(30);
    if(error){console.warn('No se pudieron cargar reseñas',error);return []}return data||[];
  }

  function publicReviewsHtml(card,rows,caps){
    const average=rows.length?(rows.reduce((sum,r)=>sum+Number(r.rating||0),0)/rows.length):0;
    const list=rows.length?rows.map(r=>`<article class="mx-review-item"><div class="mx-review-head"><div><div class="mx-review-name">${escReview(r.reviewer_name||'Cliente')}</div><div class="mx-stars" aria-label="${escReview(r.rating)} de 5 estrellas">${starText(r.rating)}</div>${r.card_services?.title?`<div class="mx-review-service">${escReview(r.card_services.title)}</div>`:''}</div><div class="mx-review-meta">${new Date(r.created_at).toLocaleDateString('es-MX')}</div></div>${r.comment?`<p class="mx-review-comment">${escReview(r.comment)}</p>`:''}${r.owner_response?`<p class="mx-review-comment"><b>Respuesta:</b> ${escReview(r.owner_response)}</p>`:''}</article>`).join(''):'<div class="mx-review-empty">Aún no hay reseñas publicadas.</div>';
    const serviceOptions=(caps.service_reviews_enabled&&Array.isArray(card.services)&&card.services.length)?`<div class="field"><label for="mx-review-service">¿Sobre qué quieres opinar?</label><select id="mx-review-service" name="service_id"><option value="">Sobre el negocio en general</option>${card.services.map(s=>`<option value="${escReview(s.id)}">${escReview(s.title)}</option>`).join('')}</select></div>`:'';
    return `<section class="card-section mx-reviews" id="mx-reviews-section"><h2 class="card-section-title">Opiniones y reseñas</h2><div class="mx-reviews-summary"><div><div class="mx-reviews-score">${rows.length?average.toFixed(1):'—'}</div><div class="mx-stars">${rows.length?starText(Math.round(average)):'☆☆☆☆☆'}</div></div><div>${rows.length} ${rows.length===1?'reseña':'reseñas'}</div></div><div class="mx-review-list">${list}</div><button type="button" class="card-secondary-action" onclick="window.mxOpenReviewForm()">⭐ Déjanos tu reseña</button><form class="mx-review-form" id="mx-review-form" hidden onsubmit="window.mxSubmitReview(event)"><div class="field"><label for="mx-review-name">Nombre</label><input id="mx-review-name" name="reviewer_name" maxlength="120" required></div>${serviceOptions}<div class="field"><label>Calificación</label><div class="mx-rating-picker" id="mx-rating-picker">${[1,2,3,4,5].map(n=>`<button type="button" data-rating="${n}" onclick="window.mxSetRating(${n})">★ ${n}</button>`).join('')}</div><input type="hidden" name="rating" id="mx-review-rating" value="5"></div><div class="field"><label for="mx-review-comment">Comentario</label><textarea id="mx-review-comment" name="comment" maxlength="1200" placeholder="Cuéntanos tu experiencia"></textarea></div><div class="error" id="mx-review-error"></div><div class="mx-review-actions"><button class="primary" type="submit">Enviar reseña</button><button class="ghost" type="button" onclick="window.mxCloseReviewForm()">Cancelar</button></div><p class="consent">Tu reseña será revisada antes de publicarse.</p></form></section>`;
  }

  function findPublicInsertPoint(){return document.querySelector('.public-card .card-content')||document.querySelector('.public-card .screen')}

  async function installPublic(){
    if(!isPublic()||!state?.publicCard?.id||document.getElementById('mx-reviews-section'))return;
    const caps=await getCapabilities(state.publicCard.id);if(!caps.reviews_enabled)return;
    reviewState.publicRows=await loadPublicReviews(state.publicCard);const point=findPublicInsertPoint();if(!point)return;
    point.insertAdjacentHTML('beforeend',publicReviewsHtml(state.publicCard,reviewState.publicRows,caps));window.mxSetRating(5);
  }

  window.mxOpenReviewForm=()=>{const form=document.getElementById('mx-review-form');if(form){form.hidden=false;form.scrollIntoView({behavior:'smooth',block:'nearest'});form.querySelector('input')?.focus()}};
  window.mxCloseReviewForm=()=>{const form=document.getElementById('mx-review-form');if(form)form.hidden=true};
  window.mxSetRating=n=>{const rating=Math.max(1,Math.min(5,Number(n)||5));const input=document.getElementById('mx-review-rating');if(input)input.value=String(rating);document.querySelectorAll('#mx-rating-picker button').forEach(btn=>btn.classList.toggle('selected',Number(btn.dataset.rating)<=rating))};
  window.mxSubmitReview=async event=>{
    event.preventDefault();const form=event.currentTarget,button=form.querySelector('button[type="submit"]'),errorEl=document.getElementById('mx-review-error'),card=state?.publicCard;if(!card?.id)return;
    const values=new FormData(form),serviceId=String(values.get('service_id')||'').trim()||null,payload={card_id:card.id,service_id:serviceId,reviewer_name:String(values.get('reviewer_name')||'').trim(),rating:Number(values.get('rating')||5),comment:String(values.get('comment')||'').trim()||null,status:'pending'};
    errorEl.textContent='';button.disabled=true;button.textContent='Enviando…';const {error}=await db.from('card_reviews').insert(payload);if(error){errorEl.textContent='No fue posible enviar tu reseña. Inténtalo nuevamente.';button.disabled=false;button.textContent='Enviar reseña';return}
    form.innerHTML='<div class="success"><b>¡Gracias!</b><br>Tu reseña fue enviada y quedará visible cuando sea aprobada.</div>';
  };

  async function loadAdminReviews(cardId){
    if(!cardId)return [];
    const {data,error}=await db.from('card_reviews').select('id,card_id,service_id,reviewer_name,rating,comment,status,created_at,owner_response,card_services(title)').eq('card_id',cardId).order('created_at',{ascending:false}).limit(100);
    if(error){console.warn('No se pudieron cargar reseñas de administración',error);return []}return data||[];
  }

  function adminHtml(rows){
    const items=rows.length?rows.map(r=>`<article class="mx-review-item" data-review-id="${escReview(r.id)}"><div class="mx-review-head"><div><div class="mx-review-name">${escReview(r.reviewer_name||'Cliente')}</div><div class="mx-stars">${starText(r.rating)}</div>${r.card_services?.title?`<div class="mx-review-service">${escReview(r.card_services.title)}</div>`:''}</div><span class="mx-review-status">${escReview(r.status)}</span></div>${r.comment?`<p class="mx-review-comment">${escReview(r.comment)}</p>`:''}<div class="mx-review-actions"><button class="ghost" type="button" onclick="window.mxReviewStatus('${escReview(r.id)}','approved')">Aprobar</button><button class="ghost" type="button" onclick="window.mxReviewStatus('${escReview(r.id)}','hidden')">Ocultar</button><button class="ghost" type="button" onclick="window.mxDeleteReview('${escReview(r.id)}')">Eliminar</button></div></article>`).join(''):'<div class="mx-review-empty">Todavía no hay reseñas para esta tarjeta.</div>';
    return `<section class="panel mx-review-admin" id="mx-review-admin"><div class="top" style="margin-bottom:12px"><div><h2 style="margin:0">Opiniones y reseñas</h2><p>Aprueba, oculta o elimina reseñas antes de que sean públicas.</p></div></div><div class="mx-review-list">${items}</div></section>`;
  }

  function adminMount(){
    if(isPublic()||!state?.card?.id||document.getElementById('mx-review-admin'))return null;
    if(state.page!=='editor'&&state.page!=='card')return null;
    return document.querySelector('.main')||document.getElementById('root');
  }

  async function installAdmin(){
    const mount=adminMount();if(!mount)return;const caps=await getCapabilities(state.card.id);if(!caps.reviews_enabled)return;reviewState.adminRows=await loadAdminReviews(state.card.id);mount.insertAdjacentHTML('beforeend',adminHtml(reviewState.adminRows));
  }

  async function refreshAdmin(){const old=document.getElementById('mx-review-admin');if(old)old.remove();await installAdmin()}
  window.mxReviewStatus=async(id,status)=>{if(!['approved','hidden','pending'].includes(status))return;const {error}=await db.from('card_reviews').update({status,moderated_at:new Date().toISOString()}).eq('id',id);if(error){window.toast?.('No se pudo actualizar la reseña.');return}window.toast?.(status==='approved'?'Reseña aprobada.':'Reseña actualizada.');await refreshAdmin()};
  window.mxDeleteReview=async id=>{const {error}=await db.from('card_reviews').delete().eq('id',id);if(error){window.toast?.('No se pudo eliminar la reseña.');return}window.toast?.('Reseña eliminada.');await refreshAdmin()};

  injectStyles();
  const observer=new MutationObserver(()=>{if(isPublic())void installPublic();else void installAdmin()});observer.observe(document.documentElement,{childList:true,subtree:true});
  if(isPublic())setTimeout(()=>void installPublic(),50);else setTimeout(()=>void installAdmin(),50);
})();
