// MX Business Card — menú público para compartir tarjeta, mostrar QR y copiar enlace.
(() => {
  if (!location.pathname.startsWith('/c/')) return;

  const SHARE_STYLE_ID = 'mx-public-share-style';
  const SHARE_MENU_ID = 'mx-public-share-menu';
  const QR_MODAL_ID = 'mx-public-qr-modal';
  const QR_MODULE_URL = 'https://cdn.jsdelivr.net/npm/qrcode@1.5.4/+esm';
  let qrModulePromise;

  const labels = () => document.documentElement.lang === 'en' ? {
    share: 'Share',
    showQr: 'Show QR code',
    shareCard: 'Share card',
    copyLink: 'Copy link',
    copied: 'Link copied',
    copyFailed: 'The link could not be copied.',
    shareText: 'View my digital business card',
    qrTitle: 'QR code',
    close: 'Close',
    qrError: 'The QR code could not be generated.'
  } : {
    share: 'Compartir',
    showQr: 'Mostrar código QR',
    shareCard: 'Compartir tarjeta',
    copyLink: 'Copiar enlace',
    copied: 'Enlace copiado',
    copyFailed: 'No se pudo copiar el enlace.',
    shareText: 'Mira mi tarjeta digital',
    qrTitle: 'Código QR',
    close: 'Cerrar',
    qrError: 'No se pudo generar el código QR.'
  };

  function cardSlug() {
    return decodeURIComponent(location.pathname.replace(/^\/c\/?/, '')).split('/')[0] || '';
  }

  function canonicalUrl() {
    return 'https://mxbusinesscard.com/c/' + encodeURIComponent(cardSlug());
  }

  function qrUrl() {
    return canonicalUrl() + '?source=qr';
  }

  function publicCard() {
    try {
      return typeof state !== 'undefined' && state.publicCard ? state.publicCard : null;
    } catch {
      return null;
    }
  }

  function notify(message) {
    try {
      if (typeof toast === 'function') {
        toast(message);
        return;
      }
    } catch {}
    const existing = document.getElementById('mx-share-toast');
    existing?.remove();
    const el = document.createElement('div');
    el.id = 'mx-share-toast';
    el.textContent = message;
    el.setAttribute('role', 'status');
    document.body.appendChild(el);
    setTimeout(() => el.remove(), 2400);
  }

  function ensureStyles() {
    if (document.getElementById(SHARE_STYLE_ID)) return;
    const style = document.createElement('style');
    style.id = SHARE_STYLE_ID;
    style.textContent = `
      .mx-share-wrap{position:relative;grid-column:span 1}
      .mx-share-trigger{width:100%;height:100%}
      .mx-share-menu{position:absolute;z-index:50;right:0;top:calc(100% + 8px);width:min(260px,calc(100vw - 32px));display:grid;gap:4px;padding:8px;border:1px solid var(--border-default,#e2e7f0);border-radius:14px;background:#fff;box-shadow:0 16px 36px rgba(16,24,40,.18)}
      .mx-share-menu[hidden]{display:none}
      .mx-share-option{width:100%;min-height:44px;display:flex;align-items:center;justify-content:flex-start;gap:10px;padding:10px 12px;border:0;border-radius:10px;background:#fff;color:#101828;font-weight:700;text-align:left}
      .mx-share-option:hover,.mx-share-option:focus-visible{background:#f5f6fb;color:var(--card-brand-primary,#4f46e5)}
      .mx-share-option svg{width:20px;height:20px;flex:0 0 20px}
      .mx-qr-layer{position:fixed;z-index:1000;inset:0;display:grid;place-items:center;padding:20px;background:rgba(11,18,32,.55)}
      .mx-qr-dialog{width:min(390px,100%);padding:22px;border-radius:20px;background:#fff;box-shadow:0 24px 70px rgba(16,24,40,.28);text-align:center}
      .mx-qr-head{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:14px}
      .mx-qr-head h2{margin:0;font-size:20px}
      .mx-qr-close{width:44px;height:44px;padding:0;border:1px solid #e2e7f0;border-radius:10px;background:#fff;color:#101828;font-size:24px;line-height:1}
      .mx-qr-canvas-wrap{display:grid;place-items:center;min-height:280px;padding:16px;border:1px solid #e2e7f0;border-radius:16px;background:#fff}
      .mx-qr-canvas-wrap canvas{width:min(280px,100%);height:auto;image-rendering:auto}
      .mx-qr-url{margin:14px 0 0;color:#667085;font-size:12px;overflow-wrap:anywhere}
      #mx-share-toast{position:fixed;z-index:1200;right:20px;bottom:20px;max-width:calc(100vw - 40px);padding:12px 16px;border-radius:10px;background:#101828;color:#fff;font:600 14px/20px system-ui;box-shadow:0 12px 28px rgba(16,24,40,.22)}
      @media(max-width:600px){.mx-share-wrap{grid-column:span 1}.mx-share-menu{position:fixed;right:12px;bottom:12px;top:auto;left:12px;width:auto;padding:10px;border-radius:18px}.mx-qr-layer{padding:12px}.mx-qr-dialog{padding:18px}.mx-qr-canvas-wrap{min-height:260px}}
    `;
    document.head.appendChild(style);
  }

  function icon(type) {
    const paths = {
      share: '<path d="M8 12h8M12 8l4 4-4 4"/><path d="M5 5h6M5 19h6"/>',
      qr: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><path d="M15 14h2v2h-2zM19 14h2v4h-2zM14 19h4v2h-4z"/>',
      send: '<path d="m3 11 18-8-8 18-2-8-8-2Z"/><path d="m11 13 4-4"/>',
      copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V4H4v12h4"/>'
    };
    return `<svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${paths[type] || paths.share}</svg>`;
  }

  function closeMenu() {
    const menu = document.getElementById(SHARE_MENU_ID);
    const trigger = document.querySelector('[data-mx-share-trigger]');
    if (menu) menu.hidden = true;
    if (trigger) trigger.setAttribute('aria-expanded', 'false');
  }

  function toggleMenu(event) {
    event?.stopPropagation();
    const menu = document.getElementById(SHARE_MENU_ID);
    const trigger = document.querySelector('[data-mx-share-trigger]');
    if (!menu || !trigger) return;
    const open = menu.hidden;
    menu.hidden = !open;
    trigger.setAttribute('aria-expanded', String(open));
    if (open) menu.querySelector('button')?.focus();
  }

  async function copyLink() {
    closeMenu();
    const text = canonicalUrl();
    try {
      if (navigator.clipboard?.writeText) await navigator.clipboard.writeText(text);
      else {
        const input = document.createElement('textarea');
        input.value = text;
        input.style.position = 'fixed';
        input.style.opacity = '0';
        document.body.appendChild(input);
        input.select();
        if (!document.execCommand('copy')) throw new Error('copy failed');
        input.remove();
      }
      notify(labels().copied);
    } catch {
      notify(labels().copyFailed);
    }
  }

  async function shareCard() {
    closeMenu();
    const l = labels();
    const card = publicCard();
    const payload = {
      title: card?.name ? `${card.name} · MX Business Card` : 'MX Business Card',
      text: l.shareText,
      url: canonicalUrl()
    };
    if (navigator.share) {
      try {
        await navigator.share(payload);
        return;
      } catch (error) {
        if (error?.name === 'AbortError') return;
      }
    }
    await copyLink();
  }

  function closeQr() {
    document.getElementById(QR_MODAL_ID)?.remove();
  }

  async function showQr() {
    closeMenu();
    closeQr();
    const l = labels();
    const layer = document.createElement('div');
    layer.className = 'mx-qr-layer';
    layer.id = QR_MODAL_ID;
    layer.innerHTML = `<section class="mx-qr-dialog" role="dialog" aria-modal="true" aria-labelledby="mx-qr-title"><div class="mx-qr-head"><h2 id="mx-qr-title">${l.qrTitle}</h2><button class="mx-qr-close" type="button" aria-label="${l.close}">×</button></div><div class="mx-qr-canvas-wrap"><canvas width="280" height="280" aria-label="${l.qrTitle}"></canvas></div><p class="mx-qr-url">${canonicalUrl()}</p></section>`;
    layer.addEventListener('click', event => { if (event.target === layer) closeQr(); });
    layer.querySelector('.mx-qr-close').addEventListener('click', closeQr);
    document.body.appendChild(layer);
    layer.querySelector('.mx-qr-close').focus();
    try {
      qrModulePromise ||= import(QR_MODULE_URL).then(module => module.default ?? module);
      const QRCode = await qrModulePromise;
      const canvas = layer.querySelector('canvas');
      await QRCode.toCanvas(canvas, qrUrl(), { errorCorrectionLevel: 'Q', margin: 4, width: 560, color: { dark: '#000000', light: '#FFFFFF' } });
    } catch (error) {
      console.error('No se pudo generar el QR público.', error);
      const wrap = layer.querySelector('.mx-qr-canvas-wrap');
      wrap.textContent = l.qrError;
    }
  }

  function install() {
    ensureStyles();
    const actions = document.querySelector('.public-card .card-main-actions');
    if (!actions || actions.querySelector('[data-mx-share-trigger]')) return false;
    const l = labels();
    const wrap = document.createElement('div');
    wrap.className = 'mx-share-wrap';
    wrap.innerHTML = `<button class="card-main-action mx-share-trigger" data-mx-share-trigger type="button" aria-haspopup="menu" aria-expanded="false" aria-controls="${SHARE_MENU_ID}">${icon('share')}<span>${l.share}</span></button><div class="mx-share-menu" id="${SHARE_MENU_ID}" role="menu" hidden><button class="mx-share-option" type="button" role="menuitem" data-mx-share-qr>${icon('qr')}<span>${l.showQr}</span></button><button class="mx-share-option" type="button" role="menuitem" data-mx-share-native>${icon('send')}<span>${l.shareCard}</span></button><button class="mx-share-option" type="button" role="menuitem" data-mx-share-copy>${icon('copy')}<span>${l.copyLink}</span></button></div>`;
    const saveContact = actions.querySelector('.card-save-contact');
    if (saveContact) actions.insertBefore(wrap, saveContact);
    else actions.appendChild(wrap);
    wrap.querySelector('[data-mx-share-trigger]').addEventListener('click', toggleMenu);
    wrap.querySelector('[data-mx-share-qr]').addEventListener('click', showQr);
    wrap.querySelector('[data-mx-share-native]').addEventListener('click', shareCard);
    wrap.querySelector('[data-mx-share-copy]').addEventListener('click', copyLink);
    return true;
  }

  document.addEventListener('click', event => {
    if (!event.target.closest('.mx-share-wrap')) closeMenu();
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') {
      if (document.getElementById(QR_MODAL_ID)) closeQr();
      else closeMenu();
    }
  });

  if (!install()) {
    const observer = new MutationObserver(() => {
      if (install()) observer.disconnect();
    });
    observer.observe(document.documentElement, { childList: true, subtree: true });
    setTimeout(() => observer.disconnect(), 15000);
  }
})();
