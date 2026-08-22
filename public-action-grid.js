// MX Business Card — ajuste puntual: Guardar contacto ocupa una sola celda.
(() => {
  if (!location.pathname.startsWith('/c/')) return;
  const id='mx-public-action-grid-style';
  if(document.getElementById(id)) return;
  const style=document.createElement('style');
  style.id=id;
  style.textContent=`
    .public-card .card-save-contact{grid-column:span 1!important}
  `;
  document.head.appendChild(style);
})();
