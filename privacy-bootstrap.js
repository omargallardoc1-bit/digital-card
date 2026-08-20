// Carga la integración de privacidad sin modificar el bundle principal.
// Vercel sirve este archivo como recurso estático.
(function(){
  var script=document.createElement('script');
  script.src='/privacy-integration.js';
  script.defer=true;
  document.head.appendChild(script);
})();
