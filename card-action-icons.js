// MX Business Card — iconos de acciones de contacto.
(() => {
  const svg=(body,extra='')=>`<span class="mx-action-icon" aria-hidden="true"><svg viewBox="0 0 24 24" focusable="false" ${extra}>${body}</svg></span>`;
  const icons={
    whatsapp:()=>svg('<path fill="currentColor" d="M17.472 14.382c-.297-.149-1.758-.867-2.03-.967-.273-.099-.471-.148-.67.15-.197.297-.767.966-.94 1.164-.173.199-.347.223-.644.075-.297-.15-1.255-.463-2.39-1.475-.883-.788-1.48-1.761-1.653-2.059-.173-.297-.018-.458.13-.606.134-.133.298-.347.446-.52.149-.174.198-.298.298-.497.099-.198.05-.371-.025-.52-.075-.149-.669-1.612-.916-2.207-.242-.579-.487-.5-.669-.51-.173-.008-.371-.01-.57-.01-.198 0-.52.074-.792.372-.272.297-1.04 1.016-1.04 2.479s1.065 2.875 1.213 3.074c.149.198 2.095 3.2 5.076 4.487.709.306 1.262.489 1.693.625.712.227 1.36.195 1.871.118.571-.085 1.758-.719 2.006-1.413.248-.694.248-1.29.173-1.414-.074-.124-.272-.198-.57-.347m-5.421 7.403h-.004a9.87 9.87 0 0 1-5.031-1.378l-.361-.214-3.741.982.998-3.648-.235-.374a9.86 9.86 0 0 1-1.51-5.26c.001-5.45 4.436-9.884 9.888-9.884 2.64 0 5.122 1.03 6.988 2.898a9.825 9.825 0 0 1 2.9 6.988c-.003 5.45-4.437 9.884-9.884 9.884m8.413-18.297A11.815 11.815 0 0 0 12.05 0C5.495 0 .16 5.335.157 11.892c0 2.096.547 4.142 1.588 5.945L.057 24l6.305-1.654a11.882 11.882 0 0 0 5.683 1.448h.005c6.554 0 11.89-5.335 11.893-11.893a11.821 11.821 0 0 0-3.48-8.413Z"/>'),
    phone:()=>svg('<path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6A19.79 19.79 0 0 1 2.12 4.18 2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72c.12.9.33 1.78.62 2.63a2 2 0 0 1-.45 2.11L8 9.73a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.85.29 1.73.5 2.63.62A2 2 0 0 1 22 16.92Z" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'),
    email:()=>svg('<rect x="3" y="5" width="18" height="14" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="m4 7 8 6 8-6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'),
    link:()=>svg('<circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2"/><path d="M3.6 9h16.8M3.6 15h16.8M12 3a15 15 0 0 1 0 18M12 3a15 15 0 0 0 0 18" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>'),
    contact:()=>svg('<circle cx="9" cy="8" r="3" fill="none" stroke="currentColor" stroke-width="2"/><path d="M3.5 19c.7-3.2 2.5-5 5.5-5s4.8 1.8 5.5 5M18 8v7M14.5 11.5H21.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>'),
    map:()=>svg('<path d="M12 22s7-6.2 7-13a7 7 0 1 0-14 0c0 6.8 7 13 7 13Z" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12" cy="9" r="2.5" fill="none" stroke="currentColor" stroke-width="2"/>')
  };

  const css=document.createElement('style');
  css.textContent=`
    .mx-action-icon{width:24px;height:24px;display:inline-grid;place-items:center;flex:0 0 24px;color:inherit}
    .mx-action-icon svg{width:24px;height:24px;display:block;overflow:visible}
    .card-main-action,.card-secondary-action,.card-location .action{display:flex;align-items:center;justify-content:center;gap:9px}
  `;
  document.head.appendChild(css);

  const install=()=>{
    if(typeof cardActionIcon!=='function'||cardActionIcon.__mxOfficialIcons)return;
    const original=cardActionIcon;
    const replacement=function(type){const key=String(type||'').toLowerCase();return icons[key]?icons[key]():original(type)};
    replacement.__mxOfficialIcons=true;
    cardActionIcon=replacement;
    window.cardActionIcon=replacement;
    if(typeof refreshPreview==='function'&&typeof state!=='undefined'&&state.page==='editor')refreshPreview();
  };

  install();
})();
