// MX Business Card — integración del aviso simplificado para tarjetas públicas.
// Se carga después de index.html y sustituye únicamente prospectForm.
(() => {
  const PRIVACY_PATH = '/privacidad';
  const CONSENT_VERSION = 'v1';

  window.prospectForm = function prospectForm(card) {
    if (prospectAlreadySent(card.id)) {
      return `<div class="panel lead-panel success" role="status"><b>Datos enviados correctamente.</b><br>Gracias por compartir tu información.</div>`;
    }
    const notice = language === 'en'
      ? `The owner or company behind this Digital Card will use the information you provide to respond to your contact, information or quote request. MX Business Card provides the technology used to receive and process these details. Read the <a href="${PRIVACY_PATH}" target="_blank" rel="noopener noreferrer">Privacy Notice</a>.`
      : `El titular o empresa propietaria de esta tarjeta utilizará los datos que proporciones para atender tu solicitud de contacto, información o cotización. MX Business Card proporciona la plataforma tecnológica para recibir y procesar estos datos. Consulta el <a href="${PRIVACY_PATH}" target="_blank" rel="noopener noreferrer">Aviso de Privacidad</a>.`;
    const consent = language === 'en'
      ? `I have read the Privacy Notice and agree that my information may be processed to respond to my contact request. Consent version: ${CONSENT_VERSION}.`
      : `He leído el Aviso de Privacidad y acepto el tratamiento de mis datos para atender mi solicitud de contacto. Versión de consentimiento: ${CONSENT_VERSION}.`;
    return `<div class="panel lead-panel" id="prospect-panel"><h2>¿Quieres que te contactemos?</h2><p class="copy-muted">Déjanos tus datos de forma opcional. La tarjeta y sus medios de contacto permanecen disponibles sin completar este formulario.</p><p class="consent" id="prospect-privacy-summary">${notice}</p><form onsubmit="submitProspect(event)" aria-describedby="prospect-privacy-summary prospect-consent-help prospect-form-error"><div class="field"><label for="prospect-name">Nombre</label><input id="prospect-name" name="name" maxlength="120" autocomplete="name" required></div><div class="field"><label for="prospect-phone">Teléfono</label><input id="prospect-phone" name="phone" type="tel" maxlength="40" autocomplete="tel" required></div><div class="field"><label for="prospect-email">Correo (opcional)</label><input id="prospect-email" name="email" type="email" maxlength="254" autocomplete="email"></div><div class="field check"><label for="prospect-consent"><input id="prospect-consent" name="consentimiento" type="checkbox" required><span class="consent" id="prospect-consent-help">${consent}</span></label></div><div class="error" id="prospect-form-error" data-prospect-error role="alert" aria-live="polite"></div><button class="primary" type="submit">Enviar mis datos</button></form></div>`;
  };
})();
