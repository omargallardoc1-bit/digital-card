// MX Business Card — opciones visuales de banner y marcas.
(() => {
  const HEIGHTS = new Set([245, 320, 740]);
  const normalizeHeight = value => HEIGHTS.has(Number(value)) ? Number(value) : 320;

  const css = document.createElement('style');
  css.textContent = `
    .banner-height-control{margin:0 0 16px;padding:14px;border:1px solid var(--border-default);border-radius:12px;background:var(--surface-muted)}
    .banner-height-control label{display:block;margin-bottom:7px;font-size:13px;font-weight:800;color:var(--text-primary)}
    .banner-height-control select{width:100%}
    .banner-height-control small{display:block;margin-top:7px;color:var(--text-muted);font-size:12px;line-height:18px}
    .card-socials .social-link[aria-label="Facebook"]{color:#1877F2}
    .card-socials .social-link[aria-label="Instagram"]{color:#E4405F}
    .card-socials .social-link[aria-label="LinkedIn"]{color:#0A66C2}
    .card-socials .social-link[aria-label="TikTok"]{color:#000}
    .card-socials .social-link[aria-label="YouTube"]{color:#FF0000}
    .card-socials .social-link[aria-label="X"]{color:#000}
    .card-main-action.wa{border-color:#25D366;background:#25D366;color:#fff}
    .card-main-action.wa:hover,.card-main-action.wa:focus-visible{border-color:#128C7E;background:#128C7E;color:#fff}
    .card-cover{transition:min-height .2s ease,height .2s ease}
  `;
  document.head.appendChild(css);

  function applyHeightToMarkup(markup, card) {
    const height = normalizeHeight(card?.banner_height);
    return String(markup).replace('class="hero card-cover" style="', `class="hero card-cover" data-banner-height="${height}" style="min-height:${height}px;height:${height}px;`);
  }

  if (typeof phonePreview === 'function') {
    const originalPhonePreview = phonePreview;
    phonePreview = function(card) { return applyHeightToMarkup(originalPhonePreview(card), card); };
  }

  function selectorMarkup() {
    const value = normalizeHeight(state?.card?.banner_height);
    const disabled = typeof canEditCurrentCardContent === 'function' && !canEditCurrentCardContent();
    return `<div class="banner-height-control" id="banner-height-control"><label for="card-banner-height">Altura del banner</label><select id="card-banner-height" ${disabled?'disabled':''}><option value="245" ${value===245?'selected':''}>Compacto — 245 px</option><option value="320" ${value===320?'selected':''}>Medio — 320 px</option><option value="740" ${value===740?'selected':''}>Grande — 740 px</option></select><small>La foto de perfil conserva su posición. El cambio se aplica a esta tarjeta.</small></div>`;
  }

  function installSelector() {
    if (typeof state === 'undefined' || state.page !== 'editor') return;
    const mediaBlock = document.querySelector('[data-editor-block="media"] .editor-block-content');
    if (!mediaBlock || document.getElementById('banner-height-control')) return;
    mediaBlock.insertAdjacentHTML('afterbegin', selectorMarkup());
    document.getElementById('card-banner-height')?.addEventListener('change', async event => {
      const height = normalizeHeight(event.target.value);
      state.card.banner_height = height;
      if (typeof refreshPreview === 'function') refreshPreview();
      if (!state.card.id) return;
      event.target.disabled = true;
      const {data,error} = await db.rpc('set_card_banner_height',{target_card_id:state.card.id,requested_height:height});
      event.target.disabled = false;
      if (error) {
        if (typeof toast === 'function') toast('No se pudo guardar la altura del banner: '+error.message);
        return;
      }
      const row=Array.isArray(data)?data[0]:data;
      if(row?.banner_height){state.card.banner_height=Number(row.banner_height);state.cards=state.cards.map(card=>card.id===state.card.id?{...card,banner_height:Number(row.banner_height)}:card)}
      if (typeof toast === 'function') toast('Altura del banner guardada.');
    });
  }

  if (typeof saveCard === 'function') {
    const originalSaveCard = saveCard;
    saveCard = async function(...args) {
      const requested = normalizeHeight(state?.card?.banner_height);
      const result = await originalSaveCard.apply(this,args);
      if (result && state?.card?.id && normalizeHeight(state.card.banner_height) !== requested) state.card.banner_height=requested;
      if (result && state?.card?.id) {
        const {data,error}=await db.rpc('set_card_banner_height',{target_card_id:state.card.id,requested_height:requested});
        if(!error){const row=Array.isArray(data)?data[0]:data;if(row?.banner_height)state.card.banner_height=Number(row.banner_height)}
      }
      return result;
    };
  }

  const observer = new MutationObserver(() => installSelector());
  observer.observe(document.documentElement,{childList:true,subtree:true});
  document.addEventListener('DOMContentLoaded',installSelector);
  installSelector();
})();
