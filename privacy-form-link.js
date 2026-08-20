// MX Business Card — enlace del Aviso de Privacidad en el formulario público.
// Mejora progresiva: no altera el envío ni el backend de prospectos.
(() => {
  const PRIVACY_URL = '/privacidad';
  const CONSENT_VERSION = 'v1';

  function enhanceProspectPrivacy() {
    const panel = document.getElementById('prospect-panel');
    const help = document.getElementById('prospect-consent-help');
    if (!panel || !help || panel.dataset.privacyEnhanced === '1') return;

    const english = document.documentElement.lang === 'en';
    help.textContent = english
      ? `I agree that my information may be used by the owner of this Digital Card to respond to my contact request. Consent version: ${CONSENT_VERSION}. `
      : `Acepto que mis datos sean utilizados por el titular de esta Digital Card para atender mi solicitud de contacto. Versión de consentimiento: ${CONSENT_VERSION}. `;

    const link = document.createElement('a');
    link.href = PRIVACY_URL;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    link.textContent = english ? 'Read Privacy Notice' : 'Consultar Aviso de Privacidad';
    help.appendChild(link);

    const summary = document.createElement('p');
    summary.className = 'consent';
    summary.id = 'prospect-privacy-summary';
    summary.textContent = english
      ? 'The card owner or company will use the details you voluntarily provide to respond to your request. MX Business Card provides the technology used to receive and process these details.'
      : 'El titular o empresa propietaria de la tarjeta utilizará los datos que proporciones voluntariamente para atender tu solicitud. MX Business Card proporciona la plataforma tecnológica para recibir y procesar estos datos.';
    const form = panel.querySelector('form');
    if (form) {
      panel.insertBefore(summary, form);
      const describedBy = form.getAttribute('aria-describedby') || '';
      if (!describedBy.includes(summary.id)) form.setAttribute('aria-describedby', `${summary.id} ${describedBy}`.trim());
    }
    panel.dataset.privacyEnhanced = '1';
  }

  const observer = new MutationObserver(enhanceProspectPrivacy);
  observer.observe(document.documentElement, { childList: true, subtree: true });
  document.addEventListener('DOMContentLoaded', enhanceProspectPrivacy);
  enhanceProspectPrivacy();
})();
