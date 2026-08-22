// MX Business Card — acciones públicas verticales en 2 columnas (3 filas de 2).
(() => {
  if (!location.pathname.startsWith('/c/')) return;
  const id='mx-public-action-grid-style';
  if(document.getElementById(id)) return;
  const style=document.createElement('style');
  style.id=id;
  style.textContent=`
    .public-card .card-main-actions{
      grid-template-columns:repeat(2,minmax(0,1fr))!important;
      gap:10px!important;
    }
    .public-card .card-save-contact,
    .public-card .mx-share-wrap{
      grid-column:span 1!important;
    }
    .public-card .card-main-action{
      min-width:0!important;
      min-height:76px!important;
      padding:10px 8px!important;
      flex-direction:column!important;
      align-items:center!important;
      justify-content:center!important;
      gap:7px!important;
      text-align:center!important;
      line-height:16px!important;
    }
    .public-card .card-main-action svg,
    .public-card .card-main-action .mx-action-icon,
    .public-card .card-main-action .mx-action-icon svg{
      width:24px!important;
      height:24px!important;
      flex:0 0 24px!important;
    }
    .public-card .mx-share-trigger{width:100%!important;height:100%!important}
    @media(max-width:600px){
      .public-card .card-main-actions{grid-template-columns:repeat(2,minmax(0,1fr))!important;gap:9px!important}
      .public-card .card-main-action{min-height:74px!important;padding:9px 7px!important;font-size:12px!important}
      .public-card .card-save-contact,.public-card .mx-share-wrap{grid-column:span 1!important}
    }
  `;
  document.head.appendChild(style);
})();
